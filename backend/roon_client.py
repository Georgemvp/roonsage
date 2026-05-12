"""Roon Core client for library queries and zone/transport management."""

import hashlib
import logging
import re
import threading
import time
from typing import Any

from unidecode import unidecode

from backend.models import RoonZoneInfo, Track

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Helpers — server-agnostic utility functions
# ---------------------------------------------------------------------------

FUZZ_THRESHOLD = 60
DATE_PATTERN = r"\d{4}[-/]\d{2}[-/]\d{2}"
LIVE_KEYWORDS = r"\b(?:live|concert|sbd|bootleg)\b"


def simplify_string(s: str) -> str:
    """Normalize string for fuzzy comparison."""
    s = s.lower()
    s = re.sub(r"[^\w\s]", "", s)
    s = unidecode(s)
    return s


def normalize_artist(name: str) -> list[str]:
    """Return variations of artist name for matching."""
    variations = [name]
    if " and " in name.lower():
        variations.append(name.replace(" and ", " & ").replace(" And ", " & "))
    elif " & " in name:
        variations.append(name.replace(" & ", " and "))
    return variations


def is_live_version(track: Any) -> bool:
    """Check if track appears to be a live recording."""
    album_title = ""
    if isinstance(track, dict):
        album_title = track.get("subtitle", "") or ""
        track_title = track.get("title", "") or ""
    else:
        album_title = getattr(track, "album", "") or ""
        track_title = getattr(track, "title", "") or ""

    for text in [album_title, track_title]:
        if re.search(DATE_PATTERN, text):
            return True
        if re.search(LIVE_KEYWORDS, text, re.IGNORECASE):
            return True
    return False


# ---------------------------------------------------------------------------
# Track Cache
# ---------------------------------------------------------------------------


class TrackCache:
    """In-memory cache for filtered track results with TTL."""

    def __init__(self, ttl_seconds: int = 300, max_entries: int = 50):
        self._cache: dict[str, tuple[list[Track], float]] = {}
        self._ttl = ttl_seconds
        self._max_entries = max_entries

    def _make_key(
        self,
        genres: list[str] | None,
        decades: list[str] | None,
        exclude_live: bool,
        min_rating: int,
    ) -> str:
        key_data = {
            "genres": sorted(genres or []),
            "decades": sorted(decades or []),
            "exclude_live": exclude_live,
            "min_rating": min_rating,
        }
        return hashlib.md5(str(key_data).encode()).hexdigest()

    def _evict_oldest(self) -> None:
        if not self._cache:
            return
        oldest_key = min(self._cache.keys(), key=lambda k: self._cache[k][1])
        del self._cache[oldest_key]

    def get(
        self,
        genres: list[str] | None,
        decades: list[str] | None,
        exclude_live: bool,
        min_rating: int,
    ) -> list[Track] | None:
        key = self._make_key(genres, decades, exclude_live, min_rating)
        if key in self._cache:
            tracks, timestamp = self._cache[key]
            if time.time() - timestamp < self._ttl:
                logger.info("Cache hit for filters (key=%s)", key[:8])
                return tracks
            del self._cache[key]
        return None

    def set(
        self,
        genres: list[str] | None,
        decades: list[str] | None,
        exclude_live: bool,
        min_rating: int,
        tracks: list[Track],
    ) -> None:
        key = self._make_key(genres, decades, exclude_live, min_rating)
        if key not in self._cache and len(self._cache) >= self._max_entries:
            self._evict_oldest()
        self._cache[key] = (tracks, time.time())
        logger.info("Cached %d tracks (key=%s)", len(tracks), key[:8])

    def clear(self) -> None:
        self._cache.clear()
        logger.info("Track cache cleared")


_track_cache = TrackCache()


def get_track_cache() -> TrackCache:
    return _track_cache


# ---------------------------------------------------------------------------
# RoonClient
# ---------------------------------------------------------------------------


class RoonQueryError(Exception):
    """Raised when a Roon library query fails."""


