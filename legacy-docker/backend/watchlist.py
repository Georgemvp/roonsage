"""Artist Watchlist — new Qobuz release detection for RoonSage.

Monitors a list of artists and checks Qobuz (via Roon Browse API) for releases
that weren't previously seen.  Uses artist_watchlist and artist_releases_cache
SQLite tables (added in db.py v8.0).

Usage::

    from backend.watchlist import get_watchlist, add_to_watchlist, scan_all_watched
"""

import asyncio
import json
import logging
from datetime import datetime
from typing import Any

logger = logging.getLogger(__name__)

# Seconds to wait between Qobuz requests during a scan (rate-limit protection)
_SCAN_RATE_LIMIT = 2.0

# How many top artists to pull from the taste profile when auto-populating
_AUTO_POPULATE_COUNT = 20

# Minimum artist weight (0-1) in the taste profile to be auto-added
_AUTO_POPULATE_MIN_WEIGHT = 0.5


# ---------------------------------------------------------------------------
# Internal DB helpers
# ---------------------------------------------------------------------------


def _get_conn():
    """Open an initialised DB connection (caller must close)."""
    from backend.db import get_db_connection  # noqa: PLC0415
    return get_db_connection()


# ---------------------------------------------------------------------------
# Watchlist CRUD
# ---------------------------------------------------------------------------


def get_watchlist() -> list[dict]:
    """Return all watched artists with their status.

    Returns:
        List of dicts with keys: id, artist_name, added_at, auto_added,
        monitor_albums, monitor_eps, monitor_singles, last_checked,
        last_new_release, unnotified_count.
    """
    conn = _get_conn()
    try:
        rows = conn.execute("""
            SELECT
                w.id,
                w.artist_name,
                w.added_at,
                w.auto_added,
                w.monitor_albums,
                w.monitor_eps,
                w.monitor_singles,
                w.last_checked,
                w.last_new_release,
                COUNT(r.id) AS unnotified_count
            FROM artist_watchlist w
            LEFT JOIN artist_releases_cache r
                ON r.artist_name = w.artist_name AND r.notified = 0
            GROUP BY w.id
            ORDER BY w.artist_name COLLATE NOCASE ASC
        """).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def add_to_watchlist(
    artist_name: str,
    *,
    auto: bool = False,
    monitor_albums: bool = True,
    monitor_eps: bool = True,
    monitor_singles: bool = False,
) -> dict:
    """Add an artist to the watchlist (idempotent — updates flags if already present).

    Args:
        artist_name:     Artist name (case-insensitive de-duplication via UNIQUE index).
        auto:            True when called by auto_populate_watchlist().
        monitor_albums:  Monitor full-length albums.
        monitor_eps:     Monitor EPs.
        monitor_singles: Monitor singles.

    Returns:
        The watchlist row as a dict.
    """
    conn = _get_conn()
    try:
        conn.execute(
            """
            INSERT INTO artist_watchlist
                (artist_name, auto_added, monitor_albums, monitor_eps, monitor_singles)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(artist_name) DO UPDATE SET
                monitor_albums  = excluded.monitor_albums,
                monitor_eps     = excluded.monitor_eps,
                monitor_singles = excluded.monitor_singles
            """,
            (
                artist_name,
                1 if auto else 0,
                1 if monitor_albums else 0,
                1 if monitor_eps else 0,
                1 if monitor_singles else 0,
            ),
        )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM artist_watchlist WHERE artist_name = ?", (artist_name,)
        ).fetchone()
        return dict(row) if row else {}
    finally:
        conn.close()


def remove_from_watchlist(artist_name: str) -> bool:
    """Remove an artist from the watchlist.

    Also removes the associated releases cache rows.

    Returns:
        True if a row was deleted, False if the artist was not found.
    """
    conn = _get_conn()
    try:
        conn.execute(
            "DELETE FROM artist_releases_cache WHERE artist_name = ?", (artist_name,)
        )
        cursor = conn.execute(
            "DELETE FROM artist_watchlist WHERE artist_name = ?", (artist_name,)
        )
        conn.commit()
        return cursor.rowcount > 0
    finally:
        conn.close()


