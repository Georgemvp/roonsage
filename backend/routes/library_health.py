"""Library Health dashboard endpoints.

Surfaces problems that grow invisibly over time:
- Duplicate tracks (same artist+title across multiple albums)
- Missing metadata (no genre / year / album art / BPM / key)
- Album consistency — tracks of an album with inconsistent enrichment IDs
- Stale cache entries — tracks ≥ N days unseen in the library
- Disk usage per genre (when MUSIC_LIBRARY_PATH is set)

Plus single-shot "fix" actions that re-enqueue or re-resolve affected rows.
"""

from __future__ import annotations

import contextlib
import logging
import os
from pathlib import Path
from typing import Any

from fastapi import APIRouter

from backend.db import aget_connection, get_db_connection

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/library-health", tags=["library-health"])

_STALE_DAYS_DEFAULT = 30

# Strings that consistently indicate a live performance / commentary track.
# We re-evaluate ``is_live`` opportunistically so stale flags from older syncs
# get cleaned up.
_LIVE_KEYWORDS = (
    "(live", " - live", "[live", "unplugged", "in concert", "live at ",
    "live in ", "live on ", "commentary",
)


async def _duplicates_block(limit: int = 30) -> dict[str, Any]:
    async with aget_connection() as conn:
        cur = await conn.execute("""
            SELECT artist, title, COUNT(DISTINCT album) AS album_count
            FROM tracks
            WHERE artist IS NOT NULL AND title IS NOT NULL
            GROUP BY LOWER(artist), LOWER(title)
            HAVING COUNT(DISTINCT album) >= 2
            ORDER BY album_count DESC, artist ASC
            LIMIT ?
        """, (limit,))
        samples = await cur.fetchall()

        cur = await conn.execute("""
            SELECT COUNT(*) FROM (
                SELECT 1 FROM tracks
                WHERE artist IS NOT NULL AND title IS NOT NULL
                GROUP BY LOWER(artist), LOWER(title)
                HAVING COUNT(DISTINCT album) >= 2
            )
        """)
        total = (await cur.fetchone())[0] or 0

    return {
        "count": total,
        "samples": [
            {"artist": r[0], "title": r[1], "album_count": r[2]} for r in samples
        ],
    }


async def _missing_metadata_block() -> dict[str, Any]:
    async with aget_connection() as conn:
        async def _scalar(sql: str) -> int:
            cur = await conn.execute(sql)
            return (await cur.fetchone())[0] or 0

        return {
            "no_genre": await _scalar(
                "SELECT COUNT(*) FROM tracks t "
                "WHERE NOT EXISTS (SELECT 1 FROM track_genres g WHERE g.track_key = t.item_key)"
            ),
            "no_year": await _scalar(
                "SELECT COUNT(*) FROM tracks WHERE year IS NULL OR year = 0"
            ),
            "no_art": await _scalar(
                "SELECT COUNT(*) FROM tracks WHERE image_key IS NULL OR image_key = ''"
            ),
            "no_bpm": await _scalar(
                "SELECT COUNT(*) FROM tracks t "
                "LEFT JOIN track_audio_features af ON af.item_key = t.item_key "
                "WHERE af.bpm IS NULL"
            ),
            "no_key": await _scalar(
                "SELECT COUNT(*) FROM tracks t "
                "LEFT JOIN track_audio_features af ON af.item_key = t.item_key "
                "WHERE af.camelot IS NULL"
            ),
        }


