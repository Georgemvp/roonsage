"""REST endpoints for sonic clustering (v13.0).

Routes
------
POST /api/clustering/run                trigger UMAP+HDBSCAN run (background)
GET  /api/clustering/status             progress + last-run summary
GET  /api/clustering/data               every track with cluster_id + 2D coords
GET  /api/clustering/summary            per-cluster aggregate stats
GET  /api/clustering/cluster/{cid}/tracks  tracks in a specific cluster

Clustering is CPU-bound (UMAP scales with O(n log n) but allocates a lot);
it runs via ``asyncio.to_thread`` so the event loop stays responsive.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.audio_features import cluster_tagger, clustering
from backend.db import get_db_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/clustering", tags=["clustering"])


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------


class ClusteringStatusResponse(BaseModel):
    status: str  # idle | running | complete | failed
    started_at: str | None = None
    finished_at: str | None = None
    n_tracks: int = 0
    n_clusters: int = 0
    n_noise: int = 0
    error_message: str | None = None
    params: dict[str, Any] = {}


class ClusteringRunResponse(BaseModel):
    started: bool
    message: str


class ClusterTrack(BaseModel):
    item_key: str
    title: str
    artist: str
    album: str
    year: int | None = None
    genres: str | None = None
    cluster_id: int | None = None
    x_2d: float | None = None
    y_2d: float | None = None
    bpm: float | None = None
    energy: float | None = None
    valence: float | None = None
    danceability: float | None = None


class ClusterSummary(BaseModel):
    cluster_id: int
    track_count: int
    avg_bpm: float | None = None
    avg_energy: float | None = None
    avg_valence: float | None = None
    avg_danceability: float | None = None
    centroid_x: float | None = None
    centroid_y: float | None = None
    dominant_genre: str | None = None
    is_noise: bool = False


class ClusterDataResponse(BaseModel):
    total: int
    tracks: list[ClusterTrack]


class ClusterSummaryResponse(BaseModel):
    n_clusters: int
    summaries: list[ClusterSummary]


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


def _current_status() -> dict[str, Any]:
    conn = get_db_connection()
    try:
        return clustering.get_status(conn)
    finally:
        conn.close()


def _run_clustering_sync() -> None:
    """Worker for asyncio.to_thread — opens its own connection.

    On completion, fires the ``clustering_complete`` automation trigger so
    downstream automations (e.g. auto-tag + notify) can run.
    """
    conn = get_db_connection()
    result: dict[str, Any] | None = None
    try:
        result = clustering.run_clustering(conn=conn)
    finally:
        conn.close()

    if result and result.get("status") == "complete":
        try:
            from backend.automation_engine import (  # noqa: PLC0415
                TriggerType,
                get_engine,
            )
            engine = get_engine()
            if engine is not None:
                engine.on_event(
                    TriggerType.CLUSTERING_COMPLETE,
                    {
                        "n_tracks": result.get("n_tracks", 0),
                        "n_clusters": result.get("n_clusters", 0),
                        "n_noise": result.get("n_noise", 0),
                    },
                )
        except Exception as exc:  # pragma: no cover - notification is best-effort
            logger.debug("clustering_complete event dispatch failed: %s", exc)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/run", response_model=ClusteringRunResponse)
async def trigger_clustering() -> ClusteringRunResponse:
    """Kick off a clustering run in the background.

    Returns immediately. Poll ``/api/clustering/status`` for completion.
    """
    status = _current_status()
    if status.get("status") == "running":
        raise HTTPException(
            status_code=409,
            detail="A clustering run is already in progress.",
        )

    # Fire-and-forget background task. Errors are captured into cluster_runs.
    asyncio.create_task(  # noqa: RUF006 - background lifetime is bounded by the run
        asyncio.to_thread(_run_clustering_sync),
        name="clustering-run",
    )
    return ClusteringRunResponse(
        started=True,
        message="Clustering started. Poll /api/clustering/status for progress.",
    )


@router.get("/status", response_model=ClusteringStatusResponse)
async def get_status() -> ClusteringStatusResponse:
    """Current state of the clustering pipeline."""
    s = _current_status()
    return ClusteringStatusResponse(
        status=s.get("status", "idle"),
        started_at=s.get("started_at"),
        finished_at=s.get("finished_at"),
        n_tracks=s.get("n_tracks") or 0,
        n_clusters=s.get("n_clusters") or 0,
        n_noise=s.get("n_noise") or 0,
        error_message=s.get("error_message"),
        params=s.get("params") or {},
    )


@router.get("/data", response_model=ClusterDataResponse)
async def get_data(limit: int | None = None) -> ClusterDataResponse:
    """All clustered tracks with 2D coords for the Music Map."""
    conn = get_db_connection()
    try:
        rows = clustering.get_cluster_data(conn, limit=limit)
    finally:
        conn.close()
    return ClusterDataResponse(
        total=len(rows),
        tracks=[ClusterTrack(**r) for r in rows],
    )


@router.get("/summary", response_model=ClusterSummaryResponse)
async def get_summary() -> ClusterSummaryResponse:
    """Per-cluster aggregate stats."""
    conn = get_db_connection()
    try:
        summaries = clustering.get_cluster_summary(conn)
    finally:
        conn.close()
    return ClusterSummaryResponse(
        n_clusters=sum(1 for s in summaries if not s["is_noise"]),
        summaries=[ClusterSummary(**s) for s in summaries],
    )


class ClusterLabel(BaseModel):
    cluster_id: int
    label_primary: str | None = None
    label_secondary: str | None = None
    label_tertiary: str | None = None
    labels: list[str] = []
    track_count: int = 0
    source: str | None = None
    updated_at: str | None = None


class ClusterLabelsResponse(BaseModel):
    n_labels: int
    labels: list[ClusterLabel]


class ClusterAutoTagResponse(BaseModel):
    n_clusters: int
    clusters: dict[int, dict[str, Any]]


@router.post("/auto-tag", response_model=ClusterAutoTagResponse)
async def trigger_auto_tag() -> ClusterAutoTagResponse:
    """Compute and persist human-readable labels for every cluster.

    Uses Last.fm community tags when available, falling back to Roon's own
    genre tags. Synchronous (pure SQL), typically completes in <1 s.
    """
    result = await cluster_tagger.auto_tag_clusters()
    return ClusterAutoTagResponse(
        n_clusters=result["n_clusters"],
        clusters={int(k): v for k, v in result["clusters"].items()},
    )


@router.get("/labels", response_model=ClusterLabelsResponse)
async def list_labels() -> ClusterLabelsResponse:
    """Return every persisted cluster label."""
    conn = get_db_connection()
    try:
        rows = cluster_tagger.get_all_labels(conn)
    finally:
        conn.close()
    return ClusterLabelsResponse(
        n_labels=len(rows),
        labels=[ClusterLabel(**r) for r in rows],
    )


@router.get("/cluster/{cluster_id}/tracks", response_model=ClusterDataResponse)
async def get_tracks(cluster_id: int, limit: int = 200) -> ClusterDataResponse:
    """Tracks belonging to a single cluster."""
    conn = get_db_connection()
    try:
        rows = clustering.get_cluster_tracks(conn, cluster_id, limit=limit)
    finally:
        conn.close()
    if not rows:
        raise HTTPException(
            status_code=404,
            detail=f"No tracks found for cluster {cluster_id}",
        )
    return ClusterDataResponse(
        total=len(rows),
        tracks=[ClusterTrack(**r) for r in rows],
    )
