"""Playlist generation and analysis endpoints."""

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from starlette.responses import StreamingResponse

import logging

from backend.analyzer import analyze_prompt as do_analyze_prompt, analyze_track as do_analyze_track
from backend.generator import generate_playlist_stream
from backend.llm_client import get_llm_client
from backend.models import (
    AnalyzePromptRequest,
    AnalyzePromptResponse,
    AnalyzeTrackRequest,
    AnalyzeTrackResponse,
    GenerateRequest,
    Track,
)
from backend.roon_client import get_roon_client
from backend.dependencies import check_rate_limit

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["generate"])


@router.post("/generate/stream", dependencies=[Depends(check_rate_limit)])
async def generate_playlist_sse(request: GenerateRequest) -> StreamingResponse:
    """Generate a playlist with streaming progress updates."""
    roon_client = get_roon_client()
    llm_client = get_llm_client()

    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")
    if not llm_client:
        raise HTTPException(status_code=503, detail="LLM not configured")

    seed_track = None
    selected_dimensions = None
    if request.seed_track:
        seed_track = await asyncio.to_thread(
            roon_client.get_track_by_key, request.seed_track.item_key
        )
        if not seed_track:
            raise HTTPException(status_code=404, detail="Seed track not found")
        selected_dimensions = request.seed_track.selected_dimensions

    def event_stream():
        yield from generate_playlist_stream(
            prompt=request.prompt,
            seed_track=seed_track,
            selected_dimensions=selected_dimensions,
            additional_notes=request.additional_notes,
            refinement_answers=request.refinement_answers,
            genres=request.genres,
            decades=request.decades,
            track_count=request.track_count,
            exclude_live=request.exclude_live,
            max_tracks_to_ai=request.max_tracks_to_ai,
            source_mode=request.source_mode,
            qobuz_percentage=request.qobuz_percentage,
        )

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.post("/analyze/prompt", response_model=AnalyzePromptResponse)
async def analyze_prompt(request: AnalyzePromptRequest) -> AnalyzePromptResponse:
    """Analyze a natural language prompt to suggest filters."""
    roon_client = get_roon_client()
    llm_client = get_llm_client()

    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")
    if not llm_client:
        raise HTTPException(status_code=503, detail="LLM not configured")

    try:
        return await asyncio.to_thread(do_analyze_prompt, request.prompt)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")


@router.post("/analyze/track", response_model=AnalyzeTrackResponse)
async def analyze_track(request: AnalyzeTrackRequest) -> AnalyzeTrackResponse:
    """Analyze a seed track for dimensions.

    Builds the Track object from metadata provided in the request body when
    available (populated by the frontend from SQLite search results).
    Falls back to a Roon Browse API lookup only when metadata is absent —
    but note that the Browse API returns navigation items (title="Library")
    instead of real track metadata, so the metadata path is strongly preferred.
    """
    llm_client = get_llm_client()
    if not llm_client:
        raise HTTPException(status_code=503, detail="LLM not configured")

    # Prefer metadata supplied directly in the request over a Roon Browse lookup.
    if request.title and request.artist:
        logger.info(
            "analyze_track: using request metadata for %r by %r",
            request.title,
            request.artist,
        )
        track = Track(
            item_key=request.item_key,
            title=request.title,
            artist=request.artist,
            album=request.album or "Unknown Album",
            duration_ms=request.duration_ms,
            year=request.year,
            genres=request.genres,
        )
    else:
        # Fallback: fetch from Roon Browse API (may return incomplete metadata)
        roon_client = get_roon_client()
        if not roon_client or not roon_client.is_connected():
            raise HTTPException(status_code=503, detail="Roon not connected")
        logger.info(
            "analyze_track: no metadata in request, falling back to Roon lookup for key %r",
            request.item_key,
        )
        track = await asyncio.to_thread(roon_client.get_track_by_key, request.item_key)
        if not track:
            raise HTTPException(status_code=404, detail="Track not found")

    try:
        return await asyncio.to_thread(do_analyze_track, track)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")
