"""Playlist generation and analysis endpoints."""

import asyncio

from fastapi import APIRouter, HTTPException, Request
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
from backend.dependencies import limiter

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["generate"])


@router.post("/generate/stream")
@limiter.limit("30/hour")
async def generate_playlist_sse(
    request: Request, body: GenerateRequest
) -> StreamingResponse:
    """Generate a playlist with streaming progress updates.

    ``request`` is required by slowapi for rate-key extraction; ``body``
    carries the actual payload (GenerateRequest).
"""
    roon_client = get_roon_client()
    llm_client = get_llm_client()

    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")
    if not llm_client:
        raise HTTPException(status_code=503, detail="LLM not configured")

    seed_track = None
    selected_dimensions = None
    if body.seed_track:
        seed_track = await asyncio.to_thread(
            roon_client.get_track_by_key, body.seed_track.item_key
        )
        if not seed_track:
            raise HTTPException(status_code=404, detail="Seed track not found")
        selected_dimensions = body.seed_track.selected_dimensions

    async def event_stream():
        async for chunk in generate_playlist_stream(
            prompt=body.prompt,
            seed_track=seed_track,
            selected_dimensions=selected_dimensions,
            additional_notes=body.additional_notes,
            refinement_answers=body.refinement_answers,
            genres=body.genres,
            decades=body.decades,
            track_count=body.track_count,
            exclude_live=body.exclude_live,
            max_tracks_to_ai=body.max_tracks_to_ai,
            source_mode=body.source_mode,
            qobuz_percentage=body.qobuz_percentage,
        ):
            yield chunk

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
@limiter.limit("30/hour")
async def analyze_prompt(
    request: Request, body: AnalyzePromptRequest
) -> AnalyzePromptResponse:
    """Analyze a natural language prompt to suggest filters."""
    roon_client = get_roon_client()
    llm_client = get_llm_client()

    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")
    if not llm_client:
        raise HTTPException(status_code=503, detail="LLM not configured")

    try:
        return await do_analyze_prompt(body.prompt)
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
        return await do_analyze_track(track)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")