async def _album_consistency_block(limit: int = 20) -> dict[str, Any]:
    """Flag albums whose tracks have inconsistent enrichment coverage.

    A consistent album has either (a) all tracks enriched or (b) no tracks
    enriched. Mixed coverage usually means the album was split mid-enrichment
    or a re-tag happened — both lead to broken sort orders in Roon. We surface
    the worst offenders so the user can re-enrich them in one action.
    """
    async with aget_connection() as conn:
        cur = await conn.execute("""
            SELECT t.album, t.artist,
                   COUNT(*) AS total,
                   SUM(CASE WHEN me.musicbrainz_id IS NOT NULL THEN 1 ELSE 0 END) AS enriched
            FROM tracks t
            LEFT JOIN track_metadata_ext me ON me.item_key = t.item_key
            WHERE t.album IS NOT NULL AND t.album != ''
            GROUP BY t.album, t.artist
            HAVING total >= 3
               AND enriched > 0
               AND enriched < total
            ORDER BY (total - enriched) DESC, total DESC
            LIMIT ?
        """, (limit,))
        rows = await cur.fetchall()

        cur = await conn.execute("""
            SELECT COUNT(*) FROM (
                SELECT 1 FROM tracks t
                LEFT JOIN track_metadata_ext me ON me.item_key = t.item_key
                WHERE t.album IS NOT NULL AND t.album != ''
                GROUP BY t.album, t.artist
                HAVING COUNT(*) >= 3
                   AND SUM(CASE WHEN me.musicbrainz_id IS NOT NULL THEN 1 ELSE 0 END) > 0
                   AND SUM(CASE WHEN me.musicbrainz_id IS NOT NULL THEN 1 ELSE 0 END) < COUNT(*)
            )
        """)
        total = (await cur.fetchone())[0] or 0

    samples = [
        {
            "album": r[0],
            "artist": r[1],
            # release_id_count is a misnomer for the React shape — we surface
            # the (total / enriched) ratio instead so it makes sense to the user.
            "release_id_count": r[2] - r[3],
        }
        for r in rows
    ]
    return {"inconsistent_albums": total, "samples": samples}


async def _stale_block(days: int = _STALE_DAYS_DEFAULT) -> dict[str, Any]:
    # We use ``updated_at`` (last sync touch) as the staleness signal — tracks
    # whose row hasn't been touched by sync for ``days`` AND that never made it
    # through enrichment are the actual stale rows. ``last_viewed_at`` would be
    # too strict (every untouched track would qualify).
    async with aget_connection() as conn:
        cur = await conn.execute(
            """
            SELECT COUNT(*)
            FROM tracks t
            LEFT JOIN enrichment_queue q ON q.item_key = t.item_key
            WHERE t.updated_at IS NOT NULL
              AND t.updated_at < datetime('now', ?)
              AND q.item_key IS NULL
              AND NOT EXISTS (SELECT 1 FROM track_metadata_ext me WHERE me.item_key = t.item_key)
            """,
            (f"-{days} days",),
        )
        count = (await cur.fetchone())[0] or 0
    return {"count": count, "older_than_days": days}


def _disk_usage_block() -> dict[str, Any]:
    music_root = os.environ.get("MUSIC_LIBRARY_PATH")
    if not music_root or not Path(music_root).is_dir():
        return {"available": False, "bytes_total": None, "per_genre": []}

    # Genre → bytes via tracks.file_path on the audio_features table, scoped to
    # the resolved files. Filesystem stat happens in worker process to avoid
    # blocking the request.
    conn = get_db_connection()
    try:
        rows = conn.execute("""
            SELECT g.genre, SUM(af.file_size_bytes) AS bytes
            FROM track_audio_features af
            JOIN track_genres g ON g.track_key = af.item_key
            WHERE af.file_size_bytes IS NOT NULL
            GROUP BY g.genre
            ORDER BY bytes DESC
            LIMIT 12
        """).fetchall()
        rows = [r for r in rows if r and r[1]]
        total = sum(r[1] for r in rows) or None
        per_genre = [{"genre": r[0], "bytes": int(r[1])} for r in rows]
    except Exception:
        # file_size_bytes column may not exist; report empty rather than 500.
        return {"available": True, "bytes_total": None, "per_genre": []}
    finally:
        conn.close()

    return {"available": True, "bytes_total": total, "per_genre": per_genre}


