"""Listening history monitor and Roon Tags browser for RoonSage intelligence layer.

This mixin is intentionally kept separate from roon_browse.py because:
- It uses zone-change callbacks and a background fallback thread, NOT the Browse API.
- Mixing browse-lock usage with the monitor thread would cause deadlocks.
"""

import asyncio
import logging
import threading
import time
from datetime import datetime
from typing import Any

logger = logging.getLogger(__name__)

# Module-level reference to the running asyncio event loop (set by main.py lifespan).
# Used to schedule fire-and-forget coroutines from sync monitor threads.
_event_loop: asyncio.AbstractEventLoop | None = None


def set_monitor_event_loop(loop: asyncio.AbstractEventLoop) -> None:
    """Register the main asyncio event loop for fire-and-forget LB submissions."""
    global _event_loop
    _event_loop = loop


def _fire_and_forget(coro) -> None:
    """Schedule *coro* on the registered event loop without blocking."""
    loop = _event_loop
    if loop is None or loop.is_closed():
        return
    try:
        asyncio.run_coroutine_threadsafe(coro, loop)
    except Exception as exc:
        logger.debug("fire_and_forget failed: %s", exc)


def _fire_and_forget_sync(fn) -> None:
    """Run *fn* (a regular callable) in a daemon thread without blocking."""
    threading.Thread(
        target=fn,
        daemon=True,
        name="roonsage-profile-recompute",
    ).start()


# Minimum seconds a track must play before being logged (avoids noise from
# brief previews or truly accidental presses).
_MIN_PLAY_SECONDS = 2

# ── Genre enrichment LRU cache ─────────────────────────────────────────────────
# Maps "artist|title" → (genre, year) to avoid repeated SQLite fuzzy queries
# for the same track within a session.
_genre_cache: dict[str, tuple[str, int | None]] = {}
_GENRE_CACHE_MAX = 500

# ── Auto-recompute taste profile ───────────────────────────────────────────────
_listen_count_since_recompute = 0
_RECOMPUTE_EVERY = 15


