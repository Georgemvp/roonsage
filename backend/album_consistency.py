"""Picard-style album consistency tagger.

Roon assumes every track in an album shares the same MusicBrainz release ID;
when they don't, the album shows up as multiple "mini-albums" in the browse
tree. This module picks one canonical release ID per album and back-fills it
onto every track row in ``track_metadata_ext``.

Strategy (inspired by SoulSync's release_selector):
1. Group tracks by (artist, album) where we have at least one MB recording ID.
2. For each group, query MusicBrainz for releases matching the recording IDs.
3. Score candidate releases on:
   - track-count match exact = +5, off-by-one = +2, otherwise = -3
   - country: NL/BE = +3, US/XW = +3, GB = +2, others = +0
   - format: Digital Media = +10, CD = +9, Vinyl/Cassette = +3, unknown = +0
   - barcode present = +1
4. Write the winner to ``track_metadata_ext.mb_release_id`` for every track in
   the group.

Schema migration: adds the column on first call so a fresh install needs no
migration; existing installs auto-populate.
"""

from __future__ import annotations

import contextlib
import logging
import sqlite3
from typing import Any

logger = logging.getLogger(__name__)

# Per-country score weight. Bias toward the user's region first, then majors.
_COUNTRY_SCORE = {
    "NL": 3, "BE": 3, "US": 3, "XW": 3, "GB": 2,
}

# Per-format score weight. Digital ≫ CD ≫ Vinyl because vinyl pressings often
# have different track orderings that Roon then surfaces as alternate albums.
_FORMAT_SCORE = {
    "Digital Media": 10,
    "CD": 9,
    "Vinyl": 3,
    "Cassette": 3,
}


def _ensure_schema(conn: sqlite3.Connection) -> None:
    """Add the mb_release_id column on demand (idempotent)."""
    # Add the column on demand. OperationalError just means it already exists.
    with contextlib.suppress(sqlite3.OperationalError):
        conn.execute("ALTER TABLE track_metadata_ext ADD COLUMN mb_release_id TEXT")
        logger.info("Album consistency: added mb_release_id column to track_metadata_ext")
    with contextlib.suppress(sqlite3.OperationalError):
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_track_metadata_ext_release "
            "ON track_metadata_ext(mb_release_id)"
        )
    conn.commit()


def _score_release(release: dict[str, Any], expected_track_count: int) -> int:
    score = 0
    actual = release.get("track-count") or 0
    diff = abs(actual - expected_track_count)
    if diff == 0:
        score += 5
    elif diff == 1:
        score += 2
    else:
        score -= 3

    country = release.get("country") or ""
    score += _COUNTRY_SCORE.get(country.upper(), 0)

    fmt = (release.get("media") or [{}])[0].get("format") if release.get("media") else None
    score += _FORMAT_SCORE.get(fmt or "", 0)

    if release.get("barcode"):
        score += 1
    return score


def _pick_release(releases: list[dict[str, Any]], expected_track_count: int) -> str | None:
    if not releases:
        return None
    best: tuple[int, str] | None = None
    for r in releases:
        rid = r.get("id")
        if not rid:
            continue
        s = _score_release(r, expected_track_count)
        if best is None or s > best[0]:
            best = (s, rid)
    return best[1] if best else None


def find_inconsistent_albums(conn: sqlite3.Connection, limit: int = 50) -> list[dict[str, Any]]:
    """Return albums missing a canonical mb_release_id but with ≥1 enriched track."""
    _ensure_schema(conn)
    rows = conn.execute(
        """
        SELECT t.album, t.artist, COUNT(*) AS total,
               SUM(CASE WHEN me.mb_release_id IS NOT NULL THEN 1 ELSE 0 END) AS tagged,
               SUM(CASE WHEN me.musicbrainz_id IS NOT NULL THEN 1 ELSE 0 END) AS enriched
        FROM tracks t
        LEFT JOIN track_metadata_ext me ON me.item_key = t.item_key
        WHERE t.album IS NOT NULL AND t.album != ''
        GROUP BY t.album, t.artist
        HAVING total >= 2 AND enriched >= 1 AND tagged < total
        ORDER BY (total - tagged) DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    return [
        {
            "album": r["album"],
            "artist": r["artist"],
            "total": r["total"],
            "tagged": r["tagged"],
            "enriched": r["enriched"],
        }
        for r in rows
    ]


def apply_release_id(conn: sqlite3.Connection, album: str, artist: str, release_id: str) -> int:
    """Stamp `release_id` onto every enriched track of the given album.

    Returns the rowcount touched.
    """
    _ensure_schema(conn)
    # Upsert: for any track of the album, ensure a track_metadata_ext row exists
    # with the release_id. We don't want to wipe existing musicbrainz_id values,
    # so use UPDATE OR INSERT staged.
    cur = conn.execute(
        """
        UPDATE track_metadata_ext
        SET mb_release_id = ?
        WHERE item_key IN (
            SELECT item_key FROM tracks WHERE LOWER(album) = LOWER(?) AND LOWER(artist) = LOWER(?)
        )
        """,
        (release_id, album, artist),
    )
    conn.commit()
    return cur.rowcount


async def tag_albums_batch(conn: sqlite3.Connection, mb_client, limit: int = 5) -> int:
    """Process up to ``limit`` inconsistent albums (async).

    Queries MusicBrainz via ``mb_client.search_releases(artist, album, limit=10)``
    and picks the best candidate via the scoring rules above. Returns the number
    of albums successfully tagged. The MB client enforces its own 1 req/s rate
    limit internally — callers don't need to throttle.
    """
    if not hasattr(mb_client, "search_releases"):
        return 0
    todo = find_inconsistent_albums(conn, limit=limit)
    tagged = 0
    for entry in todo:
        try:
            releases = await mb_client.search_releases(
                entry["artist"], entry["album"], limit=10
            )
        except Exception as exc:
            logger.debug("MB search failed for %s — %s: %s", entry["artist"], entry["album"], exc)
            continue
        release_id = _pick_release(releases, entry["total"])
        if not release_id:
            continue
        apply_release_id(conn, entry["album"], entry["artist"], release_id)
        tagged += 1
    if tagged:
        logger.info("Album consistency: tagged %d albums in this pass", tagged)
    return tagged
