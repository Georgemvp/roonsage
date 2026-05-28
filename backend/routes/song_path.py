"""REST endpoints for song-path finding (v13.0).

Routes
------
POST /api/song-path           find a smooth bridge between two tracks
POST /api/song-path/play      same, then queue the path to a Roon zone
"""

from __future__ import annotations

import logging
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.audio_features import song_path
from backend.db import get_db_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/song-path", tags=["song-path"])


VALID_MOODS = frozenset(
    {"calm", "energetic", "happy", "melancholic", "aggressive", "dreamy", "groovy", "dark"}
)


class SongPathRequest(BaseModel):
    from_track_id: str = Field(..., description="item_key of the start track")
    to_track_id: str = Field(..., description="item_key of the end track")
    max_steps: int = Field(10, ge=2, le=50)
    method: Literal["features", "greedy", "graph", "clap", "hybrid"] = Field(
        "features",
        description=(
            "Distance space + algorithm. "
            "'features' (default, alias 'greedy'): greedy walk over the 6-dim "
            "audio-feature vector. 'graph': Dijkstra over a feature k-NN graph. "
            "'clap': Dijkstra over a k-NN graph of CLAP audio embeddings — "
            "richer sonic similarity. 'hybrid': Dijkstra over a blend of CLAP "
            "cosine distance and feature distance."
        ),
    )
    mood: str | None = Field(None, description="Optional mood bias for the path")


class SongPathPlayRequest(SongPathRequest):
    zone_id: str
    mode: Literal["replace", "append"] = "replace"


class SongPathTrack(BaseModel):
    item_key: str
    title: str
    artist: str
    album: str
    year: int | None = None
    genres: str | None = None
    bpm: float | None = None
    energy: float | None = None
    danceability: float | None = None
    valence: float | None = None
    instrumentalness: float | None = None
    acousticness: float | None = None
    camelot: str | None = None
    key_root: str | None = None
    key_mode: str | None = None
    transition_dist: float | None = None


class SongPathResponse(BaseModel):
    method: str
    steps: int
    path: list[SongPathTrack]


class SongPathPlayResponse(SongPathResponse):
    playback_started: bool
    zone_id: str
    queue_response: dict[str, Any] = {}


def _has_clap_embeddings(conn) -> bool:
    row = conn.execute("SELECT 1 FROM clap_embeddings LIMIT 1").fetchone()
    return row is not None


def _find_path(req: SongPathRequest) -> list[dict]:
    mood = req.mood if req.mood and req.mood in VALID_MOODS else None
    conn = get_db_connection()
    try:
        if req.method in ("clap", "hybrid"):
            if not _has_clap_embeddings(conn):
                raise HTTPException(
                    status_code=400,
                    detail=(
                        f"method={req.method!r} requires CLAP embeddings — "
                        "enable CLAP_ENABLED and run /api/clap-search/analyze first."
                    ),
                )
            if mood is not None:
                logger.info("Mood bias is ignored for method=%s", req.method)
            if req.method == "clap":
                return song_path.find_song_path_clap(
                    conn, req.from_track_id, req.to_track_id, req.max_steps
                )
            return song_path.find_song_path_hybrid(
                conn, req.from_track_id, req.to_track_id, req.max_steps
            )
        if req.method == "graph":
            return song_path.find_song_path_graph(
                conn, req.from_track_id, req.to_track_id, req.max_steps, mood=mood
            )
        # "features" and legacy "greedy" both use the greedy walk
        return song_path.find_song_path(
            conn, req.from_track_id, req.to_track_id, req.max_steps, mood=mood
        )
    finally:
        conn.close()


@router.post("", response_model=SongPathResponse)
async def find_path(req: SongPathRequest) -> SongPathResponse:
    """Compute the smoothest sonic path between two tracks."""
    try:
        path = _find_path(req)
    except KeyError as exc:
        raise HTTPException(
            status_code=400,
            detail=str(exc) + " (run audio-features analysis first)",
        ) from exc

    if not path:
        raise HTTPException(
            status_code=404,
            detail="No path could be computed — are both tracks fully analyzed?",
        )

    return SongPathResponse(
        method=req.method,
        steps=len(path),
        path=[SongPathTrack(**t) for t in path],
    )


@router.post("/play", response_model=SongPathPlayResponse)
async def find_and_play(req: SongPathPlayRequest) -> SongPathPlayResponse:
    """Find the path and immediately queue it on the given Roon zone."""
    try:
        path = _find_path(req)
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    if not path:
        raise HTTPException(status_code=404, detail="Path not found")

    import asyncio  # noqa: PLC0415

    from backend.roon_client import get_roon_client  # noqa: PLC0415

    client = get_roon_client()
    if client is None or not client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    item_keys = [t["item_key"] for t in path]
    try:
        result = await asyncio.to_thread(
            client.play_tracks, req.zone_id, item_keys, req.mode
        )
        started = bool(getattr(result, "success", False))
        payload = result.model_dump() if hasattr(result, "model_dump") else {}
    except Exception as exc:
        logger.exception("Song-path playback failed")
        payload = {"error": str(exc)}
        started = False

    return SongPathPlayResponse(
        method=req.method,
        steps=len(path),
        path=[SongPathTrack(**t) for t in path],
        playback_started=started,
        zone_id=req.zone_id,
        queue_response=payload,
    )
