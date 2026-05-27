"""REST endpoints for mood tagging (v13.2).

Routes
------
POST /api/mood/generate          trigger K-Means + CLAP mood-text matching
GET  /api/mood/status            current run state
GET  /api/mood/tags              list moods + per-mood track counts
GET  /api/mood/tracks?mood=...   tracks for a single mood + session_id
GET  /api/mood/track/{track_id}  mood tags for one track
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from backend.audio_features import mood_tagger
from backend.config import get_clap_enabled
from backend.db import get_db_connection
from backend.filter_sessions import store_session

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/mood", tags=["mood"])


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------


class MoodGenerateResponse(BaseModel):
    started: bool
    message: str


class MoodStatusResponse(BaseModel):
    status: str
    started_at: str | None = None
    finished_at: str | None = None
    n_tracks: int = 0
    n_clusters: int = 0
    error_message: str | None = None
    available_moods: list[str] = []


class MoodTagCount(BaseModel):
    mood: str
    track_count: int


class MoodTagsResponse(BaseModel):
    moods: list[MoodTagCount]
    total_tagged: int


class MoodTrack(BaseModel):
    item_key: str
    title: str
    artist: str
    album: str
    year: int | None = None
    genres: str | None = None
    mood_primary: str
    mood_secondary: str | None = None
    confidence: float | None = None


class MoodTracksResponse(BaseModel):
    mood: str
    total: int
    tracks: list[MoodTrack]
    session_id: str | None = None


class TrackMoodResponse(BaseModel):
    track_id: str
    mood_primary: str
    mood_secondary: str | None = None
    confidence: float | None = None
    cluster_id: int | None = None
    updated_at: str | None = None


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


def _current_status() -> dict[str, Any]:
    conn = get_db_connection()
    try:
        return mood_tagger.get_status(conn)
    finally:
        conn.close()


def _run_sync() -> None:
    conn = get_db_connection()
    try:
        mood_tagger.run_mood_tagging(conn=conn)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/generate", response_model=MoodGenerateResponse)
async def trigger_generate() -> MoodGenerateResponse:
    """Kick off a mood-tag generation run in the background.

    Requires CLAP_ENABLED=true (mood tags are derived from CLAP audio
    embeddings, so /api/clap/analyze must have populated ``clap_embeddings``
    first). Poll ``/api/mood/status`` for completion.
    """
    if not get_clap_enabled():
        raise HTTPException(
            status_code=503,
            detail="CLAP_ENABLED=true required (mood tags rely on CLAP embeddings).",
        )

    if _current_status().get("status") == "running":
        raise HTTPException(409, "Mood tag generation already running")

    asyncio.create_task(  # noqa: RUF006 - background lifetime bounded by run
        asyncio.to_thread(_run_sync), name="mood-tagging"
    )
    return MoodGenerateResponse(
        started=True,
        message="Mood tag generation started. Poll /api/mood/status for progress.",
    )


@router.get("/status", response_model=MoodStatusResponse)
async def get_status() -> MoodStatusResponse:
    s = _current_status()
    return MoodStatusResponse(
        status=s.get("status", "idle"),
        started_at=s.get("started_at"),
        finished_at=s.get("finished_at"),
        n_tracks=s.get("n_tracks") or 0,
        n_clusters=s.get("n_clusters") or 0,
        error_message=s.get("error_message"),
        available_moods=list(mood_tagger.DEFAULT_MOODS),
    )


@router.get("/tags", response_model=MoodTagsResponse)
async def list_tags() -> MoodTagsResponse:
    """List every mood that has at least one tagged track + the counts."""
    conn = get_db_connection()
    try:
        rows = mood_tagger.get_mood_tag_counts(conn)
    finally:
        conn.close()
    total = sum(r["track_count"] for r in rows)
    return MoodTagsResponse(
        moods=[MoodTagCount(**r) for r in rows],
        total_tagged=total,
    )


@router.get("/tracks", response_model=MoodTracksResponse)
async def get_tracks(
    mood: str = Query(..., min_length=1),
    limit: int = Query(200, ge=1, le=1000),
    include_secondary: bool = Query(True),
) -> MoodTracksResponse:
    """Return tracks for the given mood + a curate-ready ``session_id``."""
    conn = get_db_connection()
    try:
        rows = mood_tagger.get_tracks_for_mood(
            conn, mood, limit=limit, include_secondary=include_secondary
        )
    finally:
        conn.close()

    # Build a key_map so the frontend / MCP can hand the result straight into
    # curate_and_play (same flow as filter_tracks).
    key_map = {str(i): r["item_key"] for i, r in enumerate(rows, start=1)}
    session_id = store_session(key_map, len(rows), len(rows)) if rows else None

    return MoodTracksResponse(
        mood=mood,
        total=len(rows),
        tracks=[MoodTrack(**r) for r in rows],
        session_id=session_id,
    )


@router.get("/track/{track_id}", response_model=TrackMoodResponse)
async def get_track_mood(track_id: str) -> TrackMoodResponse:
    conn = get_db_connection()
    try:
        row = mood_tagger.get_mood_for_track(conn, track_id)
    finally:
        conn.close()
    if not row:
        raise HTTPException(404, f"No mood tag for track {track_id}")
    return TrackMoodResponse(**row)
