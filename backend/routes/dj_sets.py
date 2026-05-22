"""CRUD endpoints for saved DJ sets."""

from __future__ import annotations

import json
import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.db import get_db_connection

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/dj-sets", tags=["dj-sets"])


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------

class DJSetSaveRequest(BaseModel):
    name: str
    duration_minutes: int = 60
    start_bpm: float | None = None
    end_bpm: float | None = None
    start_mood: str | None = None
    end_mood: str | None = None
    genres: list[str] = []
    tracks: list[dict] = []
    curve: list[dict] = []


class DJSetListItem(BaseModel):
    id: int
    name: str
    created_at: str
    duration_minutes: int
    track_count: int
    start_bpm: float | None
    end_bpm: float | None
    start_mood: str | None
    end_mood: str | None
    genres: list[str]
    tracks: list[dict]
    curve: list[dict]


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("", response_model=list[DJSetListItem])
async def list_dj_sets() -> list[DJSetListItem]:
    conn = get_db_connection()
    try:
        rows = conn.execute(
            "SELECT * FROM dj_sets ORDER BY created_at DESC"
        ).fetchall()
    finally:
        conn.close()
    return [
        DJSetListItem(
            id=r["id"],
            name=r["name"],
            created_at=r["created_at"],
            duration_minutes=r["duration_minutes"],
            track_count=r["track_count"],
            start_bpm=r["start_bpm"],
            end_bpm=r["end_bpm"],
            start_mood=r["start_mood"],
            end_mood=r["end_mood"],
            genres=json.loads(r["genres_json"] or "[]"),
            tracks=json.loads(r["tracks_json"] or "[]"),
            curve=json.loads(r["curve_json"] or "[]"),
        )
        for r in rows
    ]


@router.post("", response_model=DJSetListItem, status_code=201)
async def save_dj_set(req: DJSetSaveRequest) -> DJSetListItem:
    conn = get_db_connection()
    try:
        cur = conn.execute(
            """INSERT INTO dj_sets
               (name, duration_minutes, track_count,
                start_bpm, end_bpm, start_mood, end_mood,
                genres_json, tracks_json, curve_json)
               VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (
                req.name.strip() or "DJ Set",
                req.duration_minutes,
                len(req.tracks),
                req.start_bpm,
                req.end_bpm,
                req.start_mood,
                req.end_mood,
                json.dumps(req.genres),
                json.dumps(req.tracks),
                json.dumps(req.curve),
            ),
        )
        row_id = cur.lastrowid
        conn.commit()
        row = conn.execute("SELECT * FROM dj_sets WHERE id=?", (row_id,)).fetchone()
    finally:
        conn.close()
    return DJSetListItem(
        id=row["id"],
        name=row["name"],
        created_at=row["created_at"],
        duration_minutes=row["duration_minutes"],
        track_count=row["track_count"],
        start_bpm=row["start_bpm"],
        end_bpm=row["end_bpm"],
        start_mood=row["start_mood"],
        end_mood=row["end_mood"],
        genres=json.loads(row["genres_json"] or "[]"),
        tracks=json.loads(row["tracks_json"] or "[]"),
        curve=json.loads(row["curve_json"] or "[]"),
    )


@router.delete("/{set_id}", status_code=204)
async def delete_dj_set(set_id: int) -> None:
    conn = get_db_connection()
    try:
        n = conn.execute("DELETE FROM dj_sets WHERE id=?", (set_id,)).rowcount
        conn.commit()
    finally:
        conn.close()
    if not n:
        raise HTTPException(status_code=404, detail="DJ set not found")