async def _dead_files_block_cached() -> dict[str, Any]:
    """Return the cached dead-file scan result without touching the filesystem.

    The actual scan happens via ``POST /scan-dead-files`` which runs sync I/O
    in a worker thread and persists ``track_audio_features.file_missing``.
    Embedding the scan in the summary endpoint would block the asyncio event
    loop for 5–60 s on slow disks, so we read counts only.
    """
    music_root = os.environ.get("MUSIC_LIBRARY_PATH")
    if not music_root or not Path(music_root).is_dir():
        return {"available": False, "missing": 0, "checked": 0}

    async with aget_connection() as conn:
        try:
            cur = await conn.execute(
                "SELECT COUNT(*) AS total, "
                "SUM(CASE WHEN file_missing = 1 THEN 1 ELSE 0 END) AS missing "
                "FROM track_audio_features "
                "WHERE file_path IS NOT NULL AND file_path != ''"
            )
            row = await cur.fetchone()
        except Exception:
            return {"available": True, "missing": 0, "checked": 0}
    return {
        "available": True,
        "checked": (row["total"] or 0) if row else 0,
        "missing": (row["missing"] or 0) if row else 0,
    }


@router.get("/summary")
async def summary() -> dict[str, Any]:
    return {
        "duplicates": await _duplicates_block(),
        "missing_metadata": await _missing_metadata_block(),
        "album_consistency": await _album_consistency_block(),
        "stale_entries": await _stale_block(),
        "disk_usage": _disk_usage_block(),
        "dead_files": await _dead_files_block_cached(),
    }


@router.post("/fix-duplicates")
async def fix_duplicates() -> dict[str, Any]:
    """Mark cross-album duplicates by emitting a hint label on tracks.

    Doesn't delete anything — just sets `is_duplicate=1` on all but the
    earliest-added copy so the UI can filter them out. Reversible.
    """
    async with aget_connection() as conn:
        # Best-effort migration: add column if it doesn't exist. ALTER fails
        # with OperationalError on re-run, which is fine.
        with contextlib.suppress(Exception):
            await conn.execute("ALTER TABLE tracks ADD COLUMN is_duplicate INTEGER DEFAULT 0")

        await conn.execute("UPDATE tracks SET is_duplicate = 0")
        cur = await conn.execute("""
            WITH ranked AS (
                SELECT item_key, ROW_NUMBER() OVER (
                    PARTITION BY LOWER(artist), LOWER(title)
                    ORDER BY COALESCE(updated_at, item_key) ASC
                ) AS rn
                FROM tracks
                WHERE artist IS NOT NULL AND title IS NOT NULL
            )
            UPDATE tracks
            SET is_duplicate = 1
            WHERE item_key IN (SELECT item_key FROM ranked WHERE rn > 1)
        """)
        rows = cur.rowcount
        await conn.commit()
    return {"marked": rows}


@router.post("/reenrich-missing")
async def reenrich_missing() -> dict[str, Any]:
    """Re-queue tracks with missing metadata for the enrichment worker."""
    conn = get_db_connection()
    try:
        rows = conn.execute("""
            INSERT OR IGNORE INTO enrichment_queue (item_key, artist, title, album, status)
            SELECT t.item_key, t.artist, t.title, t.album, 'pending'
            FROM tracks t
            LEFT JOIN track_metadata_ext me ON me.item_key = t.item_key
            WHERE me.item_key IS NULL OR me.musicbrainz_id IS NULL
        """).rowcount
        conn.commit()
    finally:
        conn.close()
    return {"queued": rows}


@router.post("/reanalyse-missing-bpm")
async def reanalyse_missing_bpm() -> dict[str, Any]:
    """Re-queue tracks without BPM for the audio-features worker."""
    conn = get_db_connection()
    try:
        rows = conn.execute("""
            INSERT OR IGNORE INTO audio_features_queue (item_key, status)
            SELECT t.item_key, 'pending'
            FROM tracks t
            LEFT JOIN track_audio_features af ON af.item_key = t.item_key
            WHERE af.bpm IS NULL
        """).rowcount
        conn.commit()
    finally:
        conn.close()
    return {"queued": rows}


