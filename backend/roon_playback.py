"""Playback, transport, and zone management mixin for RoonSage."""

import logging
import re
import time
from typing import Any

from backend.models import RoonResponse, RoonZoneInfo
from backend.roon_utils import FUZZ_THRESHOLD, simplify_string

logger = logging.getLogger(__name__)


class RoonPlaybackMixin:
    """Mixin providing playback, transport, and zone management methods."""

    def get_zones(self) -> list[RoonZoneInfo]:
        """Return all zones from the Roon API."""
        if not self.is_connected():
            return []
        try:
            zones_raw = self._api.zones or {}
            result = []
            for zone_id, zone in zones_raw.items():
                raw_outputs = zone.get("outputs", [])
                outputs = [o.get("display_name", "") for o in raw_outputs]
                state = zone.get("state", "stopped")
                # Volume from first output (grouped zones share one fader)
                vol_info = (raw_outputs[0].get("volume") or {}) if raw_outputs else {}
                vol_value = vol_info.get("value")
                vol_pct = int(round(vol_value)) if vol_value is not None else None
                result.append(RoonZoneInfo(
                    zone_id=zone_id,
                    display_name=zone.get("display_name", zone_id),
                    state=state,
                    outputs=outputs,
                    is_grouped=len(outputs) > 1,
                    now_playing=zone.get("now_playing"),
                    volume=vol_pct,
                    is_muted=bool(vol_info.get("is_muted", False)),
                ))
            return result
        except Exception as e:
            logger.warning("Failed to get zones: %s", e)
            return []

    def _get_track_metadata_batch(
        self, keys: list[str]
    ) -> dict[str, dict[str, str]]:
        """Batch-fetch title+artist for a list of item_keys from SQLite."""
        if not keys:
            return {}
        try:
            from backend.library_cache import ensure_db_initialized  # noqa: PLC0415
            conn = ensure_db_initialized()
            try:
                placeholders = ",".join("?" * len(keys))
                rows = conn.execute(
                    f"SELECT item_key, title, artist FROM tracks"
                    f" WHERE item_key IN ({placeholders})",
                    keys,
                ).fetchall()
                return {row[0]: {"title": row[1], "artist": row[2]} for row in rows}
            finally:
                conn.close()
        except Exception as e:
            logger.warning("Track metadata batch lookup failed: %s", e)
            return {}

    def _find_best_track_match(
        self,
        items: list[dict[str, Any]],
        expected_title: str,
        expected_artist: str,
    ) -> dict[str, Any] | None:
        """Return the best-matching track item from Roon search results."""
        playable = [
            i for i in items
            if i.get("hint") in ("action", "action_list") and i.get("item_key")
        ]
        if not playable:
            return None

        title_norm = simplify_string(expected_title)
        artist_norm = simplify_string(expected_artist)

        best_item: dict[str, Any] | None = None
        best_score = -1.0

        for item in playable:
            item_title = simplify_string(item.get("title") or "")
            item_subtitle = simplify_string(item.get("subtitle") or "")

            try:
                from rapidfuzz import fuzz  # noqa: PLC0415
                title_score = fuzz.ratio(title_norm, item_title)
                artist_score = (
                    fuzz.partial_ratio(artist_norm, item_subtitle)
                    if artist_norm else 100.0
                )
            except ImportError:
                title_score = (
                    100.0 if title_norm == item_title
                    else (70.0 if title_norm in item_title else 0.0)
                )
                artist_score = 100.0 if artist_norm in item_subtitle else 50.0

            score = title_score * 0.7 + artist_score * 0.3
            if score > best_score:
                best_score = score
                best_item = item

        if best_item is not None and best_score >= FUZZ_THRESHOLD:
            return best_item

        logger.debug(
            "Track match below threshold (%.1f) for '%s' by '%s' — using first result",
            best_score, expected_title, expected_artist,
        )
        return playable[0]

    def _play_track_via_search(
        self,
        zone_id: str,
        search_query: str,
        expected_title: str,
        expected_artist: str,
        target_keywords: set[str],
        fallback_keywords: set[str],
    ) -> bool:
        """Search for a track and execute its play/queue action. Returns True on success."""
        try:
            with self._browse_lock:
                self._api.browse_browse({
                    "hierarchy": "search",
                    "input": search_query,
                    "pop_all": True,
                    "zone_or_output_id": zone_id,
                })
                root_result = self._api.browse_load({
                    "hierarchy": "search",
                    "count": 30,
                })
                root_items = root_result.get("items", []) if root_result else []

                tracks_section = next(
                    (
                        i for i in root_items
                        if i.get("hint") == "list"
                        and i.get("item_key")
                        and any(
                            kw in i.get("title", "").lower()
                            for kw in ("track", "song", "nummer", "titre", "titel")
                        )
                    ),
                    None,
                )
                if not tracks_section:
                    logger.warning(
                        "No Tracks section found in search results for '%s' "
                        "(sections: %s)",
                        search_query,
                        [i.get("title") for i in root_items],
                    )
                    return False

                self._api.browse_browse({
                    "hierarchy": "search",
                    "item_key": tracks_section["item_key"],
                })
                tracks_result = self._api.browse_load({
                    "hierarchy": "search",
                    "count": 20,
                })
                track_items = tracks_result.get("items", []) if tracks_result else []

                best_track = self._find_best_track_match(
                    track_items, expected_title, expected_artist
                )
                if not best_track:
                    logger.warning(
                        "No matching track item for '%s' by '%s' in search results",
                        expected_title, expected_artist,
                    )
                    return False

                self._api.browse_browse({
                    "hierarchy": "search",
                    "item_key": best_track["item_key"],
                    "zone_or_output_id": zone_id,
                })
                action_result = self._api.browse_load({
                    "hierarchy": "search",
                    "count": 10,
                    "zone_or_output_id": zone_id,
                })
                action_items = action_result.get("items", []) if action_result else []

                all_kw = target_keywords | fallback_keywords
                has_play_action = any(
                    (item.get("title") or "").lower().strip() in all_kw
                    and item.get("item_key")
                    for item in action_items
                )
                if not has_play_action and action_items:
                    version_item = next(
                        (i for i in action_items if i.get("item_key")),
                        None,
                    )
                    if version_item:
                        self._api.browse_browse({
                            "hierarchy": "search",
                            "item_key": version_item["item_key"],
                            "zone_or_output_id": zone_id,
                        })
                        version_result = self._api.browse_load({
                            "hierarchy": "search",
                            "count": 10,
                            "zone_or_output_id": zone_id,
                        })
                        action_items = (
                            version_result.get("items", [])
                            if version_result else []
                        )
                        logger.debug(
                            "Extra navigation into version '%s' for '%s' "
                            "→ %d action items",
                            version_item.get("title"),
                            search_query,
                            len(action_items),
                        )

                action_item: dict[str, Any] | None = None
                fallback_item: dict[str, Any] | None = None
                for item in action_items:
                    title_lower = (item.get("title") or "").lower().strip()
                    if title_lower in target_keywords and item.get("item_key"):
                        action_item = item
                        break
                    if (
                        title_lower in fallback_keywords
                        and item.get("item_key")
                        and fallback_item is None
                    ):
                        fallback_item = item

                chosen = action_item or fallback_item
                if not chosen or not chosen.get("item_key"):
                    logger.warning(
                        "No playable action in action menu for '%s' (items: %s)",
                        search_query,
                        [i.get("title") for i in action_items],
                    )
                    return False

                self._api.browse_browse({
                    "hierarchy": "search",
                    "item_key": chosen["item_key"],
                    "zone_or_output_id": zone_id,
                })
                logger.debug(
                    "Queued '%s' by '%s' via search (action: '%s')",
                    expected_title, expected_artist, chosen.get("title"),
                )
                return True

        except Exception as e:
            logger.warning(
                "Search-based play failed for '%s': %s", search_query, e
            )
            return False

    def _play_track_via_direct_key(
        self,
        zone_id: str,
        key: str,
        target_keywords: set[str],
        fallback_keywords: set[str],
    ) -> bool:
        """Fallback: try the old direct item_key browse approach. Returns True on success."""
        try:
            with self._browse_lock:
                self._api.browse_browse({
                    "hierarchy": "browse",
                    "item_key": key,
                    "pop_all": True,           # Reset browse hierarchy to avoid stale state
                    "zone_or_output_id": zone_id,
                })
                result = self._api.browse_load({
                    "hierarchy": "browse",
                    "count": 20,
                    "zone_or_output_id": zone_id,
                })

            items = result.get("items", []) if result else []

            action_item: dict[str, Any] | None = None
            fallback_item: dict[str, Any] | None = None
            for item in items:
                title_lower = (item.get("title") or "").lower().strip()
                if title_lower in target_keywords and item.get("item_key"):
                    action_item = item
                    break
                if (
                    title_lower in fallback_keywords
                    and item.get("item_key")
                    and fallback_item is None
                ):
                    fallback_item = item

            chosen = action_item or fallback_item
            if not chosen or not chosen.get("item_key"):
                # No play action found via browse hierarchy.
                #
                # Do NOT fall back to the search hierarchy here using the raw library
                # item_key.  Roon's search hierarchy does not understand library keys:
                # combining pop_all=True with a library key leaves the search hierarchy
                # parked on whatever result it last loaded — causing every subsequent
                # track in the loop to navigate deeper into that same stale result
                # (the "all tracks play as song #1" bug).
                #
                # The caller (play_tracks) already has two proper search fallbacks that
                # call _play_track_via_search with the actual title/artist from SQLite
                # and a fresh pop_all reset each time.  Return False here so those kick in.
                logger.info(
                    "Direct-key play: browse hierarchy found no play action for key %s "
                    "(items: %s) — will retry via title/artist search",
                    key,
                    [i.get("title") for i in items],
                )
                return False

            with self._browse_lock:
                self._api.browse_browse({
                    "hierarchy": "browse",
                    "item_key": chosen["item_key"],
                    "zone_or_output_id": zone_id,
                })
            return True

        except Exception as e:
            logger.warning("Direct-key play failed for key %s: %s", key, e)
            return False

    def play_tracks(
        self, zone_id: str, item_keys: list[str], mode: str = "replace"
    ) -> RoonResponse:
        """Queue and play tracks on a Roon zone via the Browse API."""
        if not self.is_connected():
            return RoonResponse(success=False, error="Not connected to Roon")

        if not item_keys:
            return RoonResponse(success=False, error="No tracks provided")

        PLAY_NOW_KEYWORDS: set[str] = {"play now", "play"}
        QUEUE_KEYWORDS: set[str] = {"queue", "add to queue"}

        track_meta = self._get_track_metadata_batch(item_keys)

        tracks_queued = 0
        tracks_skipped = 0
        play_now_succeeded = False  # True once any track clears the queue via "Play Now"

        try:
            for idx, key in enumerate(item_keys):
                # Check connection before each track; wait for reconnect if needed
                if not self.is_connected():
                    logger.warning(
                        "Roon disconnected at track %d/%d, waiting for reconnect...",
                        idx + 1, len(item_keys),
                    )
                    reconnected = False
                    for wait in range(6):  # Wait up to 30 seconds (6 × 5s)
                        time.sleep(5)
                        if self.is_connected():
                            logger.info(
                                "Roon reconnected after %ds, resuming playback",
                                (wait + 1) * 5,
                            )
                            reconnected = True
                            break
                    if not reconnected:
                        logger.error(
                            "Roon did not reconnect after 30s, skipping remaining %d tracks",
                            len(item_keys) - idx,
                        )
                        break

                if mode == "replace" and not play_now_succeeded:
                    # Keep trying "Play Now" until one track succeeds — only that
                    # action clears the existing Roon queue.  If the first track
                    # fails and we fall back to "Queue", the old queue leaks through.
                    target_kw = PLAY_NOW_KEYWORDS
                    fallback_kw = QUEUE_KEYWORDS
                else:
                    target_kw = QUEUE_KEYWORDS
                    fallback_kw = set()  # NEVER fall back to Play Now once queue is cleared

                # --- Synthetic Qobuz key (global-search fallback) ---
                # Keys of the form "qobuz_search::<artist>::<title>" are generated by
                # search_qobuz_tracks_sync when the global Roon search fallback fires.
                # The real item_keys from hierarchy:"search" are ephemeral — they resolve
                # to random content once the search session changes.  We detect this
                # prefix here and perform a FRESH search at play time instead.
                if key.startswith("qobuz_search::"):
                    import urllib.parse  # noqa: PLC0415
                    parts = key.split("::", 2)
                    synth_artist = urllib.parse.unquote(parts[1]) if len(parts) > 1 else ""
                    synth_title = urllib.parse.unquote(parts[2]) if len(parts) > 2 else ""
                    search_q = (
                        f"{synth_artist} {synth_title}".strip()
                        if synth_artist else synth_title
                    )
                    logger.info(
                        "Track %d/%d: synthetic Qobuz key — fresh search for '%s'",
                        idx + 1, len(item_keys), search_q,
                    )
                    queued = self._play_track_via_search(
                        zone_id, search_q, synth_title, synth_artist,
                        target_kw, fallback_kw,
                    )
                    if queued:
                        tracks_queued += 1
                        if mode == "replace" and not play_now_succeeded:
                            play_now_succeeded = True
                        logger.info(
                            "Track %d/%d QUEUED (synthetic): '%s' by '%s'",
                            idx + 1, len(item_keys), synth_title, synth_artist,
                        )
                    else:
                        tracks_skipped += 1
                        logger.info(
                            "Track %d/%d SKIPPED (synthetic): '%s' by '%s'",
                            idx + 1, len(item_keys), synth_title, synth_artist,
                        )
                    continue
                # --- End synthetic key handling ---

                try:
                    meta = track_meta.get(key)

                    if meta:
                        title = meta["title"]
                        artist = meta["artist"]

                        # Primary: direct key browse — most reliable, no Roon search
                        # ambiguity.  Works for all tracks, including classical where
                        # search often returns the wrong result.
                        queued = self._play_track_via_direct_key(
                            zone_id, key, target_kw, fallback_kw
                        )

                        # Fallback 1: search by primary artist + shortened title.
                        if not queued:
                            primary_artist = artist.split(",")[0].strip() if artist else ""
                            # Shorten title: remove everything after ": " (movement markers)
                            # e.g. "Piano Concerto No. 21 in C major, K. 467: II. Andante"
                            #       → "Piano Concerto No. 21"
                            short_title = title.split(":")[0].strip() if title else ""
                            # Also remove key signatures like "in C major" or "in A Minor"
                            short_title = re.sub(
                                r'\s+in\s+[A-G][#b]?\s+(major|minor|Major|Minor).*',
                                '',
                                short_title,
                            )
                            # Strip version/remaster/format suffixes that Roon doesn't index
                            short_title = re.sub(r'\s*[\(\[].*?[\)\]]\s*$', '', short_title).strip()
                            search_query = f"{primary_artist} {short_title}" if primary_artist else short_title

                            logger.info("Direct key failed for '%s', trying search", title)
                            queued = self._play_track_via_search(
                                zone_id, search_query, title, artist,
                                target_kw, fallback_kw,
                            )

                        # Fallback 2: search with cleaned title only
                        if not queued:
                            clean_search_title = re.sub(r'\s*[\(\[].*?[\)\]]\s*$', '', title).strip()
                            logger.info("Retry with title-only search for '%s'", clean_search_title)
                            queued = self._play_track_via_search(
                                zone_id, clean_search_title, title, artist,
                                target_kw, fallback_kw,
                            )
                    else:
                        logger.debug(
                            "Track key %s not in SQLite cache, trying direct browse", key
                        )
                        queued = self._play_track_via_direct_key(
                            zone_id, key, target_kw, fallback_kw
                        )

                        # Fallback for streaming tracks (e.g. Qobuz): extract
                        # title/artist from the search hierarchy and retry via
                        # the search-based path.
                        if not queued:
                            try:
                                with self._browse_lock:
                                    self._api.browse_browse({
                                        "hierarchy": "search",
                                        "item_key": key,
                                        "pop_all": True,
                                    })
                                    meta_result = self._api.browse_load({
                                        "hierarchy": "search",
                                        "count": 5,
                                    })
                                meta_items = meta_result.get("items", []) if meta_result else []
                                if meta_items:
                                    extracted_title = meta_items[0].get("title", "")
                                    extracted_subtitle = meta_items[0].get("subtitle", "") or ""
                                    if extracted_title:
                                        extracted_artist = (
                                            extracted_subtitle.split("•")[0].strip()
                                            if extracted_subtitle else ""
                                        )
                                        search_q = (
                                            f"{extracted_artist} {extracted_title}"
                                            if extracted_artist else extracted_title
                                        )
                                        logger.info(
                                            "Streaming track not in cache, trying search "
                                            "for '%s'",
                                            search_q,
                                        )
                                        queued = self._play_track_via_search(
                                            zone_id, search_q, extracted_title,
                                            extracted_artist,
                                            target_kw, fallback_kw,
                                        )
                            except Exception as e:
                                logger.debug(
                                    "Metadata extraction for key %s failed: %s", key, e
                                )

                    if queued:
                        tracks_queued += 1
                        if mode == "replace" and not play_now_succeeded:
                            play_now_succeeded = True
                        logger.info("Track %d/%d QUEUED: '%s' by '%s'", idx + 1, len(item_keys), meta.get("title", key) if meta else key, meta.get("artist", "?") if meta else "?")
                    else:
                        tracks_skipped += 1
                        logger.info("Track %d/%d SKIPPED: '%s' by '%s'", idx + 1, len(item_keys), meta.get("title", key) if meta else key, meta.get("artist", "?") if meta else "?")

                except Exception as e:
                    logger.warning("Failed to queue track %s: %s", key, e)
                    tracks_skipped += 1

            zone_name = self._get_zone_name(zone_id)
            logger.info("PLAY_TRACKS DONE: zone='%s' queued=%d skipped=%d of %d total", zone_name, tracks_queued, tracks_skipped, len(item_keys))
            return RoonResponse(
                success=tracks_queued > 0,
                zone_name=zone_name,
                tracks_queued=tracks_queued,
                tracks_skipped=tracks_skipped,
            )
        except Exception as e:
            logger.exception("Failed to play tracks on zone %s", zone_id)
            return RoonResponse(success=False, error=str(e))

    def transport_control(
        self,
        zone_id: str,
        action: str,
        value: str | None = None,
        position_seconds: int | None = None,
        seek_offset: int | None = None,
    ) -> RoonResponse:
        """Send a transport command to a Roon zone."""
        playback_actions = {"play", "pause", "stop", "next", "previous"}

        if not self.is_connected():
            return RoonResponse(success=False, error="Not connected to Roon")

        zone_name = self._get_zone_name(zone_id)

        try:
            if action in playback_actions:
                self._api.playback_control(zone_id, action)
                return RoonResponse(success=True, zone_name=zone_name, action=action)

            elif action == "shuffle":
                zones_raw = self._api.zones or {}
                zone = zones_raw.get(zone_id, {})
                current = zone.get("settings", {}).get("shuffle", False)
                if value in ("true", "1", "on", "yes"):
                    new_state = True
                elif value in ("false", "0", "off", "no"):
                    new_state = False
                else:
                    new_state = not current
                self._api.shuffle(zone_id, new_state)
                return RoonResponse(
                    success=True,
                    zone_name=zone_name,
                    action=action,
                    state="on" if new_state else "off",
                )

            elif action == "repeat":
                REPEAT_MODES = ["disabled", "loop", "loop_one"]
                if value == "cycle":
                    zones_raw = self._api.zones or {}
                    zone = zones_raw.get(zone_id, {})
                    current = zone.get("settings", {}).get("loop", "disabled")
                    idx = REPEAT_MODES.index(current) if current in REPEAT_MODES else 0
                    new_mode = REPEAT_MODES[(idx + 1) % len(REPEAT_MODES)]
                elif value in REPEAT_MODES:
                    new_mode = value
                else:
                    new_mode = "loop"
                self._api.repeat(zone_id, new_mode)
                return RoonResponse(
                    success=True,
                    zone_name=zone_name,
                    action=action,
                    state=new_mode,
                )

            elif action == "seek":
                if seek_offset is not None:
                    self._api.seek(zone_id, seek_offset, "relative")
                    return RoonResponse(
                        success=True,
                        zone_name=zone_name,
                        action=action,
                        state=f"relative:{seek_offset:+d}s",
                    )
                elif position_seconds is not None:
                    self._api.seek(zone_id, position_seconds, "absolute")
                    return RoonResponse(
                        success=True,
                        zone_name=zone_name,
                        action=action,
                        state=f"absolute:{position_seconds}s",
                    )
                else:
                    return RoonResponse(success=False, error="seek requires position_seconds or seek_offset")

            else:
                valid = sorted(playback_actions | {"shuffle", "repeat", "seek"})
                return RoonResponse(
                    success=False,
                    error=f"Invalid action '{action}'. Must be one of: {', '.join(valid)}",
                )

        except Exception as e:
            logger.warning("transport_control failed zone=%s action=%s: %s", zone_id, action, e)
            return RoonResponse(success=False, error=str(e))

    def _resolve_output_for_zone(self, zone_name_or_id: str) -> tuple[str | None, str | None, dict | None]:
        """Resolve a zone name or ID to (zone_id, output_id, output_data)."""
        zones_raw = self._api.zones if self._api else {}
        zone = zones_raw.get(zone_name_or_id)
        if not zone:
            name_lower = zone_name_or_id.lower()
            for zid, z in zones_raw.items():
                if z.get("display_name", "").lower() == name_lower:
                    zone = z
                    zone_name_or_id = zid
                    break
        if not zone:
            return None, None, None
        outputs = zone.get("outputs", [])
        if not outputs:
            return zone_name_or_id, None, None
        output = outputs[0]
        return zone_name_or_id, output.get("output_id"), output

    def _resolve_zone_id(self, zone_name_or_id: str) -> str | None:
        """Resolve a zone name or zone_id string to a zone_id."""
        zones_raw = self._api.zones if self._api else {}
        if zone_name_or_id in zones_raw:
            return zone_name_or_id
        name_lower = zone_name_or_id.lower()
        for zid, z in zones_raw.items():
            if z.get("display_name", "").lower() == name_lower:
                return zid
        return None

    def volume_control(
        self,
        zone_name: str,
        action: str,
        value: int | None = None,
    ) -> RoonResponse:
        """Control volume for a zone by name."""
        if not self.is_connected():
            return RoonResponse(success=False, error="Not connected to Roon")

        zone_id, output_id, output_data = self._resolve_output_for_zone(zone_name)
        if not zone_id or not output_id:
            return RoonResponse(success=False, error=f"Zone '{zone_name}' not found or has no outputs")

        display = self._get_zone_name(zone_id)
        vol_info = (output_data or {}).get("volume", {})

        try:
            if action == "get":
                return RoonResponse(
                    success=True,
                    zone_name=display,
                    action="get",
                    volume=vol_info.get("value"),
                    is_muted=vol_info.get("is_muted", False),
                )

            elif action == "set":
                if value is None:
                    return RoonResponse(success=False, error="value required for 'set'")
                self._api.set_volume_percent(output_id, max(0, min(100, value)))

            elif action == "adjust":
                if value is None:
                    return RoonResponse(success=False, error="value required for 'adjust'")
                self._api.change_volume_percent(output_id, value)

            elif action == "mute":
                self._api.mute(output_id, True)

            elif action == "unmute":
                self._api.mute(output_id, False)

            elif action == "toggle_mute":
                currently_muted = vol_info.get("is_muted", False)
                self._api.mute(output_id, not currently_muted)

            else:
                return RoonResponse(
                    success=False,
                    error=f"Invalid action '{action}'. Use: set, adjust, get, mute, unmute, toggle_mute",
                )

            time.sleep(0.2)
            zones_raw = self._api.zones or {}
            zone_fresh = zones_raw.get(zone_id, {})
            for out in zone_fresh.get("outputs", []):
                if out.get("output_id") == output_id:
                    vol_info = out.get("volume", {})
                    break

            return RoonResponse(
                success=True,
                zone_name=display,
                action=action,
                volume=vol_info.get("value"),
                is_muted=vol_info.get("is_muted", False),
            )

        except Exception as e:
            logger.warning("volume_control failed zone=%s action=%s: %s", zone_name, action, e)
            return RoonResponse(success=False, error=str(e))

    def transfer_zone(
        self, from_zone: str, to_zone: str
    ) -> RoonResponse:
        """Transfer playback from one zone to another."""
        if not self.is_connected():
            return RoonResponse(success=False, error="Not connected to Roon")

        from_id = self._resolve_zone_id(from_zone)
        to_id = self._resolve_zone_id(to_zone)
        if not from_id:
            return RoonResponse(success=False, error=f"Source zone '{from_zone}' not found")
        if not to_id:
            return RoonResponse(success=False, error=f"Target zone '{to_zone}' not found")

        try:
            self._api.transfer_zone(from_id, to_id)
            return RoonResponse(
                success=True,
                from_zone=self._get_zone_name(from_id),
                to_zone=self._get_zone_name(to_id),
            )
        except Exception as e:
            logger.warning("transfer_zone failed %s -> %s: %s", from_zone, to_zone, e)
            return RoonResponse(success=False, error=str(e))

    def zone_grouping(
        self, action: str, zone_names: list[str]
    ) -> RoonResponse:
        """Group, ungroup, or list zone groups."""
        if not self.is_connected():
            return RoonResponse(success=False, error="Not connected to Roon")

        zones_raw = self._api.zones or {}

        if action == "list_groups":
            groups = []
            for zid, z in zones_raw.items():
                outputs = z.get("outputs", [])
                if len(outputs) > 1:
                    groups.append({
                        "group_name": z.get("display_name", zid),
                        "zone_id": zid,
                        "zones": [o.get("display_name", o.get("output_id", "")) for o in outputs],
                    })
            return RoonResponse(success=True, action="list_groups", groups=groups)

        output_ids = []
        for name in zone_names:
            _, output_id, _ = self._resolve_output_for_zone(name)
            if output_id:
                output_ids.append(output_id)
            else:
                return RoonResponse(success=False, error=f"Zone '{name}' not found")

        if len(output_ids) < 2 and action == "group":
            return RoonResponse(success=False, error="At least 2 zones required for grouping")

        try:
            if action == "group":
                first_output_data = None
                for _zid, z in zones_raw.items():
                    for out in z.get("outputs", []):
                        if out.get("output_id") == output_ids[0]:
                            first_output_data = out
                            break
                if first_output_data:
                    compatible = first_output_data.get("can_group_with_output_ids", [])
                    for oid in output_ids[1:]:
                        if oid not in compatible:
                            return RoonResponse(
                                success=False,
                                error=f"Output {oid} is not compatible for grouping with {output_ids[0]}",
                            )
                self._api.group_outputs(output_ids)
                return RoonResponse(
                    success=True,
                    action="group",
                    groups=[{"zones": zone_names}],
                )

            elif action == "ungroup":
                self._api.ungroup_outputs(output_ids)
                return RoonResponse(
                    success=True,
                    action="ungroup",
                    groups=[],
                )

            else:
                return RoonResponse(success=False, error=f"Invalid action '{action}'. Use: group, ungroup, list_groups")

        except Exception as e:
            logger.warning("zone_grouping failed action=%s: %s", action, e)
            return RoonResponse(success=False, error=str(e))

    def play_radio(self, station_name: str, zone_id: str) -> RoonResponse:
        """Browse 'My Live Radio' and play a station by fuzzy-matched name."""
        if not self.is_connected():
            return RoonResponse(success=False, error="Not connected to Roon")

        zone_name = self._get_zone_name(zone_id)

        try:
            with self._browse_lock:
                self._api.browse_browse({"hierarchy": "browse", "pop_all": True, "zone_or_output_id": zone_id})
                root_page = self._api.browse_load({"hierarchy": "browse", "count": 100, "zone_or_output_id": zone_id})
                root_items = root_page.get("items", []) if root_page else []

                radio_item = next(
                    (i for i in root_items if "radio" in i.get("title", "").lower()),
                    None,
                )
                if not radio_item:
                    return RoonResponse(success=False, error="My Live Radio not found in Roon browse. Check that you have internet radio configured in Roon.")

                self._api.browse_browse({
                    "hierarchy": "browse",
                    "item_key": radio_item["item_key"],
                    "zone_or_output_id": zone_id,
                })
                stations_page = self._api.browse_load({
                    "hierarchy": "browse",
                    "count": 200,
                    "zone_or_output_id": zone_id,
                })
                stations = stations_page.get("items", []) if stations_page else []

                station_lower = station_name.lower()
                best_match = None
                best_score = 0
                for s in stations:
                    title = s.get("title", "")
                    title_lower = title.lower()
                    if title_lower == station_lower:
                        best_match = s
                        break
                    if station_lower in title_lower:
                        score = len(station_lower) / len(title_lower)
                        if score > best_score:
                            best_score = score
                            best_match = s
                    elif title_lower in station_lower:
                        score = len(title_lower) / len(station_lower)
                        if score > best_score:
                            best_score = score
                            best_match = s

                if not best_match:
                    station_list = [s.get("title", "") for s in stations[:20]]
                    return RoonResponse(
                        success=False,
                        error=f"Station '{station_name}' not found. Available stations (first 20): {station_list}",
                    )

                self._api.browse_browse({
                    "hierarchy": "browse",
                    "item_key": best_match["item_key"],
                    "zone_or_output_id": zone_id,
                })
                station_items = self._api.browse_load({
                    "hierarchy": "browse",
                    "count": 10,
                    "zone_or_output_id": zone_id,
                })
                play_items = (station_items or {}).get("items", [])

                play_action = next(
                    (i for i in play_items if i.get("hint") == "action" and i.get("item_key")),
                    None,
                )
                if not play_action:
                    return RoonResponse(success=True, station_name=best_match.get("title", station_name), zone_name=zone_name)

                self._api.browse_browse({
                    "hierarchy": "browse",
                    "item_key": play_action["item_key"],
                    "zone_or_output_id": zone_id,
                })

            return RoonResponse(
                success=True,
                station_name=best_match.get("title", station_name),
                zone_name=zone_name,
            )

        except Exception as e:
            logger.warning("play_radio failed station=%s zone=%s: %s", station_name, zone_id, e)
            return RoonResponse(success=False, error=str(e))

    def browse_playlists(
        self,
        action: str,
        playlist_name: str = "",
        zone_id: str = "",
    ) -> RoonResponse:
        """Browse and optionally play Roon playlists."""
        if not self.is_connected():
            return RoonResponse(success=False, error="Not connected to Roon")

        zone_name = self._get_zone_name(zone_id) if zone_id else None

        try:
            with self._browse_lock:
                self._api.browse_browse({"hierarchy": "playlists", "pop_all": True})
                root_page = self._api.browse_load({"hierarchy": "playlists", "count": 500})
                items = root_page.get("items", []) if root_page else []

            if action == "list":
                playlists = [
                    {
                        "name": i.get("title", ""),
                        "subtitle": i.get("subtitle", ""),
                        "item_key": i.get("item_key", ""),
                    }
                    for i in items
                    if i.get("title")
                ]
                return RoonResponse(
                    success=True,
                    action="list",
                    playlists=playlists,
                )

            elif action == "play":
                if not playlist_name:
                    return RoonResponse(success=False, error="playlist_name required for 'play'")
                if not zone_id:
                    return RoonResponse(success=False, error="zone_id required for 'play'")

                name_lower = playlist_name.lower()
                best_match = None
                for i in items:
                    if i.get("title", "").lower() == name_lower:
                        best_match = i
                        break
                    if name_lower in i.get("title", "").lower() and best_match is None:
                        best_match = i

                if not best_match:
                    names = [i.get("title", "") for i in items[:20]]
                    return RoonResponse(success=False, error=f"Playlist '{playlist_name}' not found. Available: {names}")

                try:
                    with self._browse_lock:
                        self._api.browse_browse({
                            "hierarchy": "playlists",
                            "item_key": best_match["item_key"],
                            "zone_or_output_id": zone_id,
                        })
                        pl_items = self._api.browse_load({
                            "hierarchy": "playlists",
                            "count": 10,
                            "zone_or_output_id": zone_id,
                        })
                        pl_actions = (pl_items or {}).get("items", [])

                        play_action = next(
                            (a for a in pl_actions if "play" in a.get("title", "").lower() and a.get("item_key")),
                            None,
                        ) or next(
                            (a for a in pl_actions if a.get("hint") == "action" and a.get("item_key")),
                            None,
                        )

                        if play_action:
                            self._api.browse_browse({
                                "hierarchy": "playlists",
                                "item_key": play_action["item_key"],
                                "zone_or_output_id": zone_id,
                            })

                    return RoonResponse(
                        success=True,
                        action="play",
                        playlists=[{"name": best_match.get("title", playlist_name)}],
                        zone_name=zone_name,
                    )
                except Exception as e:
                    return RoonResponse(success=False, error=f"Could not play playlist: {e}")

            else:
                return RoonResponse(success=False, error=f"Invalid action '{action}'. Use: list, play")

        except Exception as e:
            logger.warning("browse_playlists failed action=%s: %s", action, e)
            return RoonResponse(success=False, error=str(e))

    def _get_zone_name(self, zone_id: str) -> str | None:
        """Return display name for a zone."""
        try:
            zones = self._api.zones or {}
            zone = zones.get(zone_id, {})
            return zone.get("display_name") or zone_id
        except Exception:
            return zone_id