def update_watchlist_entry(
    artist_name: str,
    *,
    monitor_albums: bool | None = None,
    monitor_eps: bool | None = None,
    monitor_singles: bool | None = None,
) -> dict:
    """Update monitor flags for an existing watchlist entry.

    Only the flags that are not None will be updated.
    """
    conn = _get_conn()
    try:
        updates = []
        params: list[Any] = []
        if monitor_albums is not None:
            updates.append("monitor_albums = ?")
            params.append(1 if monitor_albums else 0)
        if monitor_eps is not None:
            updates.append("monitor_eps = ?")
            params.append(1 if monitor_eps else 0)
        if monitor_singles is not None:
            updates.append("monitor_singles = ?")
            params.append(1 if monitor_singles else 0)

        if updates:
            params.append(artist_name)
            conn.execute(
                f"UPDATE artist_watchlist SET {', '.join(updates)} WHERE artist_name = ?",
                params,
            )
            conn.commit()

        row = conn.execute(
            "SELECT * FROM artist_watchlist WHERE artist_name = ?", (artist_name,)
        ).fetchone()
        return dict(row) if row else {}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Auto-populate from taste profile
# ---------------------------------------------------------------------------


def auto_populate_watchlist() -> list[str]:
    """Add top artists from the taste profile to the watchlist.

    Only artists with weight >= _AUTO_POPULATE_MIN_WEIGHT are added.
    Artists already in the watchlist are not duplicated (idempotent).

    Returns:
        List of artist names that were newly added.
    """
    try:
        from backend.taste_profile import TasteProfile  # noqa: PLC0415
        profile = TasteProfile.get()
    except Exception as exc:
        logger.warning("auto_populate_watchlist: failed to load taste profile: %s", exc)
        return []

    artists: dict[str, float] = profile.get("artists", {})
    if not artists:
        logger.info("auto_populate_watchlist: taste profile has no artists yet")
        return []

    # Sort by weight descending, take top N above threshold
    candidates = [
        name
        for name, weight in sorted(artists.items(), key=lambda x: -x[1])
        if weight >= _AUTO_POPULATE_MIN_WEIGHT
    ][:_AUTO_POPULATE_COUNT]

    added: list[str] = []
    conn = _get_conn()
    try:
        existing = {
            row[0]
            for row in conn.execute(
                "SELECT artist_name FROM artist_watchlist"
            ).fetchall()
        }
    finally:
        conn.close()

    for artist_name in candidates:
        # Split credit strings and take only the primary artist
        if " / " in artist_name:
            parts = artist_name.split(" / ")
            if len(parts) > 2:
                # Too many credits — not useful for Qobuz search
                continue
            artist_name = parts[0].strip()
        # Skip entries that are still too long (>50 chars = likely a credit string)
        if len(artist_name) > 50:
            continue

        if artist_name not in existing:
            try:
                add_to_watchlist(artist_name, auto=True)
                added.append(artist_name)
                logger.info("Auto-added to watchlist: %s", artist_name)
            except Exception as exc:
                logger.warning("auto_populate_watchlist: failed to add %s: %s", artist_name, exc)

    logger.info(
        "auto_populate_watchlist: %d candidates, %d newly added", len(candidates), len(added)
    )
    return added


# ---------------------------------------------------------------------------
# Release type classifier
# ---------------------------------------------------------------------------

_ALBUM_KEYWORDS = {"album", "lp", "full", "record"}
_EP_KEYWORDS = {"ep", "e.p.", "mini", "maxi", "mini-album"}
_SINGLE_KEYWORDS = {"single", "7\"", "12\"", "7-inch", "12-inch"}


def _classify_release_type(title: str, subtitle: str = "") -> str:
    """Guess the release type from title/subtitle strings returned by Qobuz."""
    text = (title + " " + subtitle).lower()
    for kw in _SINGLE_KEYWORDS:
        if kw in text:
            return "single"
    for kw in _EP_KEYWORDS:
        if kw in text:
            return "ep"
    # Default: album (most Qobuz results are albums)
    return "album"


def _extract_date(subtitle: str) -> str | None:
    """Try to extract a release date (YYYY or YYYY-MM-DD) from a Qobuz subtitle."""
    import re  # noqa: PLC0415
    # Match YYYY-MM-DD
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", subtitle)
    if m:
        return m.group(1)
    # Match bare year
    m = re.search(r"\b(20\d{2}|19\d{2})\b", subtitle)
    if m:
        return m.group(1)
    return None