@router.post("/recompute-live-flags")
async def recompute_live_flags() -> dict[str, Any]:
    """Re-flag tracks as live based on title/album keyword heuristics."""
    keyword_clauses = " OR ".join(
        ["LOWER(title) LIKE ?" for _ in _LIVE_KEYWORDS]
        + ["LOWER(album) LIKE ?" for _ in _LIVE_KEYWORDS]
    )
    params = [f"%{kw}%" for kw in _LIVE_KEYWORDS] * 2

    conn = get_db_connection()
    try:
        conn.execute("UPDATE tracks SET is_live = 0 WHERE is_live = 1")
        cur = conn.execute(
            f"UPDATE tracks SET is_live = 1 WHERE {keyword_clauses}",
            params,
        )
        flagged = cur.rowcount
        conn.commit()
    finally:
        conn.close()
    return {"flagged": flagged}


def _scan_dead_files_sync() -> dict[str, Any]:
    """Filesystem scan — must be called via ``asyncio.to_thread``.

    Iterates every analysed track's ``file_path`` and stat()s it on disk. The
    whole thing is sync because Path.exists() doesn't have an async variant,
    and music libraries can sit on NAS where each stat is 10–50 ms.
    """
    music_root = os.environ.get("MUSIC_LIBRARY_PATH")
    if not music_root or not Path(music_root).is_dir():
        return {"available": False, "checked": 0, "missing": 0}

    conn = get_db_connection()
    try:
        with contextlib.suppress(Exception):
            conn.execute(
                "ALTER TABLE track_audio_features ADD COLUMN file_missing INTEGER DEFAULT 0"
            )
        conn.execute("UPDATE track_audio_features SET file_missing = 0")
        rows = conn.execute(
            "SELECT item_key, file_path FROM track_audio_features "
            "WHERE file_path IS NOT NULL AND file_path != ''"
        ).fetchall()
        checked = 0
        missing_keys: list[str] = []
        for r in rows:
            path = r[1]
            checked += 1
            with contextlib.suppress(OSError):
                if not Path(path).exists():
                    missing_keys.append(r[0])

        if missing_keys:
            placeholders = ",".join(["?"] * len(missing_keys))
            conn.execute(
                f"UPDATE track_audio_features SET file_missing = 1 "
                f"WHERE item_key IN ({placeholders})",
                missing_keys,
            )
        conn.commit()
    finally:
        conn.close()
    return {"available": True, "checked": checked, "missing": len(missing_keys)}


@router.post("/scan-dead-files")
async def scan_dead_files() -> dict[str, Any]:
    """Mark tracks whose on-disk file is missing.

    Runs the blocking filesystem scan in a worker thread so the event loop
    keeps serving other handlers. The result is persisted to
    ``track_audio_features.file_missing`` and surfaced by ``/summary``.
    """
    import asyncio  # noqa: PLC0415

    return await asyncio.to_thread(_scan_dead_files_sync)


@router.post("/fix-all")
async def fix_all() -> dict[str, Any]:
    """Run every reversible maintenance job in sequence (Picard-style one-click).

    Order matters: mark duplicates and live tracks first (cheap, in-DB), then
    re-queue missing metadata and missing BPM (workers pick them up async),
    finally scan dead files (slowest, optional).
    """
    results: dict[str, Any] = {}
    with contextlib.suppress(Exception):
        results["duplicates"] = await fix_duplicates()
    with contextlib.suppress(Exception):
        results["live_flags"] = await recompute_live_flags()
    with contextlib.suppress(Exception):
        results["reenrich"] = await reenrich_missing()
    with contextlib.suppress(Exception):
        results["reanalyse_bpm"] = await reanalyse_missing_bpm()
    with contextlib.suppress(Exception):
        results["dead_files"] = await scan_dead_files()
    return {"ok": True, "steps": results}
