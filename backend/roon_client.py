"""Roon Core client for library queries and zone/transport management."""

import hashlib
import logging
import re
import threading
import time
from typing import Any, Callable

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
    ) -> str:
        key_data = {
            "genres": sorted(genres or []),
            "decades": sorted(decades or []),
            "exclude_live": exclude_live,
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
    ) -> list[Track] | None:
        key = self._make_key(genres, decades, exclude_live)
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
        tracks: list[Track],
    ) -> None:
        key = self._make_key(genres, decades, exclude_live)
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
        "extension_id": "com.roonsage.roon",
        "display_name": "RoonSage",
        "display_version": "1.0.0",
        "publisher": "RoonSage",
        "email": "roonsage@example.com",
        "website": "https://github.com/Georgemvp/roonsage",
    }

    def __init__(
        self,
        host: str,
        port: int = 9330,
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
        # The Browse API is single-session — concurrent browse operations on the
        # same hierarchy corrupt each other's state. Serialize all browse sequences.
        # The Browse API is single-session *per hierarchy*.  Using three
        # separate locks means "browse", "albums", and "genres" operations can
        # run concurrently without blocking each other.
        self._browse_lock = threading.Lock()         # "browse" hierarchy
        self._albums_browse_lock = threading.Lock()  # "albums" hierarchy
        self._genres_browse_lock = threading.Lock()  # "genres" hierarchy
        self._needs_authorization = False
        # True while a _connect() call is in progress (in any thread).
        # Checked by is_connected() to avoid launching a second concurrent attempt.
        self._connecting = False

        if extension_info:
            self.EXTENSION_INFO = extension_info

        # Run connection in a background thread so startup is never blocked
        t = threading.Thread(target=self._connect, daemon=True)
        t.start()

    def _connect(self) -> None:
        """Attempt to connect to Roon Core."""
        self._connecting = True
        if not self.host:
            self._error = "Roon host is required"
            self._connecting = False
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
                    "RoonSage needs to be authorized in Roon. "
                    "Open Roon → Settings → Extensions and enable RoonSage."
                )
                return

            self._needs_authorization = False
            self._error = None
            logger.info(
                "Connected to Roon Core '%s'", self._api.core_name
            )

            # Persist token + core_id so they survive container restarts.
            # Imported here to avoid a circular import at module level
            # (config imports models; roon_client is imported by main).
            if self._api.token:
                try:
                    from backend.config import save_user_config  # noqa: PLC0415
                    save_user_config({
                        "roon": {
                            "token": self._api.token,
                            "core_id": getattr(self._api, "core_id", None)
                                       or self.core_id
                                       or "",
                        }
                    })
                    logger.info("Roon token persisted to data/config.user.yaml")
                except Exception as save_err:
                    logger.warning(
                        "Failed to persist Roon token to config: %s", save_err
                    )
        except ImportError:
            self._error = "roonapi package is not installed. Run: pip install roonapi"
            self._api = None
        except Exception as e:
            self._error = f"Roon connection error: {e}"
            self._api = None
        finally:
            self._connecting = False

    def is_connected(self) -> bool:
        """Return True if connected and authorized.

        Never blocks the caller: if a connection attempt is already in progress
        (_connecting is True), or if the reconnect cooldown has not elapsed yet,
        this method returns False immediately without starting a new attempt.
        When a reconnect *is* needed it is launched in a daemon thread so it
        cannot freeze the asyncio event loop.
        """
        if self._api is not None and not self._needs_authorization:
            return True

        # If a _connect() call is already running in another thread, don't pile
        # on — just report not-yet-connected.
        if self._connecting:
            return False

        now = time.time()
        with self._reconnect_lock:
            # Re-check inside the lock in case another thread just connected.
            if self._api is not None and not self._needs_authorization:
                return True
            # Also re-check _connecting — another thread may have started.
            if self._connecting:
                return False
            if now - self._last_reconnect_attempt >= self.RECONNECT_COOLDOWN:
                self._last_reconnect_attempt = now
                logger.info("Attempting to reconnect to Roon Core…")
                t = threading.Thread(target=self._connect, daemon=True)
                t.start()

        return False

    def needs_authorization(self) -> bool:
        """Return True if the extension needs to be authorized in Roon."""
        return self._needs_authorization

    def get_core_id(self) -> str | None:
        """Return the connected Roon Core's unique identifier."""
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

    def get_token(self) -> str | None:
        """Return the current Roon authorization token (safe public accessor)."""
        if not self._api:
            return None
        return getattr(self._api, "token", None)

    # ------------------------------------------------------------------
    # Library helpers — Browse API
    # ------------------------------------------------------------------

    def get_library_total_tracks(self) -> int:
        """Return total track count from the SQLite cache.

        Returns 0 when the cache is empty — the library sync process
        (library_cache.sync_library) is responsible for populating the cache.
        The expensive full-Roon scan must never happen here, as it blocks page
        load for large libraries (10k+ albums).
        """
        try:
            from backend import library_cache
            if library_cache.has_cached_tracks():
                count = library_cache.count_tracks_by_filters()
                if count >= 0:
                    return count
        except Exception as e:
            logger.debug("Cache track count failed: %s", e)

        # Cache is empty or unavailable — return 0 so the caller can trigger
        # a sync via checkLibraryStatus() without blocking initialization.
        return 0

    def _paginate_browse_load(
        self,
        hierarchy: str,
        batch_size: int = 500,
    ) -> list[dict[str, Any]]:
        """Load all items from the current browse position using paginated requests.

        Assumes browse_browse() has already been called to navigate to the
        desired position. Must be called while holding self._browse_lock.
        """
        all_items: list[dict[str, Any]] = []
        offset = 0
        while True:
            page = self._api.browse_load(
                {"hierarchy": hierarchy, "count": batch_size, "offset": offset}
            )
            items = page.get("items", []) if page else []
            all_items.extend(items)
            if len(items) < batch_size:
                break
            offset += batch_size
        return all_items

    def get_all_raw_tracks(
        self,
        on_album_progress: Callable[[int, int], None] | None = None,
    ) -> list[dict[str, Any]]:
        """Get all tracks from the Roon library.

        Tries two strategies in order:

        1. **Flat tracks browse** (Library → Tracks): navigates directly to the
           Tracks section and paginates the full list.  O(N/500) API calls —
           roughly 200 calls for 100k tracks instead of 22k for the per-album
           approach.

        2. **Per-album fallback**: navigates Library → Albums → each album.
           Fixed to navigate one level deeper into ``hint == "list"`` sub-items
           (the actual track rows are usually behind a "Tracks" list entry,
           not at the album-menu level).

        Returns a flat list of dicts with keys: title, subtitle, item_key,
        image_key, hint, _album_title, _album_subtitle, _album_item_key.

        Args:
            on_album_progress: Optional callback(albums_done, total_albums)
                fired after each album in the per-album fallback path.
        """
        if not self.is_connected():
            return []

        try:
            with self._browse_lock:
                # --- Strategy 1: flat Library → Tracks browse ---
                flat_tracks = self._try_flat_tracks_browse()
                if flat_tracks is not None:
                    logger.info(
                        "Flat tracks browse succeeded: %d tracks", len(flat_tracks)
                    )
                    return flat_tracks

                logger.info(
                    "Flat tracks browse unavailable, falling back to per-album browsing"
                )

                # --- Strategy 2: per-album browsing with fixed hint handling ---
                return self._browse_tracks_per_album(on_album_progress)

        except Exception as e:
            logger.exception("Failed to get all tracks from Roon: %s", e)
            return []

    # ------------------------------------------------------------------
    # Internal track-fetch helpers (must be called while _browse_lock held)
    # ------------------------------------------------------------------

    def _try_flat_tracks_browse(self) -> list[dict[str, Any]] | None:
        """Navigate Library → Tracks for a flat, paginated track list.

        This is the fast path: instead of 2 API calls per album (22k+ calls
        for large libraries), it does ~5 navigation calls plus one paginated
        load.  For 100k tracks at batch_size=500 that is ≈205 total calls
        (~41 seconds) vs the per-album approach (~41 minutes).

        Must be called while holding ``self._browse_lock``.

        Returns:
            List of track dicts on success, or ``None`` if the Tracks section
            could not be found (caller should fall back to per-album browsing).
        """
        try:
            # Reset to browse root
            self._api.browse_browse({"hierarchy": "browse", "pop_all": True})
            root_page = self._api.browse_load({"hierarchy": "browse", "count": 100})
            root_items = root_page.get("items", []) if root_page else []

            logger.debug(
                "Flat browse root items: %s",
                [i.get("title") for i in root_items],
            )

            # Find the Library section
            library_item = next(
                (i for i in root_items if "library" in i.get("title", "").lower()),
                None,
            )
            if not library_item:
                logger.debug(
                    "Flat browse: no Library item found in browse root"
                )
                return None

            # Navigate into Library
            self._api.browse_browse(
                {"hierarchy": "browse", "item_key": library_item["item_key"]}
            )
            lib_page = self._api.browse_load({"hierarchy": "browse", "count": 100})
            lib_items = lib_page.get("items", []) if lib_page else []

            logger.debug(
                "Library sub-items: %s",
                [(i.get("title"), i.get("hint")) for i in lib_items],
            )

            # Find the Tracks section (title varies by Roon locale)
            tracks_item = next(
                (
                    i for i in lib_items
                    if i.get("title", "").lower() in (
                        "tracks", "all tracks", "songs", "all songs"
                    )
                ),
                None,
            )
            if not tracks_item:
                logger.info(
                    "Flat browse: no Tracks item found in Library — "
                    "available: %s",
                    [i.get("title") for i in lib_items],
                )
                return None

            # Navigate into Tracks and load everything
            self._api.browse_browse(
                {"hierarchy": "browse", "item_key": tracks_item["item_key"]}
            )
            all_items = self._paginate_browse_load("browse")

            logger.info(
                "Flat tracks browse: loaded %d raw items", len(all_items)
            )

            # Log a sample for future diagnosis
            if all_items:
                logger.debug(
                    "Flat tracks sample (first 5): %s",
                    [
                        (t.get("title"), t.get("hint"), t.get("subtitle", "")[:50])
                        for t in all_items[:5]
                    ],
                )

            # Keep only directly-playable track items (hint == "action" or "action_list")
            track_items = [
                t for t in all_items
                if t.get("hint") in ("action", "action_list") and t.get("item_key")
            ]

            if not track_items:
                logger.warning(
                    "Flat browse: 0 action/action_list items from %d total items — "
                    "hints seen: %s",
                    len(all_items),
                    list({t.get("hint") for t in all_items}),
                )
                return None

            logger.info(
                "Flat browse: %d tracks (from %d items)",
                len(track_items),
                len(all_items),
            )
            return track_items

        except Exception as exc:
            logger.warning("Flat tracks browse failed: %s", exc)
            return None

    def _browse_tracks_per_album(
        self,
        on_album_progress: Callable[[int, int], None] | None = None,
    ) -> list[dict[str, Any]]:
        """Per-album fallback: Library → Albums → each album → tracks.

        Fixed vs the original implementation:
        - Adds debug logging per album so the hint structure is visible in logs.
        - Navigates one level deeper into ``hint == "list"`` sub-items when the
          album level returns a menu (Play Album / Add to Queue) rather than
          individual track rows.
        - Identifies actual tracks by ``subtitle`` presence, not just by hint,
          so menu action items are excluded.

        Must be called while holding ``self._browse_lock``.
        """
        all_tracks: list[dict[str, Any]] = []

        # Reset and load browse root
        self._api.browse_browse({"hierarchy": "browse", "pop_all": True})
        root_page = self._api.browse_load({"hierarchy": "browse", "count": 1000})
        root_items = root_page.get("items", []) if root_page else []

        library_item = next(
            (i for i in root_items if "library" in i.get("title", "").lower()),
            None,
        )
        if not library_item:
            logger.warning("Per-album fallback: Library item not found in browse root")
            return []

        # Navigate Library → Albums
        self._api.browse_browse(
            {"hierarchy": "browse", "item_key": library_item["item_key"]}
        )
        lib_sub_page = self._api.browse_load({"hierarchy": "browse", "count": 200})
        lib_sub_items = lib_sub_page.get("items", []) if lib_sub_page else []

        albums_item = next(
            (i for i in lib_sub_items if "album" in i.get("title", "").lower()),
            None,
        )
        if not albums_item:
            logger.warning(
                "Per-album fallback: Albums item not found in Library — "
                "available: %s",
                [i.get("title") for i in lib_sub_items],
            )
            return []

        self._api.browse_browse(
            {"hierarchy": "browse", "item_key": albums_item["item_key"]}
        )
        album_items = self._paginate_browse_load("browse")

        total_albums = len(album_items)
        logger.info("Per-album fallback: %d albums to process", total_albums)

        for album_idx, album in enumerate(album_items):
            album_key = album.get("item_key")
            if not album_key:
                continue

            try:
                self._api.browse_browse(
                    {"hierarchy": "browse", "item_key": album_key}
                )
                album_page = self._api.browse_load(
                    {"hierarchy": "browse", "count": 500}
                )
                page_items = album_page.get("items", []) if album_page else []

                logger.debug(
                    "Album '%s' returned %d items: %s",
                    album.get("title"),
                    len(page_items),
                    [
                        (t.get("title"), t.get("hint"), t.get("subtitle", "")[:50])
                        for t in page_items
                    ],
                )

                tracks = self._extract_tracks_from_album_items(page_items, album)
                all_tracks.extend(tracks)

            except Exception as exc:
                logger.debug(
                    "Failed to load tracks for album '%s': %s",
                    album.get("title"),
                    exc,
                )

            if on_album_progress:
                try:
                    on_album_progress(album_idx + 1, total_albums)
                except Exception:
                    pass  # never let a progress callback break the loop

        logger.info(
            "Per-album fallback complete: %d tracks from %d albums",
            len(all_tracks),
            total_albums,
        )
        return all_tracks

    def _extract_tracks_from_album_items(
        self,
        items: list[dict[str, Any]],
        album: dict[str, Any],
    ) -> list[dict[str, Any]]:
        """Extract playable track rows from an album's browse result.

        When Roon navigates into an album it can return two very different
        shapes:

        A) **Direct tracks** — each item is a playable track row:
           ``hint == "action"``, non-empty ``subtitle`` (e.g. "Artist Name")
           These are collected immediately.

        B) **Album action menu** — items are "Play Now", "Add to Queue",
           plus a ``hint == "list"`` entry titled "Tracks" (or similar).
           Individual track rows live one level deeper inside that list.

        The original code treated everything with ``hint == "action"`` or
        ``hint == "list"`` as a track, which collected the album-level menu
        items (Play Album, Add to Queue) instead of the actual track rows.

        This method handles both shapes correctly.

        Must be called while holding ``self._browse_lock``.
        """
        tracks: list[dict[str, Any]] = []
        list_sub_items: list[dict[str, Any]] = []

        for item in items:
            hint = item.get("hint", "")
            subtitle = (item.get("subtitle") or "").strip()
            item_key = item.get("item_key", "")

            if hint == "action" and subtitle and item_key:
                # Has a subtitle → looks like an actual track, not a menu action
                # (menu actions like "Play Album Now" have no subtitle)
                tagged = dict(item)
                tagged["_album_title"] = album.get("title", "")
                tagged["_album_subtitle"] = album.get("subtitle", "")
                tagged["_album_item_key"] = album.get("item_key", "")
                tracks.append(tagged)
            elif hint == "list" and item_key:
                # Sub-list that may contain track rows — collect for later
                list_sub_items.append(item)

        if tracks:
            # Shape A — got direct track rows from this level
            return tracks

        # Shape B — no direct tracks found; navigate into list sub-items
        for sub in list_sub_items:
            try:
                self._api.browse_browse(
                    {"hierarchy": "browse", "item_key": sub["item_key"]}
                )
                # Use paginator in case album has >500 tracks
                sub_items = self._paginate_browse_load("browse")

                logger.debug(
                    "Album '%s' → list '%s' returned %d items",
                    album.get("title"),
                    sub.get("title"),
                    len(sub_items),
                )

                for t in sub_items:
                    if t.get("hint") == "action" and t.get("item_key"):
                        tagged = dict(t)
                        tagged["_album_title"] = album.get("title", "")
                        tagged["_album_subtitle"] = album.get("subtitle", "")
                        tagged["_album_item_key"] = album.get("item_key", "")
                        tracks.append(tagged)

                if tracks:
                    # Found tracks in the first matching sub-list; stop
                    break

            except Exception as exc:
                logger.debug(
                    "Failed to navigate list sub-item '%s' for album '%s': %s",
                    sub.get("title"),
                    album.get("title"),
                    exc,
                )

        return tracks

    def _get_genre_mapping(self) -> dict[str, list[str]]:
        """Browse genres hierarchy to build album_title -> [genres] mapping.

        Only uses top-level genres (skips sub-genres) for speed.
        Must be called while holding self._genres_browse_lock.
        """
        try:
            # Collect genre names first
            self._api.browse_browse({"hierarchy": "genres", "pop_all": True})
            genre_items = self._paginate_browse_load("genres")
            genre_names = [g.get("title", "") for g in genre_items if g.get("title")]
            logger.info("Found %d top-level genres in Roon", len(genre_names))

            mapping: dict[str, list[str]] = {}

            for idx, genre_name in enumerate(genre_names):
                try:
                    # Reset to root and re-load genre list for fresh item_keys
                    self._api.browse_browse({"hierarchy": "genres", "pop_all": True})
                    fresh_genres = self._paginate_browse_load("genres")

                    # Find this genre by name with a fresh item_key
                    genre_item = next(
                        (g for g in fresh_genres if g.get("title") == genre_name),
                        None,
                    )
                    if not genre_item or not genre_item.get("item_key"):
                        continue

                    # Browse into genre
                    self._api.browse_browse({"hierarchy": "genres", "item_key": genre_item["item_key"]})
                    genre_contents = self._paginate_browse_load("genres")

                    # Find the "Albums" entry
                    albums_item = next(
                        (i for i in genre_contents
                         if (i.get("title") or "").lower() == "albums"
                         and i.get("hint") == "list"),
                        None,
                    )

                    if albums_item and albums_item.get("item_key"):
                        self._api.browse_browse({"hierarchy": "genres", "item_key": albums_item["item_key"]})
                        albums = self._paginate_browse_load("genres")

                        for album in albums:
                            album_title = (album.get("title") or "").strip().lower()
                            if album_title:
                                mapping.setdefault(album_title, [])
                                if genre_name not in mapping[album_title]:
                                    mapping[album_title].append(genre_name)

                        logger.info(
                            "Processed genre '%s' (%d/%d) — %d albums found",
                            genre_name, idx + 1, len(genre_names), len(albums),
                        )
                    else:
                        logger.info(
                            "Processed genre '%s' (%d/%d) — no Albums entry found. Contents: %s",
                            genre_name, idx + 1, len(genre_names),
                            [(i.get("title"), i.get("hint")) for i in genre_contents[:5]],
                        )

                except Exception as exc:
                    logger.warning("Failed to process genre '%s': %s", genre_name, exc)

            logger.info(
                "Genre mapping complete: %d unique albums mapped to genres", len(mapping)
            )
            return mapping

        except Exception as exc:
            logger.warning("Genre mapping failed: %s", exc)
            return {}

    def get_all_albums_metadata(self) -> dict[str, dict[str, Any]]:
        """Browse albums and extract genres/year.

        Returns dict mapping album item_key → {genres, year, title, artist}.
        Albums are paginated in batches of 500 to handle large libraries.
        """
        if not self.is_connected():
            return {}

        metadata: dict[str, dict[str, Any]] = {}
        try:
            # --- Step 1: load album list for artist/year from subtitles ---
            # Uses the "albums" hierarchy — lock is independent of "browse" and
            # "genres", so track sync can run concurrently.
            with self._albums_browse_lock:
                self._api.browse_browse({"hierarchy": "albums"})
                album_items = self._paginate_browse_load("albums")

                # Log sample album data to diagnose subtitle format
                if album_items:
                    logger.info(
                        "Sample album subtitles (first 10): %s",
                        [
                            (a.get("title"), a.get("subtitle", ""), a.get("hint"))
                            for a in album_items[:10]
                        ],
                    )

                for album in album_items:
                    item_key = album.get("item_key", "")
                    if not item_key:
                        continue
                    # subtitle format varies by Roon version/locale.
                    # Common formats: "Artist", "Artist • Year", "Artist • Year • Genre"
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
                        "image_key": album.get("image_key", ""),
                    }

            # --- Step 2: enrich with genres from the genres hierarchy ---
            # Uses the "genres" hierarchy — independent of "browse" and "albums",
            # so this lock does not block or get blocked by track sync.
            with self._genres_browse_lock:
                genre_mapping = self._get_genre_mapping()
                if genre_mapping:
                    enriched = 0
                    for meta in metadata.values():
                        album_title_lower = meta.get("title", "").strip().lower()
                        mapped_genres = genre_mapping.get(album_title_lower)
                        if mapped_genres:
                            # Merge: keep any genres already parsed from subtitle,
                            # then append mapped genres that aren't already present.
                            existing = set(meta["genres"])
                            for g in mapped_genres:
                                if g not in existing:
                                    meta["genres"].append(g)
                                    existing.add(g)
                            enriched += 1
                    logger.info(
                        "Genre enrichment: %d / %d albums now have genres from mapping",
                        enriched,
                        len(metadata),
                    )

            logger.info("Got metadata for %d albums", len(metadata))
            albums_with_genres = sum(1 for m in metadata.values() if m.get("genres"))
            albums_with_year = sum(1 for m in metadata.values() if m.get("year"))
            logger.info(
                "Album metadata summary: %d total, %d with genres, %d with year",
                len(metadata),
                albums_with_genres,
                albums_with_year,
            )
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
            with self._browse_lock:
                self._api.browse_browse(
                    {"hierarchy": "search", "input": query,
                     "pop_all": True}
                )
                result = self._api.browse_load(
                    {"hierarchy": "search", "count": 100}
                )
                tracks = []
                top_items = result.get("items", [])

                # Direct action items at top level (some Roon versions)
                for item in top_items:
                    if (item.get("hint") == "action"
                            and item.get("item_key")):
                        track = self._convert_track(item, {})
                        if track:
                            tracks.append(track)

                # Navigate into list sections to find actual tracks
                if not tracks:
                    for section in top_items:
                        if section.get("hint") != "list":
                            continue
                        if not section.get("item_key"):
                            continue
                        self._api.browse_browse(
                            {"hierarchy": "search",
                             "item_key": section["item_key"]}
                        )
                        sub_result = self._api.browse_load(
                            {"hierarchy": "search",
                             "count": limit * 2}
                        )
                        for item in sub_result.get("items", []):
                            if item.get("hint") in (
                                "action", "action_list"
                            ):
                                track = self._convert_track(item, {})
                                if track:
                                    tracks.append(track)
                                    if len(tracks) >= limit:
                                        break
                        if tracks:
                            break

            return tracks[:limit]
        except Exception as e:
            logger.warning("Search failed: %s", e)
            return []

    def get_track_by_key(self, item_key: str) -> Track | None:
        """Get a single track by its Roon item_key."""
        if not self.is_connected():
            return None
        try:
            with self._browse_lock:
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
        """Queue and play tracks on a Roon zone via the Browse API.

        The roonapi playback_control() method only accepts transport commands
        (play/pause/stop/next/previous) and does not support item_key.  To
        play a specific track we must navigate to it through browse_browse /
        browse_load and execute the appropriate action item.

        Args:
            zone_id: Roon zone ID
            item_keys: List of Roon item_keys for tracks to play
            mode: 'replace' (play now, clears queue) or 'play_next' (add after current)

        Returns:
            dict with success, tracks_queued, tracks_skipped, error
        """
        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

        if not item_keys:
            return {"success": False, "error": "No tracks provided"}

        # Action label keywords to match in browse result items.
        # First track: start fresh ("Play Now" / "Play").
        # Subsequent tracks: append ("Queue" / "Add to Queue" / "Add Next").
        PLAY_NOW_KEYWORDS = {"play now", "play"}
        QUEUE_KEYWORDS = {"queue", "add to queue", "add next"}

        tracks_queued = 0
        tracks_skipped = 0

        try:
            for idx, key in enumerate(item_keys):
                try:
                    with self._browse_lock:
                        # Navigate to the track via Browse API
                        self._api.browse_browse({
                            "hierarchy": "browse",
                            "item_key": key,
                            "zone_or_output_id": zone_id,
                        })
                        result = self._api.browse_load({
                            "hierarchy": "browse",
                            "count": 20,
                            "zone_or_output_id": zone_id,
                        })

                    items = result.get("items", []) if result else []

                    # Decide which action label to look for
                    if idx == 0 and mode == "replace":
                        target_keywords = PLAY_NOW_KEYWORDS
                        fallback_keywords = QUEUE_KEYWORDS
                    else:
                        target_keywords = QUEUE_KEYWORDS
                        fallback_keywords = PLAY_NOW_KEYWORDS

                    # Find the matching action item
                    action_item = None
                    fallback_item = None
                    for item in items:
                        title_lower = item.get("title", "").lower().strip()
                        if title_lower in target_keywords:
                            action_item = item
                            break
                        if title_lower in fallback_keywords and fallback_item is None:
                            fallback_item = item

                    chosen = action_item or fallback_item
                    if not chosen or not chosen.get("item_key"):
                        logger.warning(
                            "No playable action found for track key %s (items: %s)",
                            key,
                            [i.get("title") for i in items],
                        )
                        tracks_skipped += 1
                        continue

                    # Execute the action
                    with self._browse_lock:
                        self._api.browse_browse({
                            "hierarchy": "browse",
                            "item_key": chosen["item_key"],
                            "zone_or_output_id": zone_id,
                        })
                    tracks_queued += 1

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

    def transport_control(
        self,
        zone_id: str,
        action: str,
        value: str | None = None,
        position_seconds: int | None = None,
        seek_offset: int | None = None,
    ) -> dict[str, Any]:
        """Send a transport command to a Roon zone.

        Args:
            zone_id:          Roon zone ID (from get_zones)
            action:           One of "play", "pause", "stop", "next", "previous",
                              "shuffle", "repeat", "seek"
            value:            For "shuffle": "true"/"false"/"toggle"
                              For "repeat": "disabled"/"loop"/"loop_one"/"cycle"
            position_seconds: For "seek" (absolute position in seconds)
            seek_offset:      For "seek" (relative offset in seconds, can be negative)

        Returns:
            dict with success, zone_name, action, state, error
        """
        playback_actions = {"play", "pause", "stop", "next", "previous"}

        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

        zone_name = self._get_zone_name(zone_id)

        try:
            if action in playback_actions:
                self._api.playback_control(zone_id, action)
                return {"success": True, "zone_name": zone_name, "action": action}

            elif action == "shuffle":
                # Determine target shuffle state
                zones_raw = self._api.zones or {}
                zone = zones_raw.get(zone_id, {})
                current = zone.get("settings", {}).get("shuffle", False)
                if value in ("true", "1", "on", "yes"):
                    new_state = True
                elif value in ("false", "0", "off", "no"):
                    new_state = False
                else:  # toggle (default)
                    new_state = not current
                self._api.shuffle(zone_id, new_state)
                return {
                    "success": True,
                    "zone_name": zone_name,
                    "action": action,
                    "state": "on" if new_state else "off",
                }

            elif action == "repeat":
                REPEAT_MODES = ["disabled", "loop", "loop_one"]
                if value == "cycle":
                    # Cycle through repeat modes
                    zones_raw = self._api.zones or {}
                    zone = zones_raw.get(zone_id, {})
                    current = zone.get("settings", {}).get("loop", "disabled")
                    idx = REPEAT_MODES.index(current) if current in REPEAT_MODES else 0
                    new_mode = REPEAT_MODES[(idx + 1) % len(REPEAT_MODES)]
                elif value in REPEAT_MODES:
                    new_mode = value
                else:
                    new_mode = "loop"  # default: enable loop
                self._api.repeat(zone_id, new_mode)
                return {
                    "success": True,
                    "zone_name": zone_name,
                    "action": action,
                    "state": new_mode,
                }

            elif action == "seek":
                if seek_offset is not None:
                    self._api.seek(zone_id, seek_offset, "relative")
                    return {
                        "success": True,
                        "zone_name": zone_name,
                        "action": action,
                        "state": f"relative:{seek_offset:+d}s",
                    }
                elif position_seconds is not None:
                    self._api.seek(zone_id, position_seconds, "absolute")
                    return {
                        "success": True,
                        "zone_name": zone_name,
                        "action": action,
                        "state": f"absolute:{position_seconds}s",
                    }
                else:
                    return {"success": False, "error": "seek requires position_seconds or seek_offset"}

            else:
                valid = sorted(playback_actions | {"shuffle", "repeat", "seek"})
                return {
                    "success": False,
                    "error": f"Invalid action '{action}'. Must be one of: {', '.join(valid)}",
                }

        except Exception as e:
            logger.warning("transport_control failed zone=%s action=%s: %s", zone_id, action, e)
            return {"success": False, "error": str(e)}

    # ------------------------------------------------------------------
    # Volume Control
    # ------------------------------------------------------------------

    def _resolve_output_for_zone(self, zone_name_or_id: str) -> tuple[str | None, str | None, dict | None]:
        """Resolve a zone name or ID to (zone_id, output_id, output_data).

        For grouped zones, returns the primary (first) output.
        Returns (None, None, None) if not found.
        """
        zones_raw = self._api.zones if self._api else {}
        # Try by zone_id first
        zone = zones_raw.get(zone_name_or_id)
        if not zone:
            # Try by display_name (case-insensitive)
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
    ) -> dict[str, Any]:
        """Control volume for a zone by name.

        Actions: "set" (0-100), "adjust" (+/-N), "get", "mute", "unmute", "toggle_mute"
        """
        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

        zone_id, output_id, output_data = self._resolve_output_for_zone(zone_name)
        if not zone_id or not output_id:
            return {"success": False, "error": f"Zone '{zone_name}' not found or has no outputs"}

        display = self._get_zone_name(zone_id)
        vol_info = (output_data or {}).get("volume", {})

        try:
            if action == "get":
                return {
                    "success": True,
                    "zone_name": display,
                    "action": "get",
                    "volume": vol_info.get("value"),
                    "is_muted": vol_info.get("is_muted", False),
                }

            elif action == "set":
                if value is None:
                    return {"success": False, "error": "value required for 'set'"}
                self._api.set_volume_percent(output_id, max(0, min(100, value)))

            elif action == "adjust":
                if value is None:
                    return {"success": False, "error": "value required for 'adjust'"}
                self._api.change_volume_percent(output_id, value)

            elif action == "mute":
                self._api.mute(output_id, True)

            elif action == "unmute":
                self._api.mute(output_id, False)

            elif action == "toggle_mute":
                currently_muted = vol_info.get("is_muted", False)
                self._api.mute(output_id, not currently_muted)

            else:
                return {
                    "success": False,
                    "error": f"Invalid action '{action}'. Use: set, adjust, get, mute, unmute, toggle_mute",
                }

            # Re-fetch volume after change
            time.sleep(0.2)
            zones_raw = self._api.zones or {}
            zone_fresh = zones_raw.get(zone_id, {})
            for out in zone_fresh.get("outputs", []):
                if out.get("output_id") == output_id:
                    vol_info = out.get("volume", {})
                    break

            return {
                "success": True,
                "zone_name": display,
                "action": action,
                "volume": vol_info.get("value"),
                "is_muted": vol_info.get("is_muted", False),
            }

        except Exception as e:
            logger.warning("volume_control failed zone=%s action=%s: %s", zone_name, action, e)
            return {"success": False, "error": str(e)}

    # ------------------------------------------------------------------
    # Zone Transfer & Grouping
    # ------------------------------------------------------------------

    def transfer_zone(
        self, from_zone: str, to_zone: str
    ) -> dict[str, Any]:
        """Transfer playback from one zone to another."""
        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

        from_id = self._resolve_zone_id(from_zone)
        to_id = self._resolve_zone_id(to_zone)
        if not from_id:
            return {"success": False, "error": f"Source zone '{from_zone}' not found"}
        if not to_id:
            return {"success": False, "error": f"Target zone '{to_zone}' not found"}

        try:
            self._api.transfer_zone(from_id, to_id)
            return {
                "success": True,
                "from_zone": self._get_zone_name(from_id),
                "to_zone": self._get_zone_name(to_id),
            }
        except Exception as e:
            logger.warning("transfer_zone failed %s -> %s: %s", from_zone, to_zone, e)
            return {"success": False, "error": str(e)}

    def zone_grouping(
        self, action: str, zone_names: list[str]
    ) -> dict[str, Any]:
        """Group, ungroup, or list zone groups.

        action: "group", "ungroup", "list_groups"
        zone_names: display names of zones to group/ungroup
        """
        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

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
            return {"success": True, "action": "list_groups", "groups": groups}

        # Resolve zone names to output IDs
        output_ids = []
        for name in zone_names:
            _, output_id, _ = self._resolve_output_for_zone(name)
            if output_id:
                output_ids.append(output_id)
            else:
                return {"success": False, "error": f"Zone '{name}' not found"}

        if len(output_ids) < 2 and action == "group":
            return {"success": False, "error": "At least 2 zones required for grouping"}

        try:
            if action == "group":
                # Check compatibility
                first_output_data = None
                for zid, z in zones_raw.items():
                    for out in z.get("outputs", []):
                        if out.get("output_id") == output_ids[0]:
                            first_output_data = out
                            break
                if first_output_data:
                    compatible = first_output_data.get("can_group_with_output_ids", [])
                    for oid in output_ids[1:]:
                        if oid not in compatible:
                            return {
                                "success": False,
                                "error": f"Output {oid} is not compatible for grouping with {output_ids[0]}",
                            }
                self._api.group_outputs(output_ids)
                return {
                    "success": True,
                    "action": "group",
                    "groups": [{"zones": zone_names}],
                }

            elif action == "ungroup":
                self._api.ungroup_outputs(output_ids)
                return {
                    "success": True,
                    "action": "ungroup",
                    "groups": [],
                }

            else:
                return {"success": False, "error": f"Invalid action '{action}'. Use: group, ungroup, list_groups"}

        except Exception as e:
            logger.warning("zone_grouping failed action=%s: %s", action, e)
            return {"success": False, "error": str(e)}

    # ------------------------------------------------------------------
    # Internet Radio
    # ------------------------------------------------------------------

    def play_radio(self, station_name: str, zone_id: str) -> dict[str, Any]:
        """Browse 'My Live Radio' and play a station by fuzzy-matched name.

        Uses the Browse API: Root → My Live Radio → station.
        """
        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

        zone_name = self._get_zone_name(zone_id)

        try:
            with self._browse_lock:
                # Navigate to browse root
                self._api.browse_browse({"hierarchy": "browse", "pop_all": True, "zone_or_output_id": zone_id})
                root_page = self._api.browse_load({"hierarchy": "browse", "count": 100, "zone_or_output_id": zone_id})
                root_items = root_page.get("items", []) if root_page else []

                # Find "My Live Radio" in root
                radio_item = next(
                    (i for i in root_items if "radio" in i.get("title", "").lower()),
                    None,
                )
                if not radio_item:
                    return {"success": False, "error": "My Live Radio not found in Roon browse. Check that you have internet radio configured in Roon."}

                # Navigate into radio list
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

                # Fuzzy-match station name
                station_lower = station_name.lower()
                best_match = None
                best_score = 0
                for s in stations:
                    title = s.get("title", "")
                    title_lower = title.lower()
                    if title_lower == station_lower:
                        best_match = s
                        break
                    # Simple substring score
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
                    return {
                        "success": False,
                        "error": f"Station '{station_name}' not found. Available stations (first 20): {station_list}",
                    }

                # Navigate into station and play
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

                # Find play action
                play_action = next(
                    (i for i in play_items if i.get("hint") == "action" and i.get("item_key")),
                    None,
                )
                if not play_action:
                    # Try navigating directly to station (some Roon versions auto-play)
                    return {"success": True, "station_name": best_match.get("title", station_name), "zone_name": zone_name}

                self._api.browse_browse({
                    "hierarchy": "browse",
                    "item_key": play_action["item_key"],
                    "zone_or_output_id": zone_id,
                })

            return {
                "success": True,
                "station_name": best_match.get("title", station_name),
                "zone_name": zone_name,
            }

        except Exception as e:
            logger.warning("play_radio failed station=%s zone=%s: %s", station_name, zone_id, e)
            return {"success": False, "error": str(e)}

    # ------------------------------------------------------------------
    # Playlists Browse
    # ------------------------------------------------------------------

    def browse_playlists(
        self,
        action: str,
        playlist_name: str = "",
        zone_id: str = "",
    ) -> dict[str, Any]:
        """Browse and optionally play Roon playlists.

        action: "list" or "play"
        """
        if not self.is_connected():
            return {"success": False, "error": "Not connected to Roon"}

        zone_name = self._get_zone_name(zone_id) if zone_id else None

        try:
            with self._browse_lock:
                # Navigate playlists hierarchy
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
                return {
                    "success": True,
                    "action": "list",
                    "playlists": playlists,
                }

            elif action == "play":
                if not playlist_name:
                    return {"success": False, "error": "playlist_name required for 'play'"}
                if not zone_id:
                    return {"success": False, "error": "zone_id required for 'play'"}

                # Fuzzy match playlist name
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
                    return {"success": False, "error": f"Playlist '{playlist_name}' not found. Available: {names}"}

                # Navigate into playlist and play
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

                    return {
                        "success": True,
                        "action": "play",
                        "playlists": [{"name": best_match.get("title", playlist_name)}],
                        "zone_name": zone_name,
                    }
                except Exception as e:
                    return {"success": False, "error": f"Could not play playlist: {e}"}

            else:
                return {"success": False, "error": f"Invalid action '{action}'. Use: list, play"}

        except Exception as e:
            logger.warning("browse_playlists failed action=%s: %s", action, e)
            return {"success": False, "error": str(e)}

    def _get_zone_name(self, zone_id: str) -> str | None:
        """Return display name for a zone."""
        try:
            zones = self._api.zones or {}
            zone = zones.get(zone_id, {})
            return zone.get("display_name") or zone_id
        except Exception:
            return zone_id

    def get_album_track_keys(self, album_item_key: str) -> list[str]:
        """Browse into an album and return its track item_keys.

        Used to lazily populate track_rating_keys for album recommendations
        at play time, so the albums table doesn't need to store track lists.

        Args:
            album_item_key: The Roon item_key of the album in the albums hierarchy

        Returns:
            List of track item_keys, empty on failure or if not connected
        """
        if not self.is_connected():
            return []
        try:
            with self._albums_browse_lock:
                self._api.browse_browse({"hierarchy": "albums", "item_key": album_item_key})
                items = self._paginate_browse_load("albums")
                return [
                    item["item_key"] for item in items
                    if item.get("hint") in ("action", "action_list") and item.get("item_key")
                ]
        except Exception as e:
            logger.warning("get_album_track_keys failed for %s: %s", album_item_key, e)
            return []

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
    ) -> int:
        """Count tracks matching filter criteria."""
        tracks = self.get_tracks_by_filters(genres=genres, decades=decades,
                                             exclude_live=exclude_live)
        return len(tracks)


# ---------------------------------------------------------------------------
# Global singleton
# ---------------------------------------------------------------------------

_roon_client: RoonClient | None = None


def get_roon_client() -> RoonClient | None:
    """Get the current Roon client instance."""
    return _roon_client


def init_roon_client(
    host: str,
    port: int = 9330,
    core_id: str = "",
    token: str = "",
) -> RoonClient:
    """Initialize or reinitialize the Roon client."""
    global _roon_client
    _roon_client = RoonClient(host=host, port=port, core_id=core_id, token=token)
    return _roon_client
