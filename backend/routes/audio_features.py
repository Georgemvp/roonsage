"""REST endpoints for the Audio Feature Analysis subsystem.

Routes
------
GET  /api/audio-features/status         queue + worker state
POST /api/audio-features/start          (re)populate queue and start the worker
POST /api/audio-features/pause          pause after current item
POST /api/audio-features/resume         resume a paused worker
POST /api/audio-features/rescan-paths   re-walk the music library and re-queue
GET  /api/audio-features/{item_key}     fetch the stored features for one track
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.db import get_db_connection
from backend.filter_sessions import store_session
from backend.models import DJSetCurvePoint, DJSetRequest, DJSetResponse, Track

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/audio-features", tags=["audio-features"])


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------


class AudioFeaturesStatusResponse(BaseModel):
    enabled: bool
    analyzer_available: bool
    music_path_present: bool
    pending: int = 0
    analyzing: int = 0
    complete: int = 0
    failed: int = 0
    unresolved: int = 0
    analysed_total: int = 0
    worker_running: bool = False
    worker_paused: bool = False
    full_features: bool = True


class AudioFeaturesActionResponse(BaseModel):
    success: bool
    message: str = ""
    queued: int = 0
    matched: int = 0
    unresolved: int = 0


class TrackAudioFeatures(BaseModel):
    item_key: str
    file_path: str | None = None
    bpm: float | None = None
    bpm_confidence: float | None = None
    key_root: str | None = None
    key_mode: str | None = None
    camelot: str | None = None
    energy: float | None = None
    danceability: float | None = None
    valence: float | None = None
    acousticness: float | None = None
    instrumentalness: float | None = None
    loudness_lufs: float | None = None
    analyzed_at: str | None = None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


def _enabled() -> bool:
    return os.environ.get("AUDIO_FEATURES_ENABLED", "").lower() in ("1", "true", "yes")


def _music_root() -> Path:
    return Path(os.environ.get("MUSIC_LIBRARY_PATH", "/music"))


@router.get("/status", response_model=AudioFeaturesStatusResponse)
async def get_status() -> AudioFeaturesStatusResponse:
    """Queue counts, worker state, and feature flags."""
    from backend.audio_features.analyzer import ANALYZER_AVAILABLE  # noqa: PLC0415
    from backend.audio_features.worker import (  # noqa: PLC0415
        AUDIO_FEATURES_FULL,
        get_features_worker,
        get_queue_stats,
    )

    conn = get_db_connection()
    try:
        stats = get_queue_stats(conn)
    finally:
        conn.close()

    worker = get_features_worker()
    return AudioFeaturesStatusResponse(
        enabled=_enabled(),
        analyzer_available=ANALYZER_AVAILABLE,
        music_path_present=_music_root().exists(),
        pending=stats.get("pending", 0),
        analyzing=stats.get("analyzing", 0),
        complete=stats.get("complete", 0),
        failed=stats.get("failed", 0),
        unresolved=stats.get("unresolved", 0),
        analysed_total=stats.get("analysed_total", 0),
        worker_running=worker.is_running(),
        worker_paused=worker.is_paused(),
        full_features=AUDIO_FEATURES_FULL,
    )


@router.post("/start", response_model=AudioFeaturesActionResponse)
async def start_worker() -> AudioFeaturesActionResponse:
    """Re-populate the queue and start (or resume) the worker."""
    if not _enabled():
        raise HTTPException(
            status_code=400,
            detail="AUDIO_FEATURES_ENABLED=true is required in the environment.",
        )

    from backend.audio_features.worker import (  # noqa: PLC0415
        get_features_worker,
        populate_audio_features_queue,
    )

    conn = get_db_connection()
    try:
        queued = populate_audio_features_queue(conn)
    finally:
        conn.close()

    worker = get_features_worker()
    if worker.is_paused():
        worker.resume()
    if not worker.is_running():
        worker.start()
    return AudioFeaturesActionResponse(
        success=True,
        message=f"Worker running. {queued} new items queued.",
        queued=queued,
    )


@router.post("/pause", response_model=AudioFeaturesActionResponse)
async def pause_worker() -> AudioFeaturesActionResponse:
    from backend.audio_features.worker import get_features_worker  # noqa: PLC0415

    get_features_worker().pause()
    return AudioFeaturesActionResponse(success=True, message="Worker paused")


@router.post("/resume", response_model=AudioFeaturesActionResponse)
async def resume_worker() -> AudioFeaturesActionResponse:
    from backend.audio_features.worker import get_features_worker  # noqa: PLC0415

    get_features_worker().resume()
    return AudioFeaturesActionResponse(success=True, message="Worker resumed")


@router.post("/rescan-paths", response_model=AudioFeaturesActionResponse)
async def rescan_paths() -> AudioFeaturesActionResponse:
    """Re-walk the music library and queue any newly matched tracks."""
    if not _enabled():
        raise HTTPException(
            status_code=400,
            detail="AUDIO_FEATURES_ENABLED=true is required in the environment.",
        )

    from backend.audio_features.path_resolver import resolve_paths_for_tracks  # noqa: PLC0415

    conn = get_db_connection()
    try:
        result = resolve_paths_for_tracks(conn, _music_root())
    finally:
        conn.close()

    return AudioFeaturesActionResponse(
        success=True,
        message=(
            f"Scanned {result['scanned']} tracks, matched {result['matched']}, "
            f"unresolved {result['unresolved']}."
        ),
        matched=result["matched"],
        unresolved=result["unresolved"],
    )


@router.get("/{item_key}", response_model=TrackAudioFeatures)
async def get_features(item_key: str) -> TrackAudioFeatures:
    """Return the stored audio features for a single track."""
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT * FROM track_audio_features WHERE item_key = ?",
            (item_key,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        raise HTTPException(status_code=404, detail="No features stored for this track.")
    # sqlite3.Row iterates VALUES, not keys — explicit .keys() is required here.
    return TrackAudioFeatures(**{
        k: row[k] for k in row.keys() if k != "analysis_version"  # noqa: SIM118
    })


# ---------------------------------------------------------------------------
# DJ Set builder
# ---------------------------------------------------------------------------


class DJSetResponseWithSession(DJSetResponse):
    """Same as DJSetResponse but with a session_id for curate_and_play."""

    session_id: str = ""


@router.post("/dj-set", response_model=DJSetResponseWithSession)
async def build_dj_set(request: DJSetRequest) -> DJSetResponseWithSession:
    """Construct a beatmatched, harmonically-mixed set.

    The response includes a ``session_id`` that maps numbered positions
    (1-based) → Roon item_keys, exactly like ``/api/library/filter``. Pass
    that session_id to ``curate_and_play`` (or the matching MCP tool) to
    play the set on a Roon zone.
    """
    import asyncio  # noqa: PLC0415

    from backend.audio_features.dj_generator import build_dj_set as _build  # noqa: PLC0415

    result = await asyncio.to_thread(
        _build,
        duration_minutes=request.duration_minutes,
        track_count=request.track_count,
        start_bpm=request.start_bpm,
        end_bpm=request.end_bpm,
        energy_curve=request.energy_curve,
        genres=request.genres or None,
        decades=request.decades or None,
        exclude_live=request.exclude_live,
        seed_item_key=request.seed_item_key,
    )

    tracks = [
        Track(
            item_key=t["item_key"],
            title=t["title"],
            artist=t["artist"],
            album=t["album"],
            duration_ms=0,
            year=t.get("year"),
            genres=[],
        )
        for t in result["tracks"]
    ]

    # Store key_map server-side so the standard curate_and_play flow works.
    key_map = {str(i): t["item_key"] for i, t in enumerate(result["tracks"], start=1)}
    session_id = ""
    if key_map:
        session_id = store_session(
            key_map=key_map,
            total_matching=result["total_matching"],
            returned=result["returned"],
        )

    return DJSetResponseWithSession(
        total_matching=result["total_matching"],
        returned=result["returned"],
        tracks=tracks,
        curve=[DJSetCurvePoint(**c) for c in result["curve"]],
        session_id=session_id,
    )
