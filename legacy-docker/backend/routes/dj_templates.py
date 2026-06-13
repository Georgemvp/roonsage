"""DJ-set template endpoints.

GET    /api/dj-templates              — list all (built-in + user)
GET    /api/dj-templates/{id}         — fetch one
POST   /api/dj-templates              — create / update a user template
DELETE /api/dj-templates/{id}         — delete a user template (403 for built-in)
POST   /api/dj-templates/{id}/build   — build a DJ set from this template
"""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from backend.dj_templates import (
    DJTemplate,
    delete_user_dj_template,
    get_all_dj_templates,
    get_dj_template,
    save_user_dj_template,
)
from backend.filter_sessions import store_session
from backend.models import DJSetCurvePoint, Track

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/dj-templates", tags=["dj-templates"])


# ---------------------------------------------------------------------------
# Wire models
# ---------------------------------------------------------------------------


class DJTemplateResponse(BaseModel):
    id: str
    name: str
    description: str
    icon: str
    category: str
    duration_minutes: int
    track_count: int | None
    start_bpm: float
    end_bpm: float
    energy_curve: str
    start_mood: str | None
    end_mood: str | None
    genres: list[str]
    decades: list[str]
    exclude_live: bool
    is_builtin: bool


class CreateDJTemplateRequest(BaseModel):
    id: str = Field(..., pattern=r"^[a-z0-9][a-z0-9\-]{1,62}$")
    name: str = Field(..., min_length=1, max_length=80)
    description: str = Field("", max_length=200)
    icon: str = Field("🎚️", max_length=8)
    category: str = Field("My DJ Templates", max_length=40)
    duration_minutes: int = Field(60, ge=10, le=240)
    track_count: int | None = Field(None, ge=3, le=120)
    start_bpm: float = Field(110.0, ge=40, le=220)
    end_bpm: float = Field(128.0, ge=40, le=220)
    energy_curve: str = Field("ramp_up")
    start_mood: str | None = None
    end_mood: str | None = None
    genres: list[str] = []
    decades: list[str] = []
    exclude_live: bool = True


class DJTemplateBuildResponse(BaseModel):
    total_matching: int
    returned: int
    tracks: list[Track]
    curve: list[DJSetCurvePoint] = []
    session_id: str = ""
    template_id: str
    template_name: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _to_response(t: DJTemplate) -> DJTemplateResponse:
    return DJTemplateResponse(**t.model_dump())


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("", response_model=list[DJTemplateResponse])
async def list_dj_templates() -> list[DJTemplateResponse]:
    return [_to_response(t) for t in get_all_dj_templates()]


@router.get("/{template_id}", response_model=DJTemplateResponse)
async def get_dj_template_by_id(template_id: str) -> DJTemplateResponse:
    t = get_dj_template(template_id)
    if t is None:
        raise HTTPException(status_code=404, detail=f"DJ template '{template_id}' not found")
    return _to_response(t)


@router.post("", response_model=DJTemplateResponse, status_code=201)
async def create_dj_template(body: CreateDJTemplateRequest) -> DJTemplateResponse:
    template = DJTemplate(
        **body.model_dump(),
        is_builtin=False,
    )
    try:
        saved = save_user_dj_template(template)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _to_response(saved)


@router.delete("/{template_id}", status_code=204)
async def delete_dj_template(template_id: str) -> None:
    try:
        found = delete_user_dj_template(template_id)
    except ValueError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    if not found:
        raise HTTPException(status_code=404, detail=f"DJ template '{template_id}' not found")


@router.post("/{template_id}/build", response_model=DJTemplateBuildResponse)
async def build_dj_template(template_id: str) -> DJTemplateBuildResponse:
    """Build a DJ set from a template.

    Returns the same shape as ``/api/audio-features/dj-set`` (plus the
    template ID/name) so the frontend can reuse its rendering + playback
    paths verbatim.
    """
    t = get_dj_template(template_id)
    if t is None:
        raise HTTPException(status_code=404, detail=f"DJ template '{template_id}' not found")

    from backend.audio_features.dj_generator import build_dj_set as _build  # noqa: PLC0415

    result = await asyncio.to_thread(
        _build,
        duration_minutes=t.duration_minutes,
        track_count=t.track_count,
        start_bpm=t.start_bpm,
        end_bpm=t.end_bpm,
        energy_curve=t.energy_curve,
        genres=t.genres or None,
        decades=t.decades or None,
        exclude_live=t.exclude_live,
        start_mood=t.start_mood,
        end_mood=t.end_mood,
    )

    tracks = [
        Track(
            item_key=r["item_key"],
            title=r["title"],
            artist=r["artist"],
            album=r["album"],
            duration_ms=0,
            year=r.get("year"),
            genres=[],
        )
        for r in result["tracks"]
    ]

    key_map = {str(i): r["item_key"] for i, r in enumerate(result["tracks"], start=1)}
    session_id = ""
    if key_map:
        session_id = store_session(
            key_map=key_map,
            total_matching=result["total_matching"],
            returned=result["returned"],
        )

    return DJTemplateBuildResponse(
        total_matching=result["total_matching"],
        returned=result["returned"],
        tracks=tracks,
        curve=[DJSetCurvePoint(**c) for c in result["curve"]],
        session_id=session_id,
        template_id=t.id,
        template_name=t.name,
    )
