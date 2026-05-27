"""REST endpoints for lyrics extraction + semantic search (v13.0)."""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.config import get_lyrics_search_enabled
from backend.db import get_db_connection
from backend.lyrics import cross_modal, embedder, mood_lyrics, search

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/lyrics", tags=["lyrics"])


class LyricsAnalyzeResponse(BaseModel):
    started: bool
    message: str


class LyricsStatusResponse(BaseModel):
    enabled: bool
    model_loaded: bool
    status: str
    started_at: str | None = None
    finished_at: str | None = None
    n_total: int = 0
    n_extracted: int = 0
    n_embedded: int = 0
    n_no_lyrics: int = 0
    n_failed: int = 0
    error_message: str | None = None


class LyricsSearchRequest(BaseModel):
    query: str = Field(..., min_length=1)
    limit: int = Field(25, ge=1, le=200)


class LyricsSearchPlayRequest(LyricsSearchRequest):
    zone_id: str
    mode: Literal["replace", "append"] = "replace"


class LyricsTrack(BaseModel):
    item_key: str
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    year: int | None = None
    similarity: float | None = None
    snippet: str | None = None


class LyricsSearchResponse(BaseModel):
    query: str
    results: list[LyricsTrack]


class LyricsSearchPlayResponse(LyricsSearchResponse):
    playback_started: bool
    zone_id: str
    queue_response: dict[str, Any] = {}


class LyricsTrackDetail(BaseModel):
    item_key: str
    lyrics: str | None = None
    language: str | None = None
    extracted_at: str | None = None


def _require_enabled() -> None:
    if not get_lyrics_search_enabled():
        raise HTTPException(503, "LYRICS_SEARCH_ENABLED=true required")


def _run_batch_sync() -> None:
    conn = get_db_connection()
    try:
        embedder.batch_embed_lyrics(conn)
    finally:
        conn.close()


@router.post("/analyze", response_model=LyricsAnalyzeResponse)
async def start_analyze() -> LyricsAnalyzeResponse:
    _require_enabled()
    conn = get_db_connection()
    try:
        if embedder.get_status(conn).get("status") == "running":
            raise HTTPException(409, "lyrics analysis already running")
    finally:
        conn.close()

    tok, model = embedder.get_model_pair()
    if tok is None or model is None:
        raise HTTPException(503, "Lyrics model could not be loaded")

    asyncio.create_task(  # noqa: RUF006
        asyncio.to_thread(_run_batch_sync), name="lyrics-batch"
    )
    return LyricsAnalyzeResponse(started=True, message="Lyrics analysis started.")


@router.get("/status", response_model=LyricsStatusResponse)
async def status() -> LyricsStatusResponse:
    conn = get_db_connection()
    try:
        s = embedder.get_status(conn)
    finally:
        conn.close()
    return LyricsStatusResponse(
        enabled=get_lyrics_search_enabled(),
        model_loaded=embedder._model is not None and embedder._tokenizer is not None,
        status=s.get("status", "idle"),
        started_at=s.get("started_at"),
        finished_at=s.get("finished_at"),
        n_total=s.get("n_total") or 0,
        n_extracted=s.get("n_extracted") or 0,
        n_embedded=s.get("n_embedded") or 0,
        n_no_lyrics=s.get("n_no_lyrics") or 0,
        n_failed=s.get("n_failed") or 0,
        error_message=s.get("error_message"),
    )


@router.post("/search", response_model=LyricsSearchResponse)
async def do_search(req: LyricsSearchRequest) -> LyricsSearchResponse:
    _require_enabled()
    tok, model = embedder.get_model_pair()
    if tok is None or model is None:
        raise HTTPException(503, "Lyrics model not loaded")

    def _do():
        conn = get_db_connection()
        try:
            return search.search_lyrics(conn, req.query, req.limit)
        finally:
            conn.close()

    out = await asyncio.to_thread(_do)
    return LyricsSearchResponse(
        query=req.query,
        results=[LyricsTrack(**r) for r in out],
    )


@router.post("/search/play", response_model=LyricsSearchPlayResponse)
async def search_and_play(req: LyricsSearchPlayRequest) -> LyricsSearchPlayResponse:
    inner = await do_search(LyricsSearchRequest(query=req.query, limit=req.limit))

    from backend.roon_client import get_roon_client  # noqa: PLC0415

    client = get_roon_client()
    if client is None or not client.is_connected():
        raise HTTPException(503, "Roon not connected")

    item_keys = [t.item_key for t in inner.results]
    try:
        result = await asyncio.to_thread(
            client.play_tracks, req.zone_id, item_keys, req.mode
        )
        started = bool(getattr(result, "success", False))
        payload = result.model_dump() if hasattr(result, "model_dump") else {}
    except Exception as exc:
        logger.exception("lyrics playback failed")
        started = False
        payload = {"error": str(exc)}

    return LyricsSearchPlayResponse(
        query=req.query,
        results=inner.results,
        playback_started=started,
        zone_id=req.zone_id,
        queue_response=payload,
    )


