"""Library sync logic for RoonSage.

Syncs track and album metadata from the Roon Core into the local SQLite
cache.  Also provides sync-state inspection helpers used by routes and the
startup health check.
"""

import json
import logging
import threading
import time
from datetime import datetime, timezone
from typing import Any, Callable

from backend.db import clear_migration_flag, ensure_db_initialized, get_connection
from backend.roon_utils import is_live_version

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Sync constants and in-memory state
# ---------------------------------------------------------------------------

SYNC_BATCH_SIZE = 500

# In-memory sync progress (updated under _sync_lock during sync_library)
_sync_state: dict[str, Any] = {
    "is_syncing": False,
    "phase": None,  # "fetching_albums" | "fetching" | "processing"
    "current": 0,
    "total": 0,
    "error": None,
}

_sync_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _is_live(title: str, album: str) -> bool:
    """Thin adapter: check whether a title/album string pair looks live.

    Delegates to roon_utils.is_live_version so pattern definitions stay
    in one place.
    """
    return is_live_version({"title": title, "subtitle": album})


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def get_sync_state() -> dict[str, Any]:
    """Return current sync state from the database and in-memory progress.

    Returns:
        Dict with track_count, synced_at, roon_core_id, sync_duration_ms,
        is_syncing, sync_progress (or None), and error.
    """
    with get_connection() as conn:
        row = conn.execute(
            "SELECT roon_core_id, last_sync_at, track_count, sync_duration_ms "
            "FROM sync_state WHERE id = 1"
        ).fetchone()

        with _sync_lock:
            ss = dict(_sync_state)

        result: dict[str, Any] = {
            "track_count": row["track_count"] if row else 0,
            "synced_at": row["last_sync_at"] if row else None,
            "roon_core_id": row["roon_core_id"] if row else None,
            "sync_duration_ms": row["sync_duration_ms"] if row else None,
            "is_syncing": ss["is_syncing"],
            "sync_progress": None,
            "error": ss["error"],
        }

        if ss["is_syncing"]:
            result["sync_progress"] = {
                "phase": ss["phase"],
                "current": ss["current"],
                "total": ss["total"],
            }

        return result


def get_sync_progress() -> dict[str, Any]:
    """Return the current in-memory sync progress snapshot (for polling)."""
    with _sync_lock:
        return dict(_sync_state)


def clear_cache() -> None:
    """Delete all cached tracks and reset the sync state row."""
    with get_connection() as conn:
        conn.execute("DELETE FROM tracks")
        conn.execute(
            "UPDATE sync_state SET last_sync_at = NULL, track_count = 0, "
            "sync_duration_ms = NULL WHERE id = 1"
        )
        conn.commit()
        logger.info("Cache cleared")


def is_cache_stale(max_age_hours: int = 24) -> bool:
    """Return True if the cache is empty or older than *max_age_hours*."""
    state = get_sync_state()
    if not state["synced_at"]:
        return True

    try:
        synced_at = datetime.fromisoformat(state["synced_at"].replace("Z", "+00:00"))
        age_hours = (datetime.now(timezone.utc) - synced_at).total_seconds() / 3600
        return age_hours > max_age_hours
    except (ValueError, TypeError):
        return True


def check_server_changed(current_server_id: str) -> bool:
    """Return True if the Roon Core ID has changed since the last sync.

    Args:
        current_server_id: The current Roon Core's unique identifier.

    Returns:
        True when the cached ID differs (cache should be cleared before sync).
    """
    cached_server_id = get_sync_state().get("roon_core_id")
    if not cached_server_id:
        return False  # First sync — no prior ID to compare
    return cached_server_id != current_server_id


