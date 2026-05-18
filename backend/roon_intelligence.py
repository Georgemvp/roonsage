"""Listening history monitor and Roon Tags browser for RoonSage intelligence layer.

This mixin is intentionally kept separate from roon_browse.py because:
- It uses a background thread polling get_zones(), NOT the Browse API.
- Mixing browse-lock usage with the monitor thread would cause deadlocks.
"""

import logging
import threading
import time
from typing import Any

logger = logging.getLogger(__name__)

# Minimum seconds a track must play before being logged (avoids noise from
# brief previews or accidental presses).
_MIN_PLAY_SECONDS = 5


class RoonIntelligenceMixin:
    """Mixin providing listening history monitoring and Roon Tags access."""

    # -------------------------------------------------------------------------
    # Listening history monitor
    # -------------------------------------------------------------------------

    def start_listening_monitor(self) -> None:
        """Start the background thread that logs track changes to listening_history.

        Safe to call multiple times — only one thread will run at a time.
        Requires Roon to be connected; call this only after is_connected() is True.
        """
        existing: threading.Thread | None = getattr(
            self, "_listening_monitor_thread", None
        )
        if existing is not None and existing.is_alive():
            logger.debug("Listening monitor already running")
            return

        self._last_zone_states: dict[str, dict] = getattr(
            self, "_last_zone_states", {}
        )
        t = threading.Thread(
            target=self._monitor_zones,
            daemon=True,
            name="roonsage-listening-monitor",
        )
        self._listening_monitor_thread = t
        t.start()
        logger.info("Listening monitor started")

    def _monitor_zones(self) -> None:
        """Background loop: poll zones every 10 s and log track changes."""
        while True:
            try:
                if self.is_connected():
                    zones_raw = getattr(self, "_api", None)
                    if zones_raw is not None:
                        zones_dict: dict = zones_raw.zones or {}
                        for zone_id, zone in zones_dict.items():
                            self._process_zone_change(zone_id, zone)
            except Exception as exc:
                logger.warning("Listening monitor error: %s", exc)

            time.sleep(10)

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
                played = int(time.time() - prev["started_at"])
                if played >= _MIN_PLAY_SECONDS:
                    skipped = 1 if played < 30 else 0
                    self._log_listen(prev, played, skipped, zone.get("display_name", zone_id))
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
            played = int(time.time() - prev["started_at"])
            if played >= _MIN_PLAY_SECONDS:
                skipped = 1 if played < 30 else 0
                self._log_listen(prev, played, skipped, zone.get("display_name", zone_id))

        if not prev or prev.get("track_key") != track_key:
            # New track started — record start state
            three = now_playing.get("three_line", {})
            self._last_zone_states[zone_id] = {
                "track_key": track_key,
                "title":     three.get("line1") or now_playing.get("one_line", {}).get("line1", ""),
                "artist":    three.get("line2", ""),
                "album":     three.get("line3", ""),
                "genre":     "",  # Roon doesn't expose genre in now_playing
                "duration":  now_playing.get("length", 0),
                "started_at": time.time(),
            }

    def _log_listen(
        self,
        track_info: dict,
        played_seconds: int,
        skipped: int,
        zone_name: str,
    ) -> None:
        """Insert a completed listen into listening_history."""
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                conn.execute(
                    """
                    INSERT INTO listening_history
                        (zone_name, track_title, artist, album, genre,
                         duration_seconds, played_seconds, skipped)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        zone_name,
                        track_info.get("title", ""),
                        track_info.get("artist", ""),
                        track_info.get("album", ""),
                        track_info.get("genre", ""),
                        track_info.get("duration", 0),
                        played_seconds,
                        skipped,
                    ),
                )
                conn.commit()
                logger.debug(
                    "Logged listen: '%s' by %s (%ds, skipped=%d)",
                    track_info.get("title"),
                    track_info.get("artist"),
                    played_seconds,
                    skipped,
                )
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
