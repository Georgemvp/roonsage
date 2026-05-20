"""REST API endpoints for Scheduled Playlist management."""

import asyncio
import json
import logging
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.db import get_connection
from backend.scheduler import _run_schedule

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/schedules", tags=["schedules"])


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class ScheduleFilters(BaseModel):
    genres: list[str] = []
    decades: list[str] = []
    exclude_live: bool = True


class CreateScheduleRequest(BaseModel):
    name: str
    prompt: str
    filters: Optional[ScheduleFilters] = None
    track_count: int = 25
    schedule: str  # cron expression
    zone_name: Optional[str] = None
    save_to_qobuz: bool = True
    qobuz_playlist_id: Optional[str] = None
    enabled: bool = True


class UpdateScheduleRequest(BaseModel):
    name: Optional[str] = None
    prompt: Optional[str] = None
    filters: Optional[ScheduleFilters] = None
    track_count: Optional[int] = None
    schedule: Optional[str] = None
    zone_name: Optional[str] = None
    save_to_qobuz: Optional[bool] = None
    qobuz_playlist_id: Optional[str] = None
    enabled: Optional[bool] = None


def _row_to_dict(row) -> dict:
    """Convert a sqlite3.Row to a plain dict with parsed filters."""
    d = dict(row)
    if d.get("filters"):
        try:
            d["filters"] = json.loads(d["filters"])
        except Exception:
            d["filters"] = {}
    else:
        d["filters"] = {}
    return d


def _validate_cron(expr: str) -> None:
    """Raise HTTPException 400 when *expr* is not a valid 5-field cron string."""
    from backend.scheduler import matches_cron  # noqa: PLC0415
    # matches_cron already handles bad expressions gracefully; we do a stricter check here
    parts = expr.strip().split()
    if len(parts) != 5:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid cron expression {expr!r}: expected 5 fields (minute hour dom month dow)",
        )
    # Dry-run on a known datetime to surface parsing errors
    try:
        matches_cron(expr, datetime(2025, 1, 6, 7, 0))  # Monday 07:00
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Invalid cron expression: {exc}") from exc


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.get("")
async def list_schedules():
    """Return all scheduled playlists ordered by created_at DESC."""
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT * FROM scheduled_playlists ORDER BY created_at DESC"
        ).fetchall()
    return [_row_to_dict(r) for r in rows]


@router.post("", status_code=201)
async def create_schedule(req: CreateScheduleRequest):
    """Create a new scheduled playlist."""
    _validate_cron(req.schedule)

    filters_json = json.dumps(req.filters.model_dump() if req.filters else {})

    with get_connection() as conn:
        cursor = conn.execute(
            """INSERT INTO scheduled_playlists
                   (name, prompt, filters, track_count, schedule,
                    zone_name, save_to_qobuz, qobuz_playlist_id, enabled)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                req.name,
                req.prompt,
                filters_json,
                req.track_count,
                req.schedule,
                req.zone_name,
                1 if req.save_to_qobuz else 0,
                req.qobuz_playlist_id,
                1 if req.enabled else 0,
            ),
        )
        conn.commit()
        new_id = cursor.lastrowid

    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM scheduled_playlists WHERE id=?", (new_id,)
        ).fetchone()

    return _row_to_dict(row)


@router.get("/{schedule_id}")
async def get_schedule(schedule_id: int):
    """Return a single scheduled playlist by ID."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM scheduled_playlists WHERE id=?", (schedule_id,)
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail=f"Schedule {schedule_id} not found")
    return _row_to_dict(row)


@router.put("/{schedule_id}")
async def update_schedule(schedule_id: int, req: UpdateScheduleRequest):
    """Update an existing scheduled playlist."""
    with get_connection() as conn:
        existing = conn.execute(
            "SELECT * FROM scheduled_playlists WHERE id=?", (schedule_id,)
        ).fetchone()
    if not existing:
        raise HTTPException(status_code=404, detail=f"Schedule {schedule_id} not found")

    if req.schedule is not None:
        _validate_cron(req.schedule)

    updates: list[str] = []
    params: list = []

    if req.name is not None:
        updates.append("name=?")
        params.append(req.name)
    if req.prompt is not None:
        updates.append("prompt=?")
        params.append(req.prompt)
    if req.filters is not None:
        updates.append("filters=?")
        params.append(json.dumps(req.filters.model_dump()))
    if req.track_count is not None:
        updates.append("track_count=?")
        params.append(req.track_count)
    if req.schedule is not None:
        updates.append("schedule=?")
        params.append(req.schedule)
    if req.zone_name is not None:
        updates.append("zone_name=?")
        params.append(req.zone_name)
    if req.save_to_qobuz is not None:
        updates.append("save_to_qobuz=?")
        params.append(1 if req.save_to_qobuz else 0)
    if req.qobuz_playlist_id is not None:
        updates.append("qobuz_playlist_id=?")
        params.append(req.qobuz_playlist_id)
    if req.enabled is not None:
        updates.append("enabled=?")
        params.append(1 if req.enabled else 0)

    if updates:
        params.append(schedule_id)
        with get_connection() as conn:
            conn.execute(
                f"UPDATE scheduled_playlists SET {', '.join(updates)} WHERE id=?",  # noqa: S608
                params,
            )
            conn.commit()

    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM scheduled_playlists WHERE id=?", (schedule_id,)
        ).fetchone()
    return _row_to_dict(row)


@router.delete("/{schedule_id}", status_code=204)
async def delete_schedule(schedule_id: int):
    """Delete a scheduled playlist permanently."""
    with get_connection() as conn:
        result = conn.execute(
            "DELETE FROM scheduled_playlists WHERE id=?", (schedule_id,)
        )
        conn.commit()
        if result.rowcount == 0:
            raise HTTPException(status_code=404, detail=f"Schedule {schedule_id} not found")


@router.post("/{schedule_id}/run")
async def run_schedule_now(schedule_id: int):
    """Trigger an immediate run of the scheduled playlist (ignores cron timing)."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM scheduled_playlists WHERE id=?", (schedule_id,)
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail=f"Schedule {schedule_id} not found")

    row_dict = _row_to_dict(row)

    # Run in background so the HTTP response returns immediately
    asyncio.create_task(
        _run_schedule(row_dict),
        name=f"schedule-manual-{schedule_id}",
    )

    return {
        "status": "running",
        "message": f"Schedule {schedule_id!r} ({row_dict['name']}) started in background",
    }


@router.patch("/{schedule_id}/toggle")
async def toggle_schedule(schedule_id: int):
    """Toggle the enabled/disabled state of a scheduled playlist."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT enabled FROM scheduled_playlists WHERE id=?", (schedule_id,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail=f"Schedule {schedule_id} not found")

        new_state = 0 if row["enabled"] else 1
        conn.execute(
            "UPDATE scheduled_playlists SET enabled=? WHERE id=?",
            (new_state, schedule_id),
        )
        conn.commit()

    return {"id": schedule_id, "enabled": bool(new_state)}