def sync_library(
    roon_client: Any,
    on_progress: Callable[[int, int], None] | None = None,
) -> dict[str, Any]:
    """Sync tracks from the Roon Core into the local SQLite cache.

    This is a blocking synchronous operation.  For async usage wrap it in
    ``asyncio.to_thread()``.

    Args:
        roon_client: RoonClient instance with an active Roon connection.
        on_progress: Optional callback(current, total) called after every
            SYNC_BATCH_SIZE tracks are written.

    Returns:
        Dict with ``success`` (bool), ``track_count`` (int), and either
        ``duration_ms`` (int) on success or ``error`` (str) on failure.
    """
    global _sync_state

    with _sync_lock:
        if _sync_state["is_syncing"]:
            return {"success": False, "error": "Sync already in progress"}

        _sync_state = {
            "is_syncing": True,
            "phase": "fetching_albums",
            "current": 0,
            "total": 0,
            "error": None,
        }

    start_time = time.time()
    conn = None

    try:
        # ----------------------------------------------------------------
        # Step 0 — identify the Roon Core
        # ----------------------------------------------------------------
        server_id = roon_client.get_core_id()
        if not server_id:
            raise ValueError("Could not get Roon Core identifier")

        if check_server_changed(server_id):
            logger.info("Roon Core changed, clearing cache")
            clear_cache()

        conn = ensure_db_initialized()

        # ----------------------------------------------------------------
        # Phase 1 — fetch album metadata for genre/year enrichment
        # ----------------------------------------------------------------
        logger.info("Fetching album metadata from Roon...")
        album_metadata: dict[str, Any] = roon_client.get_all_albums_metadata()
        logger.info("Got metadata for %d albums", len(album_metadata))

        album_batch = [
            (
                item_key,
                meta.get("title", "Unknown Album"),
                meta.get("artist", "Unknown Artist"),
                meta.get("year"),
                json.dumps(meta.get("genres", [])),
                meta.get("image_key", ""),
            )
            for item_key, meta in album_metadata.items()
        ]

        conn.execute("DELETE FROM albums")  # Full replace each sync
        conn.executemany(
            "INSERT INTO albums (item_key, title, artist, year, genres, image_key, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, datetime('now'))",
            album_batch,
        )
        conn.commit()
        logger.info("Stored %d albums in albums table", len(album_batch))

        # Build artist → genres mapping for track-level genre enrichment fallback
        artist_genres: dict[str, list[str]] = {}
        for meta in album_metadata.values():
            artist_lower = meta.get("artist", "").strip().lower()
            if not artist_lower:
                continue
            existing = artist_genres.setdefault(artist_lower, [])
            for g in meta.get("genres", []):
                if g not in existing:
                    existing.append(g)

        # ----------------------------------------------------------------
        # Phase 2 — fetch all tracks from Roon
        # ----------------------------------------------------------------
        with _sync_lock:
            _sync_state["phase"] = "fetching"

        def _on_album_progress(current: int, total: int) -> None:
            with _sync_lock:
                _sync_state["phase"] = "fetching"
                _sync_state["current"] = current
                _sync_state["total"] = total

        logger.info("Fetching all tracks from Roon (this may take a while)...")
        all_tracks: list[dict] = roon_client.get_all_raw_tracks(
            on_album_progress=_on_album_progress
        )
        total = len(all_tracks)
        logger.info("Got %d tracks from Roon", total)

        with _sync_lock:
            _sync_state["total"] = total
            _sync_state["phase"] = "processing"

        # Full replace: clear existing cache only after a successful Roon fetch
        # so that a network failure in Phase 1/2 leaves the previous cache intact.
        # (Roon Browse API issues different item_keys across sessions — incremental
        # updates would accumulate stale rows indefinitely.)
        logger.info("Clearing existing track cache for full replace...")
        conn.execute("DELETE FROM track_genres")   # FK child first
        conn.execute("DELETE FROM tracks")
        conn.commit()

        # ----------------------------------------------------------------
        # Phase 3 — process tracks in batches with album metadata lookup
        # ----------------------------------------------------------------
        synced_count = 0
        batch_data: list[tuple] = []

        # Build reverse lookup by album title for flat browse tracks
        album_by_title: dict[str, dict] = {}
        for meta in album_metadata.values():
            title_lower = meta.get("title", "").lower()
            if title_lower and title_lower not in album_by_title:
                album_by_title[title_lower] = meta

        for track in all_tracks:
            title = track.get("title", "Unknown Track")
            subtitle = track.get("subtitle", "") or ""
            sub_parts = [p.strip() for p in subtitle.split("•")]
            artist = sub_parts[0] if sub_parts else "Unknown Artist"
            album = (
                sub_parts[1] if len(sub_parts) > 1
                else track.get("_album_title", "Unknown Album")
            )

            # Resolve genres and year via album item_key
            album_item_key = track.get("_album_item_key", "")
            album_data = album_metadata.get(album_item_key, {})
            if not album_data:
                fallback_title = track.get("_album_title") or album
                if fallback_title and fallback_title != "Unknown Album":
                    album_data = album_by_title.get(fallback_title.lower(), {})

            genres = album_data.get("genres", [])

            # Artist-based genre fallback (flat browse has no album item_key)
            if not genres:
                artist_lower = artist.strip().lower()
                genres = artist_genres.get(artist_lower, [])

                if not genres and "," in artist:
                    first_artist = artist.split(",")[0].strip().lower()
                    genres = artist_genres.get(first_artist, [])

                if not genres and "," in artist:
                    for individual in artist.split(","):
                        matched = artist_genres.get(individual.strip().lower(), [])
                        if matched:
                            genres = matched
                            break

            year = album_data.get("year")

            # Flat browse tracks have no _album_item_key; generate a synthetic
            # key so get_album_candidates() can group them into albums.
            if not album_item_key:
                album_item_key = f"synth:{artist}|||{album}"

            item_key = track.get("item_key", "")

            batch_data.append((
                item_key,
                title,
                artist,
                album,
                track.get("duration", 0) * 1000 if track.get("duration") else 0,
                year,
                json.dumps(genres),
                _is_live(title, album),
                album_item_key,   # stored in parent_item_key
                0,                # view_count (Roon API doesn't expose plays)
                None,             # last_viewed_at
            ))

            if len(batch_data) >= SYNC_BATCH_SIZE:
                conn.executemany(
                    "INSERT OR REPLACE INTO tracks "
                    "(item_key, title, artist, album, duration_ms, year, genres, "
                    "is_live, parent_item_key, view_count, last_viewed_at, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))",
                    batch_data,
                )
                synced_count += len(batch_data)
                batch_data = []

                with _sync_lock:
                    _sync_state["current"] = synced_count
                if on_progress:
                    on_progress(synced_count, total)

                logger.info("Synced %d/%d tracks", synced_count, total)
                conn.commit()  # Allow concurrent reads (WAL mode)

        # Insert remaining tracks
        if batch_data:
            conn.executemany(
                "INSERT OR REPLACE INTO tracks "
                "(item_key, title, artist, album, duration_ms, year, genres, "
                "is_live, parent_item_key, view_count, last_viewed_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))",
                batch_data,
            )
            synced_count += len(batch_data)
            with _sync_lock:
                _sync_state["current"] = synced_count

        conn.commit()

        # ----------------------------------------------------------------
        # Post-processing: backfill year, rebuild genre junction table
        # ----------------------------------------------------------------
        logger.info("Backfilling track year from albums table...")
        conn.execute("""
            UPDATE tracks SET year = (
                SELECT a.year FROM albums a
                WHERE a.item_key = tracks.parent_item_key
                AND a.year IS NOT NULL
            )
            WHERE year IS NULL
            AND parent_item_key IS NOT NULL
            AND parent_item_key != ''
        """)
        conn.commit()
        backfilled = conn.execute(
            "SELECT COUNT(*) FROM tracks WHERE year IS NOT NULL"
        ).fetchone()[0]
        logger.info("Year backfill complete: %d tracks now have year data", backfilled)

        logger.info("Rebuilding track_genres junction table...")
        genre_rows = conn.execute(
            "SELECT item_key, genres FROM tracks WHERE genres IS NOT NULL AND genres != '[]'"
        ).fetchall()
        genre_batch: list[tuple[str, str]] = []
        for grow in genre_rows:
            try:
                glist = json.loads(grow["genres"])
            except (json.JSONDecodeError, TypeError):
                continue
            for g in glist:
                if g:
                    genre_batch.append((grow["item_key"], g))
        if genre_batch:
            conn.executemany(
                "INSERT OR IGNORE INTO track_genres (track_key, genre) VALUES (?, ?)",
                genre_batch,
            )
        conn.commit()
        logger.info(
            "Populated track_genres with %d rows for %d tracks",
            len(genre_batch), len(genre_rows),
        )

        # ----------------------------------------------------------------
        # Update sync_state metadata row
        # ----------------------------------------------------------------
        duration_ms = int((time.time() - start_time) * 1000)
        synced_at = datetime.now(timezone.utc).isoformat()

        conn.execute(
            "UPDATE sync_state SET roon_core_id = ?, last_sync_at = ?, "
            "track_count = ?, sync_duration_ms = ? WHERE id = 1",
            (server_id, synced_at, synced_count, duration_ms),
        )
        conn.commit()

        logger.info("Sync complete: %d tracks in %dms", synced_count, duration_ms)

        # New columns are now populated — migration no longer requires a re-sync
        clear_migration_flag()

        # Fire-and-forget notification
        try:
            from backend.notifications import EventType, event_bus  # noqa: PLC0415
            event_bus.emit(
                EventType.LIBRARY_SYNC_COMPLETE,
                {"track_count": synced_count, "duration_ms": duration_ms},
            )
        except Exception:
            pass

        return {
            "success": True,
            "track_count": synced_count,
            "duration_ms": duration_ms,
        }

    except Exception as exc:
        logger.exception("Sync failed: %s", exc)
        with _sync_lock:
            _sync_state["error"] = str(exc)

        # Fire-and-forget notification
        try:
            from backend.notifications import EventType, event_bus  # noqa: PLC0415
            event_bus.emit(
                EventType.LIBRARY_SYNC_FAILED,
                {"error": str(exc)},
            )
        except Exception:
            pass

        return {"success": False, "error": str(exc)}

    finally:
        with _sync_lock:
            _sync_state["is_syncing"] = False
            _sync_state["phase"] = None
            _sync_state["current"] = 0
            _sync_state["total"] = 0
        if conn:
            conn.close()
