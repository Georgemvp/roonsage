"""Bento-grid dashboard aggregator.

Single endpoint that fans out to the underlying stats / intelligence / circadian /
worker / sonic-fingerprint / watchlist endpoints and returns ONE consolidated
JSON payload so the React Dashboard view can render in a single round trip.

Each block is wrapped so any one upstream failure (worker not initialised,
fingerprint cache missing, no Roon zones) degrades to a null/empty shape instead
of taking the whole dashboard down.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import APIRouter

from backend.db import aget_connection, get_db_connection

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/dashboard", tags=["dashboard"])


# ---------------------------------------------------------------------------
# Per-block probes — each returns either a populated dict or a stable null shape
# ---------------------------------------------------------------------------


async def _now_playing() -> dict[str, Any] | None:
    """Return the currently-playing zone or None when nothing is active."""
    try:
        from backend.roon_client import get_roon_client  # noqa: PLC0415

        client = get_roon_client()
        if client is None or not client.is_connected():
            return None
        zones = await asyncio.to_thread(client.get_zones)
        for zone in zones or []:
            # zones are RoonZoneInfo Pydantic objects — use attribute access.
            if zone.state == "playing" and zone.now_playing:
                np = zone.now_playing  # dict from the Roon API
                two = np.get("two_line") or {}
                one = np.get("one_line") or {}
                return {
                    "title": two.get("line1") or one.get("line1") or "",
                    "artist": two.get("line2") or one.get("line2") or "",
                    "album": np.get("three_line", {}).get("line3"),
                    "art_key": np.get("image_key"),
                    "zone_id": zone.zone_id,
                    "zone_name": zone.display_name or zone.zone_id,
                    "state": zone.state,
                }
    except Exception as exc:
        logger.debug("Dashboard now_playing block failed: %s", exc)
    return None


async def _library_block() -> dict[str, Any]:
    try:
        async with aget_connection() as conn:
            cur = await conn.execute("SELECT COUNT(*) FROM tracks")
            tracks = (await cur.fetchone())[0] or 0
            cur = await conn.execute("SELECT COUNT(DISTINCT album) FROM tracks WHERE album IS NOT NULL")
            albums = (await cur.fetchone())[0] or 0
            cur = await conn.execute("SELECT COUNT(DISTINCT artist) FROM tracks WHERE artist IS NOT NULL")
            artists = (await cur.fetchone())[0] or 0
        return {
            "total_tracks": tracks,
            "total_albums": albums,
            "total_artists": artists,
            "sync_state": "idle",
            "sync_progress": None,
        }
    except Exception as exc:
        logger.debug("Dashboard library block failed: %s", exc)
        return {"total_tracks": 0, "total_albums": 0, "total_artists": 0, "sync_state": "error", "sync_progress": None}


def _workers_block() -> dict[str, Any]:
    def _zeros() -> dict[str, Any]:
        return {"pending": 0, "processing": 0, "processed_24h": 0, "paused": True}

    out = {
        "enrichment": _zeros(),
        "audio_features": _zeros(),
        "clustering": {"last_run_at": None, "n_clusters": None},
    }
    try:
        from backend.enrichment_worker import get_queue_stats, get_worker  # noqa: PLC0415

        conn = get_db_connection()
        try:
            stats = get_queue_stats(conn)
        finally:
            conn.close()
        worker = get_worker()
        out["enrichment"] = {
            "pending": stats.get("pending", 0),
            "processing": stats.get("processing", 0),
            "processed_24h": stats.get("complete", 0),
            "paused": worker.is_paused(),
        }
    except Exception as exc:
        logger.debug("Dashboard enrichment block failed: %s", exc)

    try:
        from backend.audio_features.worker import get_features_worker  # noqa: PLC0415
        from backend.audio_features.worker import get_queue_stats as get_af_stats
        from backend.config import get_audio_features_enabled  # noqa: PLC0415

        if get_audio_features_enabled():
            conn = get_db_connection()
            try:
                stats = get_af_stats(conn)
            finally:
                conn.close()
            af_worker = get_features_worker()
            out["audio_features"] = {
                "pending": stats.get("pending", 0),
                "processing": stats.get("analyzing", 0),
                "processed_24h": stats.get("complete", 0),
                "paused": af_worker.is_paused(),
            }
    except Exception as exc:
        logger.debug("Dashboard audio_features block failed: %s", exc)

    try:
        conn = get_db_connection()
        try:
            row = conn.execute(
                "SELECT COUNT(*) FROM cluster_runs WHERE rowid = 1"
            ).fetchone()
            if row and row[0]:
                meta = conn.execute(
                    "SELECT created_at, n_clusters FROM cluster_runs WHERE rowid = 1"
                ).fetchone()
                if meta:
                    out["clustering"] = {"last_run_at": meta[0], "n_clusters": meta[1]}
        finally:
            conn.close()
    except Exception:
        # cluster_runs table may not exist on fresh installs
        pass

    return out


async def _fingerprint_block() -> dict[str, Any] | None:
    try:
        def _run() -> dict[str, Any] | None:
            from backend.audio_features.sonic_fingerprint import (
                get_sonic_fingerprint,  # noqa: PLC0415
            )

            conn = get_db_connection()
            try:
                fp = get_sonic_fingerprint(conn, top_n=50)
            finally:
                conn.close()
            if not fp or not fp.get("fingerprint"):
                return None
            cols = fp.get("feature_columns") or []
            vec = fp.get("fingerprint") or []
            pairs = list(zip(cols, vec, strict=False))
            pairs.sort(key=lambda kv: abs(kv[1]), reverse=True)
            top = [{"name": k, "value": float(v)} for k, v in pairs[:6]]
            return {"top_dimensions": top, "sample_recommendations": []}

        return await asyncio.to_thread(_run)
    except Exception as exc:
        logger.debug("Dashboard fingerprint block failed: %s", exc)
        return None


def _today_mix_block() -> dict[str, Any]:
    """Mood + energy for now based on the time-of-day centroid."""
    hour = datetime.now().hour
    if 5 <= hour < 9:
        mood, energy = "Ochtend — kalm", 0.35
    elif 9 <= hour < 12:
        mood, energy = "Ochtend — focus", 0.55
    elif 12 <= hour < 17:
        mood, energy = "Middag — vitaal", 0.7
    elif 17 <= hour < 21:
        mood, energy = "Avond — warm", 0.6
    elif 21 <= hour < 24:
        mood, energy = "Avond — wind-down", 0.35
    else:
        mood, energy = "Nacht — dromerig", 0.2

    cached = False
    try:
        conn = get_db_connection()
        try:
            row = conn.execute(
                "SELECT id FROM results WHERE type='circadian_auto' "
                "AND date(created_at) = date('now', 'localtime') LIMIT 1"
            ).fetchone()
            cached = bool(row)
        finally:
            conn.close()
    except Exception:
        pass

    return {"mood": mood, "energy": energy, "track_count": 35, "cached": cached}


async def _recent_history_block() -> list[dict[str, Any]]:
    try:
        async with aget_connection() as conn:
            cur = await conn.execute(
                """
                SELECT lh.track_title, lh.artist, t.image_key, lh.timestamp
                FROM listening_history lh
                LEFT JOIN tracks t
                    ON LOWER(t.title) = LOWER(lh.track_title)
                    AND LOWER(t.artist) = LOWER(lh.artist)
                WHERE lh.timestamp >= ?
                  AND typeof(lh.timestamp) = 'text'
                ORDER BY lh.timestamp DESC
                LIMIT 10
                """,
                ((datetime.now(UTC) - timedelta(hours=24)).isoformat(),),
            )
            rows = await cur.fetchall()
        return [
            {
                "title": r[0] or "—",
                "artist": r[1] or "",
                "art_key": r[2],
                "played_at": r[3],
            }
            for r in rows
        ]
    except Exception as exc:
        logger.debug("Dashboard recent_history block failed: %s", exc)
        return []


async def _watchlist_block() -> list[dict[str, Any]]:
    try:
        async with aget_connection() as conn:
            cur = await conn.execute(
                """
                SELECT a.name, r.release_title, r.release_date
                FROM artist_releases_cache r
                JOIN artist_watchlist a ON a.mbid = r.mbid
                WHERE r.release_date >= date('now', '-30 day')
                ORDER BY r.release_date DESC
                LIMIT 8
                """
            )
            rows = await cur.fetchall()
        return [
            {"artist": r[0] or "", "release_title": r[1] or "", "release_date": r[2] or ""}
            for r in rows
        ]
    except Exception as exc:
        logger.debug("Dashboard watchlist block failed: %s", exc)
        return []


# ---------------------------------------------------------------------------
# Public endpoint
# ---------------------------------------------------------------------------


@router.get("/summary")
async def dashboard_summary() -> dict[str, Any]:
    """One round trip → everything the React Dashboard needs.

    Fans out blocks in parallel; ~250 ms typical on a warm 46k-track library.
    """
    now_playing, library, fingerprint, recent_history, watchlist = await asyncio.gather(
        _now_playing(),
        _library_block(),
        _fingerprint_block(),
        _recent_history_block(),
        _watchlist_block(),
    )
    workers = await asyncio.to_thread(_workers_block)
    today_mix = await asyncio.to_thread(_today_mix_block)

    return {
        "now_playing": now_playing,
        "library": library,
        "workers": workers,
        "fingerprint": fingerprint,
        "today_mix": today_mix,
        "recent_history": recent_history,
        "watchlist_updates": watchlist,
    }
