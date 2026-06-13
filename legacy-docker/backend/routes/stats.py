"""Listening stats overview.

Single-call aggregator for the Stats dashboard: KPI cards, a daily timeline,
genre breakdown, top artists/albums, and library-health coverage. Built on the
async connection layer so it never blocks the event loop.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import APIRouter, Query

from backend.db import aget_connection

router = APIRouter(prefix="/api/stats", tags=["stats"])

_RANGE_DAYS = {"7d": 7, "30d": 30, "12m": 365, "all": 36500}


def _cutoff_iso(days: int) -> str:
    return (datetime.now(UTC) - timedelta(days=days)).isoformat()


@router.get("/overview")
async def stats_overview(
    window: str = Query("30d", alias="range"),
) -> dict[str, Any]:
    """Everything the Stats dashboard needs, in one round trip.

    `range`: 7d | 30d | 12m | all
    """
    days = _RANGE_DAYS.get(window, 30)
    cutoff = _cutoff_iso(days)
    now = datetime.now(UTC)
    cutoff_today = (now - timedelta(days=1)).isoformat()
    cutoff_week = (now - timedelta(days=7)).isoformat()
    cutoff_month = (now - timedelta(days=30)).isoformat()

    async with aget_connection() as conn:
        # --- KPI cards: plays in rolling windows + all-time ---
        async def _count(since: str | None) -> int:
            if since is None:
                cur = await conn.execute("SELECT COUNT(*) FROM listening_history")
            else:
                cur = await conn.execute(
                    "SELECT COUNT(*) FROM listening_history WHERE timestamp >= ?", (since,)
                )
            row = await cur.fetchone()
            return row[0] or 0

        plays_today = await _count(cutoff_today)
        plays_week = await _count(cutoff_week)
        plays_month = await _count(cutoff_month)
        plays_all = await _count(None)

        # --- Totals for the selected window ---
        cur = await conn.execute(
            """SELECT COUNT(*) AS total,
                      SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) AS skipped,
                      SUM(COALESCE(played_seconds, 0)) AS secs,
                      COUNT(DISTINCT artist) AS artists,
                      COUNT(DISTINCT album)  AS albums
               FROM listening_history WHERE timestamp >= ?""",
            (cutoff,),
        )
        t = await cur.fetchone()
        total = t["total"] or 0
        skipped = t["skipped"] or 0

        # --- Daily timeline ---
        cur = await conn.execute(
            """SELECT date(timestamp) AS day, COUNT(*) AS plays
               FROM listening_history WHERE timestamp >= ?
               GROUP BY day ORDER BY day""",
            (cutoff,),
        )
        timeline = [{"day": r["day"], "plays": r["plays"]} for r in await cur.fetchall()]

        # --- Genre breakdown ---
        cur = await conn.execute(
            """SELECT genre, COUNT(*) AS plays
               FROM listening_history
               WHERE timestamp >= ? AND genre IS NOT NULL AND genre != ''
               GROUP BY genre ORDER BY plays DESC LIMIT 10""",
            (cutoff,),
        )
        genres = [{"genre": r["genre"], "plays": r["plays"]} for r in await cur.fetchall()]

        # --- Top artists ---
        cur = await conn.execute(
            """SELECT artist, COUNT(*) AS plays
               FROM listening_history
               WHERE timestamp >= ? AND artist IS NOT NULL AND artist != ''
               GROUP BY artist ORDER BY plays DESC LIMIT 12""",
            (cutoff,),
        )
        top_artists = [{"artist": r["artist"], "plays": r["plays"]} for r in await cur.fetchall()]

        # --- Top albums (with art key + artist for play buttons) ---
        cur = await conn.execute(
            """SELECT album, artist, COUNT(*) AS plays
               FROM listening_history
               WHERE timestamp >= ? AND album IS NOT NULL AND album != ''
               GROUP BY album, artist ORDER BY plays DESC LIMIT 12""",
            (cutoff,),
        )
        top_albums = [
            {"album": r["album"], "artist": r["artist"], "plays": r["plays"]}
            for r in await cur.fetchall()
        ]

        # --- Listening hour-of-day heatmap (0-23) ---
        cur = await conn.execute(
            """SELECT CAST(strftime('%H', timestamp) AS INTEGER) AS hour,
                      COUNT(*) AS plays
               FROM listening_history WHERE timestamp >= ?
               GROUP BY hour ORDER BY hour""",
            (cutoff,),
        )
        hour_rows = {r["hour"]: r["plays"] for r in await cur.fetchall()}
        listening_by_hour = [
            {"hour": h, "plays": hour_rows.get(h, 0)} for h in range(24)
        ]

        # --- Day-of-week heatmap (0 = Sunday … 6 = Saturday per SQLite) ---
        cur = await conn.execute(
            """SELECT CAST(strftime('%w', timestamp) AS INTEGER) AS dow,
                      COUNT(*) AS plays
               FROM listening_history WHERE timestamp >= ?
               GROUP BY dow ORDER BY dow""",
            (cutoff,),
        )
        dow_rows = {r["dow"]: r["plays"] for r in await cur.fetchall()}
        listening_by_dow = [
            {"dow": d, "plays": dow_rows.get(d, 0)} for d in range(7)
        ]

        # --- Decade breakdown (over plays in window) ---
        cur = await conn.execute(
            """SELECT decade, COUNT(*) AS plays
               FROM listening_history
               WHERE timestamp >= ? AND decade IS NOT NULL AND decade != ''
               GROUP BY decade ORDER BY decade""",
            (cutoff,),
        )
        decades = [
            {"decade": r["decade"], "plays": r["plays"]} for r in await cur.fetchall()
        ]

        # --- BPM histogram (library-wide, not window-scoped — it's structural) ---
        bpm_buckets: list[dict[str, int]] = []
        try:
            cur = await conn.execute(
                """SELECT bpm FROM track_audio_features
                   WHERE bpm IS NOT NULL AND bpm BETWEEN 40 AND 220"""
            )
            rows = await cur.fetchall()
            counts: dict[int, int] = {}
            for row in rows:
                bucket = (int(row["bpm"]) // 10) * 10
                counts[bucket] = counts.get(bucket, 0) + 1
            for low in range(40, 221, 10):
                bpm_buckets.append({"bpm": low, "count": counts.get(low, 0)})
        except Exception:
            bpm_buckets = []

        # --- Library health (cheap aggregate counts) ---
        async def _scalar(sql: str) -> int:
            try:
                cur2 = await conn.execute(sql)
                row = await cur2.fetchone()
                return row[0] or 0
            except Exception:
                return 0

        total_tracks = await _scalar("SELECT COUNT(*) FROM tracks")
        enriched = await _scalar("SELECT COUNT(*) FROM track_metadata_ext")
        analysed = await _scalar(
            "SELECT COUNT(*) FROM track_audio_features WHERE bpm IS NOT NULL"
        )
        lyrics = await _scalar(
            "SELECT COUNT(DISTINCT stable_id) FROM lyrics_data"
        )

    return {
        "range": window,
        "kpi": {
            "today": plays_today,
            "week": plays_week,
            "month": plays_month,
            "all_time": plays_all,
        },
        "window": {
            "plays": total,
            "skipped": skipped,
            "skip_rate": round(skipped / total * 100, 1) if total else 0.0,
            "minutes": round((t["secs"] or 0) / 60),
            "unique_artists": t["artists"] or 0,
            "unique_albums": t["albums"] or 0,
        },
        "timeline": timeline,
        "genres": genres,
        "top_artists": top_artists,
        "top_albums": top_albums,
        "listening_by_hour": listening_by_hour,
        "listening_by_dow": listening_by_dow,
        "decades": decades,
        "bpm_histogram": bpm_buckets,
        "library_health": {
            "total_tracks": total_tracks,
            "enriched": enriched,
            "enriched_pct": round(enriched / total_tracks * 100) if total_tracks else 0,
            "analysed": analysed,
            "analysed_pct": round(analysed / total_tracks * 100) if total_tracks else 0,
            "lyrics": lyrics,
            "lyrics_pct": round(lyrics / total_tracks * 100) if total_tracks else 0,
        },
    }