@router.get("/track/{item_key}", response_model=LyricsTrackDetail)
async def get_track(item_key: str) -> LyricsTrackDetail:
    conn = get_db_connection()
    try:
        row = search.get_track_lyrics(conn, item_key)
    finally:
        conn.close()
    if not row:
        raise HTTPException(404, f"no lyrics record for {item_key}")
    return LyricsTrackDetail(**row)


# ---------------------------------------------------------------------------
# Lyric moods + cross-modal (v13.x)
# ---------------------------------------------------------------------------


class MoodTrack(BaseModel):
    item_key: str
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    year: int | None = None
    similarity: float | None = None
    mood: str | None = None


class MoodPlaylistResponse(BaseModel):
    mood: str
    results: list[MoodTrack]


class MoodInfo(BaseModel):
    mood: str
    track_count: int


class MoodsListResponse(BaseModel):
    moods: list[MoodInfo]


class CrossModalTrack(BaseModel):
    item_key: str
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    year: int | None = None
    lyrics_similarity: float | None = None
    clap_similarity: float | None = None
    combined_similarity: float | None = None


class CrossModalResponse(BaseModel):
    seed_item_key: str
    results: list[CrossModalTrack]


class ThematicMood(BaseModel):
    mood: str
    score: float


class ThematicTasteResponse(BaseModel):
    moods: list[ThematicMood]
    n_source_tracks: int
    message: str | None = None


@router.get("/moods", response_model=MoodsListResponse)
async def list_moods() -> MoodsListResponse:
    """Available lyric moods with a per-mood track-count estimate."""
    _require_enabled()

    def _do() -> list[dict[str, Any]]:
        conn = get_db_connection()
        try:
            return mood_lyrics.get_moods_with_counts(conn)
        finally:
            conn.close()

    out = await asyncio.to_thread(_do)
    return MoodsListResponse(moods=[MoodInfo(**m) for m in out])


@router.get("/mood-playlist", response_model=MoodPlaylistResponse)
async def mood_playlist(mood: str, limit: int = 25) -> MoodPlaylistResponse:
    """Generate a playlist whose lyrics best match a given mood centroid."""
    _require_enabled()
    if mood not in mood_lyrics.MOOD_QUERIES:
        raise HTTPException(
            400,
            f"Unknown mood '{mood}'. Available: {', '.join(mood_lyrics.available_moods())}",
        )
    if limit < 1 or limit > 200:
        raise HTTPException(400, "limit must be between 1 and 200")

    def _do() -> list[dict[str, Any]]:
        conn = get_db_connection()
        try:
            return mood_lyrics.get_lyrics_mood_playlist(mood, limit, conn)
        finally:
            conn.close()

    out = await asyncio.to_thread(_do)
    return MoodPlaylistResponse(
        mood=mood,
        results=[MoodTrack(**r) for r in out],
    )


@router.get("/cross-modal/{item_key}", response_model=CrossModalResponse)
async def cross_modal_endpoint(item_key: str, limit: int = 20) -> CrossModalResponse:
    """Tracks similar in BOTH sound and lyrics to the given seed track."""
    _require_enabled()
    if limit < 1 or limit > 200:
        raise HTTPException(400, "limit must be between 1 and 200")

    def _do() -> list[dict[str, Any]]:
        conn = get_db_connection()
        try:
            return cross_modal.cross_modal_similarity(item_key, conn, limit)
        finally:
            conn.close()

    out = await asyncio.to_thread(_do)
    if not out:
        # Distinguish "seed not analysed" from "no matches found".
        conn = get_db_connection()
        try:
            has_lyr = conn.execute(
                "SELECT 1 FROM lyrics_embeddings WHERE item_key = ?", (item_key,)
            ).fetchone()
            has_clap = conn.execute(
                "SELECT 1 FROM clap_embeddings WHERE item_key = ?", (item_key,)
            ).fetchone()
        finally:
            conn.close()
        if not has_lyr or not has_clap:
            raise HTTPException(
                404,
                f"Track {item_key} is missing a "
                f"{'lyrics' if not has_lyr else 'CLAP'} embedding.",
            )

    return CrossModalResponse(
        seed_item_key=item_key,
        results=[CrossModalTrack(**r) for r in out],
    )


@router.get("/thematic-taste", response_model=ThematicTasteResponse)
async def thematic_taste_endpoint() -> ThematicTasteResponse:
    """User's mood preferences derived from the lyrics of their top-played tracks."""
    _require_enabled()

    def _do() -> dict[str, Any]:
        conn = get_db_connection()
        try:
            return cross_modal.get_thematic_taste(conn)
        finally:
            conn.close()

    out = await asyncio.to_thread(_do)
    return ThematicTasteResponse(
        moods=[ThematicMood(**m) for m in out.get("moods", [])],
        n_source_tracks=out.get("n_source_tracks", 0),
        message=out.get("message"),
    )