class RoonIntelligenceMixin:
    """Mixin providing listening history monitoring and Roon Tags access."""

    # -------------------------------------------------------------------------
    # Listening history monitor
    # -------------------------------------------------------------------------

    def start_listening_monitor(self) -> None:
        """Register zone-change callback and start a fallback polling thread.

        Safe to call multiple times — only one thread/callback will run at a time.
        Requires Roon to be connected; call this only after is_connected() is True.
        """
        if not hasattr(self, "_last_zone_states"):
            self._last_zone_states: dict[str, dict] = {}

        # ── Real-time callback (primary) ───────────────────────────────────
        api = getattr(self, "_api", None)
        if api is not None:
            try:
                api.register_state_callback(
                    self._on_zones_changed,
                    event_filter=["zones_changed"],
                )
                logger.info("Listening monitor: registered zones_changed callback")
            except Exception as exc:
                logger.warning(
                    "Could not register zone callback, falling back to polling only: %s", exc
                )

        # ── Fallback polling thread (30 s interval) ────────────────────────
        existing: threading.Thread | None = getattr(
            self, "_listening_monitor_thread", None
        )
        if existing is not None and existing.is_alive():
            logger.debug("Fallback polling thread already running")
            return

        t = threading.Thread(
            target=self._monitor_zones_fallback,
            daemon=True,
            name="roonsage-listening-monitor",
        )
        self._listening_monitor_thread = t
        t.start()
        logger.info("Listening monitor fallback polling thread started (30 s interval)")

    # ── Callback path (real-time) ──────────────────────────────────────────

    def _on_zones_changed(self, event: str, changed_ids) -> None:
        """Roon zone-change callback — fires instantly on any zone state change."""
        try:
            api = getattr(self, "_api", None)
            if api is None:
                return
            zones_dict: dict = api.zones or {}
            for zone_id, zone in zones_dict.items():
                self._process_zone_change(zone_id, zone)
        except Exception as exc:
            logger.warning("Zone callback error: %s", exc)

    # ── Fallback polling path (30 s) ───────────────────────────────────────

    def _monitor_zones_fallback(self) -> None:
        """Background loop: poll zones every 30 s to catch missed callback events."""
        while True:
            try:
                if self.is_connected():
                    api = getattr(self, "_api", None)
                    if api is not None:
                        zones_dict: dict = api.zones or {}
                        for zone_id, zone in zones_dict.items():
                            self._process_zone_change(zone_id, zone)
            except Exception as exc:
                logger.warning("Fallback monitor error: %s", exc)

            time.sleep(30)

    # ── Core zone-change logic ─────────────────────────────────────────────

    def _process_zone_change(self, zone_id: str, zone: dict) -> None:
        """Detect track changes in a zone and log completed listens."""
        if not hasattr(self, "_last_zone_states"):
            self._last_zone_states = {}

        state = zone.get("state", "stopped")
        now_playing: dict | None = zone.get("now_playing")

        if not now_playing or state != "playing":
            # Zone stopped/paused — log whatever was playing
            prev = self._last_zone_states.pop(zone_id, None)
            if prev:
                played = _calc_played(prev, now_playing)
                if played >= _MIN_PLAY_SECONDS:
                    duration = prev.get("duration", 0)
                    skipped = _is_skipped(played, duration)
                    self._log_listen(
                        prev, played, skipped, zone.get("display_name", zone_id)
                    )
            return

        track_key = (
            f"{now_playing.get('three_line', {}).get('line2', '')}|"
            f"{now_playing.get('three_line', {}).get('line1', '')}"
        )
        # Fallback: use one_line
        if track_key == "|":
            track_key = now_playing.get("one_line", {}).get("line1", "")

        prev = self._last_zone_states.get(zone_id)

        if prev and prev.get("track_key") != track_key:
            # Track changed — log the previous one
            played = _calc_played(prev, now_playing)
            if played >= _MIN_PLAY_SECONDS:
                duration = prev.get("duration", 0)
                skipped = _is_skipped(played, duration)
                self._log_listen(
                    prev, played, skipped, zone.get("display_name", zone_id)
                )

        if not prev or prev.get("track_key") != track_key:
            # New track started — record start state
            three = now_playing.get("three_line", {})
            title = three.get("line1") or now_playing.get("one_line", {}).get("line1", "")
            artist = three.get("line2", "")
            album = three.get("line3", "")
            seek_pos = now_playing.get("seek_position") or 0
            self._last_zone_states[zone_id] = {
                "track_key":  track_key,
                "title":      title,
                "artist":     artist,
                "album":      album,
                "genre":      "",  # Roon doesn't expose genre in now_playing
                "duration":   now_playing.get("length", 0),
                "started_at": time.time(),
                "start_seek": seek_pos,
            }
            # Fire-and-forget: submit now_playing to ListenBrainz
            if title and artist:
                try:
                    from backend.listenbrainz_client import get_lb_client  # noqa: PLC0415
                    lb = get_lb_client()
                    if lb:
                        _fire_and_forget(lb.submit_now_playing(artist, title, album))
                except Exception as exc:
                    logger.debug("LB now_playing submit failed: %s", exc)

    def _log_listen(
        self,
        track_info: dict,
        played_seconds: int,
        skipped: int,
        zone_name: str,
    ) -> None:
        """Insert a completed listen into listening_history with enriched metadata."""
        global _listen_count_since_recompute

        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                title = track_info.get("title", "")
                artist = track_info.get("artist", "")
                album = track_info.get("album", "")
                duration = track_info.get("duration", 0)

                # ── Genre/year enrichment from SQLite library cache ────────────
                genre = track_info.get("genre", "")
                year: int | None = None
                decade: str | None = None

                # Check LRU cache first to avoid redundant fuzzy queries
                cache_key = f"{artist}|{title}"
                if cache_key in _genre_cache:
                    genre, year = _genre_cache[cache_key]
                else:
                    try:
                        if not genre and artist and title:
                            from rapidfuzz import fuzz  # noqa: PLC0415
                            candidates = conn.execute(
                                "SELECT item_key, title, artist, year FROM tracks "
                                "WHERE artist LIKE ? LIMIT 20",
                                (f"%{artist[:20]}%",),
                            ).fetchall()
                            best_key: str | None = None
                            best_score = 0
                            for row in candidates:
                                score = fuzz.token_sort_ratio(
                                    f"{artist} {title}",
                                    f"{row['artist']} {row['title']}",
                                )
                                if score > best_score:
                                    best_score = score
                                    best_key = row["item_key"]
                                    if row["year"]:
                                        year = row["year"]
                            if best_key and best_score >= 80:
                                genre_rows = conn.execute(
                                    "SELECT genre FROM track_genres WHERE track_key = ?",
                                    (best_key,),
                                ).fetchall()
                                genre = ", ".join(r["genre"] for r in genre_rows)

                            # Store in cache (evict oldest when full)
                            _genre_cache[cache_key] = (genre, year)
                            if len(_genre_cache) > _GENRE_CACHE_MAX:
                                _genre_cache.pop(next(iter(_genre_cache)))
                    except Exception as enrich_exc:
                        logger.warning("Genre enrichment failed: %s", enrich_exc)

                # ── Decade ────────────────────────────────────────────────────
                if year:
                    decade = f"{(year // 10) * 10}s"

                # ── Time columns ──────────────────────────────────────────────
                now = datetime.now()
                hour_of_day = now.hour
                day_of_week = now.weekday()  # 0 = Monday

                # ── played_pct ────────────────────────────────────────────────
                played_pct: float | None = (
                    played_seconds / duration if duration > 0 else None
                )

                conn.execute(
                    """
                    INSERT INTO listening_history
                        (zone_name, track_title, artist, album, genre,
                         duration_seconds, played_seconds, skipped,
                         year, decade, hour_of_day, day_of_week, source,
                         played_pct)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        zone_name,
                        title,
                        artist,
                        album,
                        genre,
                        duration,
                        played_seconds,
                        skipped,
                        year,
                        decade,
                        hour_of_day,
                        day_of_week,
                        "library",
                        played_pct,
                    ),
                )
                conn.commit()
                logger.debug(
                    "Logged listen: '%s' by %s (%ds, skipped=%d, pct=%.0f%%, genre=%s)",
                    title,
                    artist,
                    played_seconds,
                    skipped,
                    (played_pct or 0) * 100,
                    genre or "?",
                )

                # ── ListenBrainz scrobble (fire-and-forget) ───────────────────
                # Scrobble when: not skipped AND (played >= 30s OR played >= duration/2)
                duration_threshold = max(30, (duration // 2) if duration > 0 else 30)
                if played_seconds >= duration_threshold and title and artist:
                    try:
                        from backend.listenbrainz_client import get_lb_client  # noqa: PLC0415
                        lb = get_lb_client()
                        if lb:
                            listened_at = int(time.time())
                            _fire_and_forget(
                                lb.submit_listen(
                                    artist=artist,
                                    title=title,
                                    album=album,
                                    duration_ms=duration * 1000,
                                    listened_at=listened_at,
                                )
                            )
                    except Exception as lb_exc:
                        logger.debug("LB scrobble failed: %s", lb_exc)

                # ── Auto-recompute taste profile every N listens ───────────────
                _listen_count_since_recompute += 1
                if _listen_count_since_recompute >= _RECOMPUTE_EVERY:
                    _listen_count_since_recompute = 0
                    try:
                        from backend.taste_profile import TasteProfile  # noqa: PLC0415
                        _fire_and_forget_sync(TasteProfile.compute_profile_from_history)
                    except Exception as exc:
                        logger.debug("Auto-recompute failed: %s", exc)

            finally:
                conn.close()
        except Exception as exc:
            logger.warning("Failed to log listen: %s", exc)

    # -------------------------------------------------------------------------
    # Roon Tags browser (uses Browse API via _browse_lock)
    # -------------------------------------------------------------------------

    def get_tags(self) -> list[dict]:
        """Return all user-created Roon Tags via the Browse API.

        Each item has: title, item_key.
        Returns [] when Roon is not connected or Tags are not found.
        """
        if not self.is_connected():
            return []

        try:
            with self._browse_lock:
                return self._browse_tags_locked()
        except Exception as exc:
            logger.warning("get_tags failed: %s", exc)
            return []

    def _browse_tags_locked(self) -> list[dict]:
        """Navigate Browse API to the Tags section.  Must hold _browse_lock."""
        api = self._api

        # Step 1: pop to root
        api.browse_browse({"hierarchy": "browse", "pop_all": True})
        root_page = api.browse_load({"hierarchy": "browse", "count": 100})
        root_items = root_page.get("items", []) if root_page else []

        # Step 2: enter Library
        library_item = next(
            (i for i in root_items if "library" in (i.get("title") or "").lower()),
            None,
        )
        if not library_item:
            logger.debug("Tags browse: Library not found in root")
            return []

        api.browse_browse(
            {"hierarchy": "browse", "item_key": library_item["item_key"]}
        )
        lib_page = api.browse_load({"hierarchy": "browse", "count": 100})
        lib_items = lib_page.get("items", []) if lib_page else []

        # Step 3: enter Tags
        tags_item = next(
            (i for i in lib_items if (i.get("title") or "").lower() in ("tags", "label", "labels")),
            None,
        )
        if not tags_item:
            logger.debug(
                "Tags browse: Tags section not found in Library. Available: %s",
                [i.get("title") for i in lib_items],
            )
            return []

        api.browse_browse(
            {"hierarchy": "browse", "item_key": tags_item["item_key"]}
        )
        tags_page = self._paginate_browse_load("browse")

        return [
            {"title": i.get("title", ""), "item_key": i.get("item_key", "")}
            for i in tags_page
            if i.get("item_key")
        ]

    def get_tag_tracks(self, tag_item_key: str) -> list[dict[str, Any]]:
        """Return all tracks in a specific Roon tag (by its item_key).

        Each item has: title, item_key, subtitle.
        """
        if not self.is_connected():
            return []

        try:
            with self._browse_lock:
                self._api.browse_browse(
                    {"hierarchy": "browse", "item_key": tag_item_key}
                )
                items = self._paginate_browse_load("browse")
                return [
                    {
                        "title":    i.get("title", ""),
                        "item_key": i.get("item_key", ""),
                        "subtitle": i.get("subtitle", ""),
                    }
                    for i in items
                    if i.get("hint") in ("action", "action_list") and i.get("item_key")
                ]
        except Exception as exc:
            logger.warning("get_tag_tracks failed for key=%s: %s", tag_item_key, exc)
            return []


# ---------------------------------------------------------------------------
# Module-level helpers (pure functions, no self)
# ---------------------------------------------------------------------------


def _calc_played(prev: dict, now_playing: dict | None) -> int:
    """Calculate played seconds using seek_position diff when available.

    Falls back to wall-clock elapsed time when seek_position is unavailable.
    """
    start_seek = prev.get("start_seek")
    if start_seek is not None and now_playing is not None:
        current_seek = now_playing.get("seek_position")
        if current_seek and current_seek > 0:
            delta = current_seek - start_seek
            if delta > 0:
                return int(delta)
    # Wall-clock fallback
    return int(time.time() - prev["started_at"])


def _is_skipped(played: int, duration: int) -> int:
    """Return 1 if the listen counts as a skip, 0 otherwise.

    Uses proportional threshold (< 25% of track played) when duration is known.
    Falls back to absolute 30 s threshold for tracks with unknown duration.
    """
    if duration > 0:
        return 1 if (played / duration) < 0.25 else 0
    return 1 if played < 30 else 0
