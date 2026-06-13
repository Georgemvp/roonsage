"""Playlist personas — opinionated, cache-only playlist generators.

Inspired by SoulSync's named playlist library (Time Machine, Hidden Gems,
Discovery Weekly, Daily Mix, etc). Each persona is a pure SQL/Python query over
data already in the local cache — no LLM calls, no external APIs, instant.

The MCP server (mcp_server.py) wraps each into a tool so Claude Desktop can
invoke them by name.
"""

from __future__ import annotations

import asyncio
import logging
import random
from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.db import aget_connection, get_db_connection

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/personas", tags=["personas"])


# ---------------------------------------------------------------------------
# Registry — one entry per persona slug
# ---------------------------------------------------------------------------


PERSONAS: list[dict[str, Any]] = [
    {
        "slug": "time-machine",
        "name": "Time Machine",
        "emoji": "🕰️",
        "description": "Wat luisterde je precies 1, 5 of 10 jaar geleden in deze week?",
        "source": "Listening history",
        "track_count": 30,
    },
    {
        "slug": "hidden-gems",
        "name": "Hidden Gems",
        "emoji": "💎",
        "description": "Tracks van favoriete artiesten die je nooit (of bijna nooit) hebt gespeeld.",
        "source": "Bibliotheek + history",
        "track_count": 30,
    },
    {
        "slug": "seasonal-mix",
        "name": "Seasonal Mix",
        "emoji": "🌿",
        "description": "Energie en sfeer afgestemd op het seizoen — zomerse vibe of winterse kalmte.",
        "source": "Audio features",
        "track_count": 35,
    },
    {
        "slug": "daily-mix",
        "name": "Daily Mix",
        "emoji": "🎯",
        "description": "Dagelijks vernieuwde mix rond je top-genres met een vleugje verrassing.",
        "source": "Taste profile",
        "track_count": 30,
    },
    {
        "slug": "discovery-shuffle",
        "name": "Discovery Shuffle",
        "emoji": "🎲",
        "description": "Random wandeling door je fingerprint-buurt, alleen tracks die je nog niet kent.",
        "source": "Sonic fingerprint",
        "track_count": 30,
    },
    {
        "slug": "rainy-day",
        "name": "Tijdmachine NL",
        "emoji": "🌧️",
        "description": "Wat luisterde je toen het regende vorige maandag? Tijdmachine met weer als bonus.",
        "source": "Listening history",
        "track_count": 25,
    },
]


class PersonaPlayRequest(BaseModel):
    zone_id: str
    limit: int | None = None
    mode: str = "replace_queue"


# ---------------------------------------------------------------------------
# Persona implementations — each returns a list of (item_key, title, artist, album, art_key)
# ---------------------------------------------------------------------------


