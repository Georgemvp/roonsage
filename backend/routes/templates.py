"""Playlist template endpoints for RoonSage.

GET  /api/templates              — list all templates (built-in + user)
GET  /api/templates/{id}         — get a single template
POST /api/templates              — create/update a user template
DELETE /api/templates/{id}       — delete a user template (built-in: 403)
POST /api/templates/{id}/generate — generate a playlist from a template
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from starlette.responses import StreamingResponse

from backend.dependencies import limiter
from backend.generator import generate_playlist_stream
from backend.llm_client import get_llm_client
from backend.roon_client import get_roon_client
from backend.templates import (
    PlaylistTemplate,
    TemplateFilters,
    delete_user_template,
    get_all_templates,
    get_template,
    save_user_template,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/templates", tags=["templates"])


# ---------------------------------------------------------------------------
# Request / Response schemas
# ---------------------------------------------------------------------------


class TemplateResponse(BaseModel):
    """Wire representation of a template returned by the API."""

    id: str
    name: str
    description: str
    icon: str
    category: str
    prompt: str
    filters: TemplateFilters
    track_count: int
    is_builtin: bool


class CreateTemplateRequest(BaseModel):
    """Payload for creating or updating a user template."""

    id: str = Field(..., pattern=r"^[a-z0-9][a-z0-9\-]{1,62}$")
    name: str = Field(..., min_length=1, max_length=80)
    description: str = Field("", max_length=200)
    icon: str = Field("🎵", max_length=8)
    category: str = Field("My Templates", max_length=40)
    prompt: str = Field(..., min_length=10, max_length=4000)
    filters: TemplateFilters = Field(default_factory=TemplateFilters)
    track_count: int = Field(25, ge=5, le=200)


class GenerateFromTemplateRequest(BaseModel):
    """Optional overrides when generating from a template."""

    genres: list[str] | None = None
    decades: list[str] | None = None
    track_count: int | None = None
    exclude_live: bool | None = None
    source_mode: str | None = None
    qobuz_percentage: int | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _to_response(t: PlaylistTemplate) -> TemplateResponse:
    return TemplateResponse(
        id=t.id,
        name=t.name,
        description=t.description,
        icon=t.icon,
        category=t.category,
        prompt=t.prompt,
        filters=t.filters,
        track_count=t.track_count,
        is_builtin=t.is_builtin,
    )


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("", response_model=list[TemplateResponse])
async def list_templates() -> list[TemplateResponse]:
    """List all playlist templates (built-in + user-created)."""
    return [_to_response(t) for t in get_all_templates()]


@router.get("/{template_id}", response_model=TemplateResponse)
async def get_template_by_id(template_id: str) -> TemplateResponse:
    """Get a single playlist template by ID."""
    t = get_template(template_id)
    if t is None:
        raise HTTPException(status_code=404, detail=f"Template '{template_id}' not found")
    return _to_response(t)


@router.post("", response_model=TemplateResponse, status_code=201)
async def create_template(body: CreateTemplateRequest) -> TemplateResponse:
    """Create or update a user-defined playlist template."""
    template = PlaylistTemplate(
        id=body.id,
        name=body.name,
        description=body.description,
        icon=body.icon,
        category=body.category,
        prompt=body.prompt,
        filters=body.filters,
        track_count=body.track_count,
        is_builtin=False,
    )
    try:
        saved = save_user_template(template)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _to_response(saved)


@router.delete("/{template_id}", status_code=204)
async def delete_template(template_id: str) -> None:
    """Delete a user-created template.  Built-in templates cannot be deleted."""
    try:
        found = delete_user_template(template_id)
    except ValueError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    if not found:
        raise HTTPException(status_code=404, detail=f"Template '{template_id}' not found")


@router.post("/{template_id}/generate")
@limiter.limit("30/hour")
async def generate_from_template(
    request: Request,
    template_id: str,
    body: GenerateFromTemplateRequest | None = None,
) -> StreamingResponse:
    """Generate a playlist from a template, streaming SSE progress events.

    The template's prompt, filters, and track_count are used as defaults.
    Any fields in the request body override the template defaults.
    """
    t = get_template(template_id)
    if t is None:
        raise HTTPException(status_code=404, detail=f"Template '{template_id}' not found")

    roon_client = get_roon_client()
    llm_client = get_llm_client()

    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")
    if not llm_client:
        raise HTTPException(status_code=503, detail="LLM not configured")

    # Apply template defaults, then override with any explicit request fields
    overrides = body or GenerateFromTemplateRequest()
    genres = overrides.genres if overrides.genres is not None else t.filters.genres
    decades = overrides.decades if overrides.decades is not None else t.filters.decades
    track_count = overrides.track_count if overrides.track_count is not None else t.track_count
    exclude_live = overrides.exclude_live if overrides.exclude_live is not None else t.filters.exclude_live
    source_mode = overrides.source_mode if overrides.source_mode is not None else t.filters.source_mode
    qobuz_percentage = overrides.qobuz_percentage if overrides.qobuz_percentage is not None else t.filters.qobuz_percentage

    logger.info(
        "TEMPLATE GENERATE: id=%s name=%r tracks=%d source=%s",
        t.id, t.name, track_count, source_mode,
    )

    def event_stream():
        yield from generate_playlist_stream(
            prompt=t.prompt,
            seed_track=None,
            selected_dimensions=None,
            additional_notes=None,
            refinement_answers=None,
            genres=genres,
            decades=decades,
            track_count=track_count,
            exclude_live=exclude_live,
            max_tracks_to_ai=500,
            source_mode=source_mode,
            qobuz_percentage=qobuz_percentage,
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