# ---------------------------------------------------------------------------
# Per-artist release check
# ---------------------------------------------------------------------------


def check_artist_releases(artist_name: str) -> list[dict]:
    """Search Qobuz for the artist and return newly-discovered releases.

    This is a *synchronous* function that calls into qobuz_browser.py
    (which requires the Roon client).  Call it from a thread, not the event loop.

    Returns:
        List of new release dicts:
            {artist_name, album_title, release_date, release_type,
             qobuz_id, item_key, first_seen_at}
        Empty list when Roon/Qobuz is unavailable or no new releases found.
    """
    from backend.roon_client import get_roon_client  # noqa: PLC0415

    roon = get_roon_client()
    if roon is None or not roon.is_connected():
        logger.debug("check_artist_releases: Roon not connected — skipping %s", artist_name)
        return []

    try:
        from backend.qobuz_browser import search_qobuz_tracks_sync  # noqa: PLC0415
        results = search_qobuz_tracks_sync(roon, artist_name, limit=25)
    except Exception as exc:
        logger.warning("check_artist_releases: Qobuz search failed for %s: %s", artist_name, exc)
        return []

    if not results:
        logger.debug("check_artist_releases: no Qobuz results for %s", artist_name)
        _update_last_checked(artist_name)
        return []

    # Group results into unique albums (deduplicate by album title)
    seen_albums: dict[str, dict] = {}
    for track in results:
        album = (track.get("album") or "").strip()
        if not album or album in seen_albums:
            continue
        # Only include tracks by this artist (Qobuz returns broader results)
        track_artist = (track.get("artist") or "").lower()
        if artist_name.lower() not in track_artist and track_artist not in artist_name.lower():
            continue
        release_type = _classify_release_type(
            album, track.get("subtitle") or ""
        )
        release_date = _extract_date(track.get("subtitle") or "")
        seen_albums[album] = {
            "artist_name": artist_name,
            "album_title": album,
            "release_date": release_date,
            "release_type": release_type,
            "qobuz_id": track.get("qobuz_id") or None,
            "item_key": track.get("item_key") or None,
        }

    new_releases: list[dict] = []
    now = datetime.utcnow().isoformat()

    conn = _get_conn()
    try:
        # Load watchlist entry to check monitor flags
        wl_row = conn.execute(
            "SELECT * FROM artist_watchlist WHERE artist_name = ?", (artist_name,)
        ).fetchone()
        monitor_albums = bool(wl_row["monitor_albums"]) if wl_row else True
        monitor_eps = bool(wl_row["monitor_eps"]) if wl_row else True
        monitor_singles = bool(wl_row["monitor_singles"]) if wl_row else False

        for album_title, release in seen_albums.items():
            rtype = release["release_type"]
            # Respect per-artist monitor flags
            if rtype == "album" and not monitor_albums:
                continue
            if rtype == "ep" and not monitor_eps:
                continue
            if rtype == "single" and not monitor_singles:
                continue

            # Try to insert; if UNIQUE conflict, it was already cached → not new
            cursor = conn.execute(
                """
                INSERT OR IGNORE INTO artist_releases_cache
                    (artist_name, album_title, release_date, release_type,
                     qobuz_id, item_key, first_seen_at, notified)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """,
                (
                    artist_name,
                    album_title,
                    release["release_date"],
                    rtype,
                    release["qobuz_id"],
                    release["item_key"],
                    now,
                ),
            )
            if cursor.rowcount > 0:
                # Genuinely new — fetch the auto-incremented id
                row = conn.execute(
                    "SELECT * FROM artist_releases_cache WHERE artist_name = ? AND album_title = ?",
                    (artist_name, album_title),
                ).fetchone()
                if row:
                    entry = dict(row)
                    new_releases.append(entry)
                    logger.info(
                        "New release detected: %s — %s (%s)",
                        artist_name, album_title, rtype,
                    )

        # Update last_new_release JSON if we found something
        if new_releases:
            latest = new_releases[0]
            conn.execute(
                "UPDATE artist_watchlist SET last_new_release = ? WHERE artist_name = ?",
                (
                    json.dumps(
                        {
                            "title": latest["album_title"],
                            "date": latest["release_date"],
                            "type": latest["release_type"],
                        },
                        ensure_ascii=False,
                    ),
                    artist_name,
                ),
            )

        # Always update last_checked
        conn.execute(
            "UPDATE artist_watchlist SET last_checked = ? WHERE artist_name = ?",
            (now, artist_name),
        )
        conn.commit()
    finally:
        conn.close()

    return new_releases