class RoonClient:
    """Client for interacting with a Roon Core via roonapi."""

    RECONNECT_COOLDOWN = 30
    # Roon extension registration info
    EXTENSION_INFO = {
        "extension_id": "com.mediasage.roon",
        "display_name": "MediaSage",
        "display_version": "1.0.0",
        "publisher": "MediaSage",
        "email": "mediasage@example.com",
        "website": "https://github.com/ecwilsonaz/mediasage",
    }

    def __init__(
        self,
        host: str,
        port: int = 9100,
        core_id: str = "",
        token: str = "",
        extension_info: dict[str, str] | None = None,
    ):
        self.host = host
        self.port = port
        self.core_id = core_id
        self.token = token or None
        self._api: Any = None
        self._error: str | None = None
        self._last_reconnect_attempt: float = 0.0
        self._reconnect_lock = threading.Lock()
        self._needs_authorization = False

        if extension_info:
            self.EXTENSION_INFO = extension_info

        self._connect()

    def _connect(self) -> None:
        """Attempt to connect to Roon Core."""
        if not self.host:
            self._error = "Roon host is required"
            return

        try:
            from roonapi import RoonApi  # type: ignore

            appinfo = self.EXTENSION_INFO

            self._api = RoonApi(
                appinfo,
                self.token,
                host=self.host,
                port=self.port,
                blocking_init=True,
            )

            if not self._api.token:
                # Not yet authorized in Roon's extension manager
                self._needs_authorization = True
                self._error = (
                    "MediaSage needs to be authorized in Roon. "
                    "Open Roon → Settings → Extensions and enable MediaSage."
                )
                return

            self._needs_authorization = False
            self._error = None
            logger.info(
                "Connected to Roon Core '%s'", self._api.core_name
            )
        except ImportError:
            self._error = "roonapi package is not installed. Run: pip install roonapi"
            self._api = None
        except Exception as e:
            self._error = f"Roon connection error: {e}"
            self._api = None

    def is_connected(self) -> bool:
        """Return True if connected and authorized."""
        if self._api is not None and not self._needs_authorization:
            return True

        now = time.time()
        with self._reconnect_lock:
            if self._api is not None and not self._needs_authorization:
                return True
            if now - self._last_reconnect_attempt >= self.RECONNECT_COOLDOWN:
                self._last_reconnect_attempt = now
                logger.info("Attempting to reconnect to Roon Core…")
                self._connect()

        return self._api is not None and not self._needs_authorization

    def needs_authorization(self) -> bool:
        """Return True if the extension needs to be authorized in Roon."""
        return self._needs_authorization

    def get_core_id(self) -> str | None:
        """Return the connected Roon Core's ID (equivalent of Plex machineIdentifier)."""
        if not self._api:
            return None
        return getattr(self._api, "core_id", None) or self.core_id or None

    def get_core_name(self) -> str | None:
        """Return the human-readable Roon Core name."""
        if not self._api:
            return None
        return getattr(self._api, "core_name", None)

    def get_error(self) -> str | None:
        return self._error

    # ------------------------------------------------------------------
    # Library helpers — Browse API
    # ------------------------------------------------------------------

    def get_library_total_tracks(self) -> int:
        """Return total track count via Browse API."""
        if not self.is_connected():
            return 0
        try:
            opts = {"hierarchy": "browse", "pop_all": True}
            result = self._api.browse_browse(opts)
            # Navigate: Library → Albums → each album → tracks
            # For a quick total, use the search/items API at track level if available
            # Fall back to counting all tracks
            tracks = self.get_all_raw_tracks()
            return len(tracks)
        except Exception as e:
            logger.warning("Failed to get total tracks: %s", e)
            return 0

    def get_all_raw_tracks(self) -> list[dict[str, Any]]:
        """Get all tracks by browsing Library → Albums → tracks per album.

        Returns a flat list of dicts representing Roon browse items with
        keys: title, subtitle, item_key, image_key, hint.
        """
        if not self.is_connected():
            return []

        all_tracks: list[dict[str, Any]] = []
        try:
            # Load the library root
            opts: dict[str, Any] = {
                "hierarchy": "browse",
                "pop_all": True,
            }
            self._api.browse_browse(opts)
            items = self._api.browse_load({"hierarchy": "browse", "count": 1000}).get("items", [])

            # Find "Library" item
            library_item = next((i for i in items if "library" in i.get("title", "").lower()), None)
            if not library_item:
                # Try navigating directly
                self._api.browse_browse({"hierarchy": "albums"})
                album_items = self._api.browse_load({"hierarchy": "albums", "count": 5000}).get("items", [])
            else:
                # Navigate into Library → Albums
                self._api.browse_browse({"hierarchy": "browse", "item_key": library_item["item_key"]})
                sub_items = self._api.browse_load({"hierarchy": "browse", "count": 200}).get("items", [])
                albums_item = next((i for i in sub_items if "album" in i.get("title", "").lower()), None)
                if albums_item:
                    self._api.browse_browse({"hierarchy": "browse", "item_key": albums_item["item_key"]})
                    album_items = self._api.browse_load({"hierarchy": "browse", "count": 5000}).get("items", [])
                else:
                    album_items = []

            logger.info("Found %d albums in Roon library", len(album_items))

            for album in album_items:
                album_key = album.get("item_key")
                if not album_key:
                    continue
                try:
                    self._api.browse_browse({"hierarchy": "browse", "item_key": album_key})
                    track_page = self._api.browse_load({"hierarchy": "browse", "count": 500})
                    for t in track_page.get("items", []):
                        if t.get("hint") == "action" or t.get("hint") == "list":
                            # It's a track (action = playable)
                            t["_album_title"] = album.get("title", "")
                            t["_album_subtitle"] = album.get("subtitle", "")
                            all_tracks.append(t)
                except Exception as e:
                    logger.debug("Failed to load tracks for album %s: %s", album.get("title"), e)
                    continue

            logger.info("Total tracks fetched from Roon: %d", len(all_tracks))
            return all_tracks

        except Exception as e:
            logger.exception("Failed to get all tracks from Roon: %s", e)
            return []

    def get_all_albums_metadata(self) -> dict[str, dict[str, Any]]:
        """Browse albums and extract genres/year.

        Returns dict mapping album item_key → {genres, year, title, artist}.
        """
        if not self.is_connected():
            return {}

        metadata: dict[str, dict[str, Any]] = {}
        try:
            self._api.browse_browse({"hierarchy": "albums"})
            result = self._api.browse_load({"hierarchy": "albums", "count": 10000})
            for album in result.get("items", []):
                item_key = album.get("item_key", "")
                if not item_key:
                    continue
                # subtitle typically contains "Artist • Year • Genre" in Roon
                subtitle = album.get("subtitle", "") or ""
                parts = [p.strip() for p in subtitle.split("•")]
                year = None
                genres: list[str] = []
                artist = ""
                for part in parts:
                    if re.match(r"^\d{4}$", part):
                        year = int(part)
                    elif part and not year and re.match(r"^\d{4}", part):
                        pass  # skip decade-ish strings
                    elif part:
                        if not artist:
                            artist = part
                        else:
                            genres.append(part)
                metadata[item_key] = {
                    "genres": genres,
                    "year": year,
                    "title": album.get("title", ""),
                    "artist": artist,
                }
            logger.info("Got metadata for %d albums", len(metadata))
        except Exception as e:
            logger.exception("Failed to get album metadata: %s", e)
        return metadata

    def get_library_stats(self) -> dict[str, Any]:
        """Return {total_tracks, genres, decades}."""
        if not self.is_connected():
            return {"total_tracks": 0, "genres": [], "decades": []}

        try:
            album_meta = self.get_all_albums_metadata()
            genre_set: dict[str, int] = {}
            decade_set: dict[str, int] = {}

            for meta in album_meta.values():
                for g in meta.get("genres", []):
                    genre_set[g] = genre_set.get(g, 0) + 1
                year = meta.get("year")
                if year:
                    decade = f"{(year // 10) * 10}s"
                    decade_set[decade] = decade_set.get(decade, 0) + 1

            genres = sorted([{"name": k, "count": v} for k, v in genre_set.items()], key=lambda x: x["name"])
            decades = sorted([{"name": k, "count": v} for k, v in decade_set.items()], key=lambda x: x["name"])

            total = self.get_library_total_tracks()
            return {"total_tracks": total, "genres": genres, "decades": decades}
        except Exception as e:
            logger.exception("Failed to get library stats: %s", e)
            return {"total_tracks": 0, "genres": [], "decades": [], "error": str(e)}

    def search_tracks(self, query: str, limit: int = 20) -> list[Track]:
        """Search for tracks by title/artist using Roon search."""
        if not self.is_connected():
            return []
        try:
            self._api.browse_browse({"hierarchy": "search", "input": query, "pop_all": True})
            result = self._api.browse_load({"hierarchy": "search", "count": limit * 2})
            tracks = []
            for item in result.get("items", []):
                if item.get("hint") == "action":
                    track = self._convert_track(item, {})
                    if track:
                        tracks.append(track)
                        if len(tracks) >= limit:
                            break
            return tracks
        except Exception as e:
            logger.warning("Search failed: %s", e)
            return []

    def get_track_by_key(self, item_key: str) -> Track | None:
        """Get a single track by its Roon item_key."""
        if not self.is_connected():
            return None
        try:
            self._api.browse_browse({"hierarchy": "browse", "item_key": item_key})
            result = self._api.browse_load({"hierarchy": "browse", "count": 1})
            items = result.get("items", [])
            if items:
                return self._convert_track(items[0], {})
        except Exception as e:
            logger.warning("get_track_by_key failed for %s: %s", item_key, e)
        return None

    # ------------------------------------------------------------------
    # Zones / Transport
    # ------------------------------------------------------------------

    def get_zones(self) -> list[RoonZoneInfo]:
        """Return all zones from the Roon API."""
        if not self.is_connected():
            return []
        try:
            zones_raw = self._api.zones or {}
            result = []
            for zone_id, zone in zones_raw.items():
                outputs = [o.get("display_name", "") for o in zone.get("outputs", [])]
                state = zone.get("state", "stopped")
                result.append(RoonZoneInfo(
                    zone_id=zone_id,
                    display_name=zone.get("display_name", zone_id),
                    state=state,
                    outputs=outputs,
                    is_grouped=len(outputs) > 1,
                ))
            return result
        except Exception as e:
            logger.warning("Failed to get zones: %s", e)
            return []

    def play_tracks(
        self, zone_id: str, item_keys: list[str], mode: str = "replace"
    ) -> dict[str, Any]:
        """Queue and play tracks on a Roon zone.

        Args:
            zone_id: Roon zone ID
            item_keys: List of Roon item_keys
            mode: 'replace' (play now) or 'play_next' (add after current)

        Returns:
            dict with success, tracks_queued, error
        """
        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

        if not item_keys:
            return {"success": False, "error": "No tracks provided"}

        try:
            action = "play_now" if mode == "replace" else "add_next"
            tracks_queued = 0
            tracks_skipped = 0

            for key in item_keys:
                try:
                    self._api.playback_control(zone_id, action, item_key=key)
                    tracks_queued += 1
                    # After first track, switch to queue for subsequent tracks
                    action = "queue"
                except Exception as e:
                    logger.warning("Failed to queue track %s: %s", key, e)
                    tracks_skipped += 1

            zone_name = self._get_zone_name(zone_id)
            return {
                "success": tracks_queued > 0,
                "zone_name": zone_name,
                "tracks_queued": tracks_queued,
                "tracks_skipped": tracks_skipped,
            }
        except Exception as e:
            logger.exception("Failed to play tracks on zone %s", zone_id)
            return {"success": False, "error": str(e)}

    def _get_zone_name(self, zone_id: str) -> str | None:
        """Return display name for a zone."""
        try:
            zones = self._api.zones or {}
            zone = zones.get(zone_id, {})
            return zone.get("display_name") or zone_id
        except Exception:
            return zone_id

    def get_image_url(self, image_key: str, width: int = 500, height: int = 500) -> str | None:
        """Return a URL for a Roon image by image_key."""
        if not self.is_connected() or not image_key:
            return None
        try:
            url = self._api.get_image(image_key, width=width, height=height)
            return url
        except Exception as e:
            logger.warning("Failed to get image URL for key %s: %s", image_key, e)
            return None

    # ------------------------------------------------------------------
    # Conversion
    # ------------------------------------------------------------------

    def _convert_track(
        self, roon_item: dict[str, Any], album_info: dict[str, Any]
    ) -> Track | None:
        """Convert a Roon browse item dict to our Track model.

        Args:
            roon_item: Browse item dict from Roon API
            album_info: Optional album metadata dict {genres, year, title, artist}
        """
        item_key = roon_item.get("item_key", "")
        title = roon_item.get("title", "Unknown Track")
        subtitle = roon_item.get("subtitle", "") or ""  # Usually "Artist • Album"

        # Parse subtitle: "Artist • Album" or just "Artist"
        parts = [p.strip() for p in subtitle.split("•")]
        artist = parts[0] if parts else "Unknown Artist"
        album = parts[1] if len(parts) > 1 else album_info.get("title", "Unknown Album")

        # Fall back to album metadata
        if not artist or artist == "Unknown Artist":
            artist = album_info.get("artist", "Unknown Artist")

        genres = album_info.get("genres", [])
        year = album_info.get("year")
        image_key = roon_item.get("image_key", "")

        # Build art_url via our proxy endpoint
        art_url = f"/api/art/{item_key}" if item_key else None

        return Track(
            rating_key=item_key,
            title=title,
            artist=artist,
            album=album,
            duration_ms=roon_item.get("duration", 0) * 1000 if roon_item.get("duration") else 0,
            year=year,
            genres=genres,
            art_url=art_url,
        )