async def _time_machine_tracks(limit: int) -> list[tuple]:
    async with aget_connection() as conn:
        cuts = []
        now = datetime.now(UTC)
        for years_ago in (1, 5, 10):
            start = (now - timedelta(days=years_ago * 365 + 4)).isoformat()
            end = (now - timedelta(days=years_ago * 365 - 4)).isoformat()
            cuts.append((start, end))

        rows: list[tuple] = []
        for start, end in cuts:
            cur = await conn.execute(
                """
                SELECT DISTINCT t.item_key, t.title, t.artist, t.album, t.image_key
                FROM listening_history lh
                JOIN tracks t ON LOWER(t.title) = LOWER(lh.track_title)
                              AND LOWER(t.artist) = LOWER(lh.artist)
                WHERE lh.timestamp BETWEEN ? AND ?
                ORDER BY lh.timestamp DESC
                LIMIT ?
                """,
                (start, end, max(limit // 3, 4)),
            )
            rows.extend(await cur.fetchall())
        # Dedup by item_key while preserving order
        seen: set[str] = set()
        out: list[tuple] = []
        for r in rows:
            if r[0] in seen:
                continue
            seen.add(r[0])
            out.append(tuple(r))
        return out[:limit]


async def _hidden_gems_tracks(limit: int) -> list[tuple]:
    async with aget_connection() as conn:
        cur = await conn.execute(
            """
            WITH top_artists AS (
                SELECT artist, COUNT(*) AS plays
                FROM listening_history
                WHERE artist IS NOT NULL AND artist != ''
                GROUP BY artist
                ORDER BY plays DESC
                LIMIT 25
            ),
            played_keys AS (
                SELECT DISTINCT LOWER(track_title) AS title, LOWER(artist) AS artist
                FROM listening_history
                WHERE track_title IS NOT NULL
            )
            SELECT t.item_key, t.title, t.artist, t.album, t.image_key
            FROM tracks t
            JOIN top_artists ta ON ta.artist = t.artist
            LEFT JOIN played_keys p ON p.title = LOWER(t.title) AND p.artist = LOWER(t.artist)
            WHERE p.title IS NULL
              AND (t.is_live IS NULL OR t.is_live = 0)
            ORDER BY RANDOM()
            LIMIT ?
            """,
            (limit,),
        )
        return [tuple(r) for r in await cur.fetchall()]


def _seasonal_targets() -> dict[str, float]:
    """Return mood centroid weights for the current calendar season."""
    month = datetime.now().month
    if 3 <= month <= 5:  # Spring
        return {"valence": 0.7, "energy": 0.6, "acousticness": 0.4}
    if 6 <= month <= 8:  # Summer
        return {"valence": 0.8, "energy": 0.75, "danceability": 0.7}
    if 9 <= month <= 11:  # Autumn
        return {"valence": 0.45, "energy": 0.5, "acousticness": 0.55}
    return {"valence": 0.35, "energy": 0.4, "acousticness": 0.6}  # Winter


async def _seasonal_tracks(limit: int) -> list[tuple]:
    targets = _seasonal_targets()
    async with aget_connection() as conn:
        # Cosine-rank against the seasonal centroid using the cached audio features.
        cur = await conn.execute(
            """
            SELECT t.item_key, t.title, t.artist, t.album, t.image_key,
                   af.valence, af.energy, af.acousticness, af.danceability
            FROM tracks t
            JOIN track_audio_features af ON af.item_key = t.item_key
            WHERE af.valence IS NOT NULL AND af.energy IS NOT NULL
              AND (t.is_live IS NULL OR t.is_live = 0)
            """
        )
        rows = await cur.fetchall()

    def _score(r: tuple) -> float:
        s = 0.0
        feats = {
            "valence": r[5],
            "energy": r[6],
            "acousticness": r[7] or 0,
            "danceability": r[8] or 0,
        }
        for k, tgt in targets.items():
            v = feats.get(k)
            if v is None:
                continue
            s -= abs(v - tgt)  # higher = closer to target
        return s

    ranked = sorted((tuple(r) for r in rows), key=_score, reverse=True)
    return [r[:5] for r in ranked[: limit * 3]][:limit]


async def _daily_mix_tracks(limit: int) -> list[tuple]:
    # Top 5 genres → 6 tracks from each, ordered by year DESC to feel current.
    async with aget_connection() as conn:
        cur = await conn.execute(
            """
            SELECT genre, COUNT(*) AS plays
            FROM listening_history
            WHERE genre IS NOT NULL AND genre != ''
            GROUP BY genre
            ORDER BY plays DESC
            LIMIT 5
            """
        )
        genres = [r[0] for r in await cur.fetchall()]
        if not genres:
            return []

        per_genre = max(limit // max(len(genres), 1), 4)
        out: list[tuple] = []
        for genre in genres:
            cur = await conn.execute(
                """
                SELECT DISTINCT t.item_key, t.title, t.artist, t.album, t.image_key
                FROM tracks t
                JOIN track_genres g ON g.track_key = t.item_key
                WHERE LOWER(g.genre) = LOWER(?)
                  AND (t.is_live IS NULL OR t.is_live = 0)
                ORDER BY t.year DESC NULLS LAST, RANDOM()
                LIMIT ?
                """,
                (genre, per_genre),
            )
            out.extend(tuple(r) for r in await cur.fetchall())
        random.shuffle(out)
        return out[:limit]


async def _discovery_shuffle_tracks(limit: int) -> list[tuple]:
    """Random unplayed tracks ranked by similarity to the user's fingerprint."""

    def _run() -> list[tuple]:
        from backend.audio_features.sonic_fingerprint import (  # noqa: PLC0415
            get_fingerprint_recommendations,
        )

        conn = get_db_connection()
        try:
            recs = get_fingerprint_recommendations(conn, limit=limit * 3, unplayed_only=True)
            return [
                (r["item_key"], r["title"], r["artist"], r["album"], None)
                for r in recs.get("results", [])
            ]
        finally:
            conn.close()

    try:
        rows = await asyncio.to_thread(_run)
    except Exception as exc:
        logger.warning("discovery-shuffle failed: %s", exc)
        return []
    random.shuffle(rows)
    return rows[:limit]


async def _rainy_day_tracks(limit: int) -> list[tuple]:
    """History snapshot keyed to the same weekday over the past year."""
    async with aget_connection() as conn:
        cur = await conn.execute(
            """
            SELECT DISTINCT t.item_key, t.title, t.artist, t.album, t.image_key
            FROM listening_history lh
            JOIN tracks t ON LOWER(t.title) = LOWER(lh.track_title)
                          AND LOWER(t.artist) = LOWER(lh.artist)
            WHERE lh.day_of_week = strftime('%w', 'now')
              AND lh.timestamp >= datetime('now', '-365 days')
            ORDER BY lh.timestamp DESC
            LIMIT ?
            """,
            (limit,),
        )
        return [tuple(r) for r in await cur.fetchall()]


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------


_DISPATCH = {
    "time-machine": _time_machine_tracks,
    "hidden-gems": _hidden_gems_tracks,
    "seasonal-mix": _seasonal_tracks,
    "daily-mix": _daily_mix_tracks,
    "discovery-shuffle": _discovery_shuffle_tracks,
    "rainy-day": _rainy_day_tracks,
}


async def _resolve(slug: str, limit: int) -> list[tuple]:
    fn = _DISPATCH.get(slug)
    if fn is None:
        raise HTTPException(status_code=404, detail=f"Unknown persona: {slug}")
    return await fn(limit)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("/list")
async def list_personas() -> list[dict[str, Any]]:
    return [{**p, "generated_at": None} for p in PERSONAS]


@router.get("/{slug}/preview")
async def preview_persona(slug: str) -> dict[str, Any]:
    meta = next((p for p in PERSONAS if p["slug"] == slug), None)
    if meta is None:
        raise HTTPException(status_code=404, detail=f"Unknown persona: {slug}")
    rows = await _resolve(slug, meta["track_count"])
    return {
        "slug": slug,
        "tracks": [
            {
                "number": i + 1,
                "title": r[1] or "—",
                "artist": r[2] or "",
                "album": r[3] or "",
                "art_key": r[4],
            }
            for i, r in enumerate(rows)
        ],
    }


@router.post("/{slug}/play")
async def play_persona(slug: str, request: PersonaPlayRequest) -> dict[str, Any]:
    from backend.roon_client import get_roon_client  # noqa: PLC0415

    meta = next((p for p in PERSONAS if p["slug"] == slug), None)
    if meta is None:
        raise HTTPException(status_code=404, detail=f"Unknown persona: {slug}")

    limit = request.limit or meta["track_count"]
    rows = await _resolve(slug, limit)
    if not rows:
        raise HTTPException(status_code=404, detail="Persona returned no tracks")

    client = get_roon_client()
    if not client or not client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    item_keys = [r[0] for r in rows if r[0]]
    result = await asyncio.to_thread(
        client.play_tracks,
        request.zone_id,
        item_keys,
        request.mode,
        False,
    )
    if not result.success:
        raise HTTPException(status_code=500, detail=result.error or "Queue failed")
    return {
        "success": True,
        "persona": slug,
        "queued": len(item_keys),
        "name": meta["name"],
    }