def _update_last_checked(artist_name: str) -> None:
    """Stamp the last_checked timestamp without touching anything else."""
    conn = _get_conn()
    try:
        conn.execute(
            "UPDATE artist_watchlist SET last_checked = datetime('now') WHERE artist_name = ?",
            (artist_name,),
        )
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Unnotified releases CRUD
# ---------------------------------------------------------------------------


def get_new_releases(notified: bool = False) -> list[dict]:
    """Return releases from the cache.

    Args:
        notified: When False (default) return only unnotified releases.
                  When True return all releases.
    """
    conn = _get_conn()
    try:
        if notified:
            rows = conn.execute(
                "SELECT * FROM artist_releases_cache ORDER BY first_seen_at DESC"
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM artist_releases_cache WHERE notified = 0 "
                "ORDER BY first_seen_at DESC"
            ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def dismiss_release(release_id: int) -> bool:
    """Mark a release as notified (dismissed by the user).

    Returns True if the row was updated.
    """
    conn = _get_conn()
    try:
        cursor = conn.execute(
            "UPDATE artist_releases_cache SET notified = 1 WHERE id = ?", (release_id,)
        )
        conn.commit()
        return cursor.rowcount > 0
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Full scan
# ---------------------------------------------------------------------------


_SCAN_BATCH_SIZE = 5  # artists checked in parallel per batch


async def scan_all_watched() -> list[dict]:
    """Check every watched artist for new Qobuz releases.

    Runs synchronous Qobuz calls in a thread via asyncio.to_thread().
    Artists are processed in parallel batches of _SCAN_BATCH_SIZE with
    _SCAN_RATE_LIMIT seconds between batches (~5× faster than serial).

    Returns:
        Flat list of all new release dicts found across all artists.
    """
    conn = _get_conn()
    try:
        rows = conn.execute(
            "SELECT artist_name FROM artist_watchlist ORDER BY last_checked ASC NULLS FIRST"
        ).fetchall()
        artists = [r["artist_name"] for r in rows]
    finally:
        conn.close()

    if not artists:
        logger.info("scan_all_watched: watchlist is empty")
        return []

    logger.info("scan_all_watched: checking %d artists in batches of %d", len(artists), _SCAN_BATCH_SIZE)
    all_new: list[dict] = []

    for batch_start in range(0, len(artists), _SCAN_BATCH_SIZE):
        if batch_start > 0:
            await asyncio.sleep(_SCAN_RATE_LIMIT)

        batch = artists[batch_start : batch_start + _SCAN_BATCH_SIZE]
        tasks = [asyncio.to_thread(check_artist_releases, name) for name in batch]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        for artist_name, result in zip(batch, results, strict=True):
            if isinstance(result, Exception):
                logger.warning("scan_all_watched: error for %s: %s", artist_name, result)
            else:
                all_new.extend(result)

    if all_new:
        logger.info(
            "scan_all_watched: found %d new release(s) across %d artists",
            len(all_new),
            len({r["artist_name"] for r in all_new}),
        )
        # Emit notification for each unique artist that has new releases
        try:
            from backend.notifications import EventType, event_bus  # noqa: PLC0415
            for release in all_new:
                await event_bus.emit_async(
                    EventType.NEW_RELEASE_FOUND,
                    {
                        "artist": release["artist_name"],
                        "album": release["album_title"],
                        "release_type": release["release_type"],
                        "release_date": release.get("release_date"),
                    },
                )
        except Exception as exc:
            logger.debug("scan_all_watched: notification emit failed: %s", exc)

        # Automation: fire WATCHLIST_MATCH event per new release
        try:
            from backend.automation_engine import TriggerType, get_engine  # noqa: PLC0415
            _eng = get_engine()
            if _eng:
                for release in all_new:
                    await _eng.on_event_async(TriggerType.WATCHLIST_MATCH, {
                        "artist": release["artist_name"],
                        "album": release["album_title"],
                    })
        except Exception as exc:
            logger.debug("scan_all_watched: automation event failed: %s", exc)
    else:
        logger.info("scan_all_watched: no new releases found")

    return all_new