# ---------------------------------------------------------------------------
# Global singleton
# ---------------------------------------------------------------------------

_roon_client: RoonClient | None = None


def get_roon_client() -> RoonClient | None:
    """Get the current Roon client instance."""
    return _roon_client


def init_roon_client(
    host: str,
    port: int = 9100,
    core_id: str = "",
    token: str = "",
) -> RoonClient:
    """Initialize or reinitialize the Roon client."""
    global _roon_client
    _roon_client = RoonClient(host=host, port=port, core_id=core_id, token=token)
    return _roon_client


    def get_random_tracks(
        self,
        count: int,
        exclude_live: bool = True,
    ) -> list[Track]:
        """Get a random sample of tracks from the library.

        Falls back to fetching all tracks and sampling.
        """
        import random
        all_tracks = self.get_all_raw_tracks()
        if exclude_live:
            all_tracks = [t for t in all_tracks if not is_live_version(t)]
        random.shuffle(all_tracks)
        sample = all_tracks[:count]
        return [t for t in (self._convert_track(item, {}) for item in sample) if t]

    def get_tracks_by_filters(
        self,
        genres: list[str] | None = None,
        decades: list[str] | None = None,
        exclude_live: bool = True,
        min_rating: int = 0,
        limit: int = 0,
    ) -> list[Track]:
        """Get tracks matching filter criteria from the library cache.

        Falls back to an in-memory filter over all_raw_tracks when cache is empty.
        """
        import random
        album_meta = self.get_all_albums_metadata()
        all_tracks = self.get_all_raw_tracks()

        results = []
        for item in all_tracks:
            album_key_val = item.get("_album_item_key", "")
            meta = album_meta.get(album_key_val, {})
            item_genres = meta.get("genres", [])
            item_year = meta.get("year")

            # Genre filter
            if genres and not any(g.lower() in [x.lower() for x in item_genres] for g in genres):
                continue
            # Decade filter
            if decades and item_year:
                decade = f"{(item_year // 10) * 10}s"
                if decade not in decades:
                    continue
            # Live filter
            if exclude_live and is_live_version(item):
                continue

            track = self._convert_track(item, meta)
            if track:
                results.append(track)

        if limit > 0:
            random.shuffle(results)
            results = results[:limit]

        return results

    def count_tracks_by_filters(
        self,
        genres: list[str] | None = None,
        decades: list[str] | None = None,
        exclude_live: bool = True,
        min_rating: int = 0,
    ) -> int:
        """Count tracks matching filter criteria."""
        tracks = self.get_tracks_by_filters(genres=genres, decades=decades,
                                             exclude_live=exclude_live, min_rating=min_rating)
        return len(tracks)
