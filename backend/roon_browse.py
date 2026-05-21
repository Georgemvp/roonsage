"""Browse API navigation mixin for RoonSage."""

import contextlib
import logging
import re
import time
from collections.abc import Callable
from typing import Any

logger = logging.getLogger(__name__)

# In-memory cache for get_all_albums_metadata — avoids repeated full-library scans
_album_metadata_cache: dict = {"data": None, "timestamp": 0}
_ALBUM_METADATA_CACHE_TTL = 300  # 5 minutes


class RoonBrowseMixin:
    """Mixin providing Browse API navigation methods."""

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
           Tracks section and paginates the full list.  O(N/500) API calls.

        2. **Per-album fallback**: navigates Library → Albums → each album.

        Returns a flat list of dicts with keys: title, subtitle, item_key,
        image_key, hint, _album_title, _album_subtitle, _album_item_key.
        """
        if not self.is_connected():
            return []

        try:
            with self._browse_lock:
                flat_tracks = self._try_flat_tracks_browse()
                if flat_tracks is not None:
                    logger.info(
                        "Flat tracks browse succeeded: %d tracks", len(flat_tracks)
                    )
                    return flat_tracks

                logger.info(
                    "Flat tracks browse unavailable, falling back to per-album browsing"
                )

                return self._browse_tracks_per_album(on_album_progress)

        except Exception as e:
            logger.exception("Failed to get all tracks from Roon: %s", e)
            return []

    def _try_flat_tracks_browse(self) -> list[dict[str, Any]] | None:
        """Navigate Library → Tracks for a flat, paginated track list.

        Must be called while holding ``self._browse_lock``.

        Returns:
            List of track dicts on success, or ``None`` if the Tracks section
            could not be found (caller should fall back to per-album browsing).
        """
        try:
            self._api.browse_browse({"hierarchy": "browse", "pop_all": True})
            root_page = self._api.browse_load({"hierarchy": "browse", "count": 100})
            root_items = root_page.get("items", []) if root_page else []

            logger.debug(
                "Flat browse root items: %s",
                [i.get("title") for i in root_items],
            )

            library_item = next(
                (i for i in root_items if "library" in i.get("title", "").lower()),
                None,
            )
            if not library_item:
                logger.debug(
                    "Flat browse: no Library item found in browse root"
                )
                return None

            self._api.browse_browse(
                {"hierarchy": "browse", "item_key": library_item["item_key"]}
            )
            lib_page = self._api.browse_load({"hierarchy": "browse", "count": 100})
            lib_items = lib_page.get("items", []) if lib_page else []

            logger.debug(
                "Library sub-items: %s",
                [(i.get("title"), i.get("hint")) for i in lib_items],
            )

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

            self._api.browse_browse(
                {"hierarchy": "browse", "item_key": tracks_item["item_key"]}
            )
            all_items = self._paginate_browse_load("browse")

            logger.info(
                "Flat tracks browse: loaded %d raw items", len(all_items)
            )

            if all_items:
                logger.debug(
                    "Flat tracks sample (first 5): %s",
                    [
                        (t.get("title"), t.get("hint"), t.get("subtitle", "")[:50])
                        for t in all_items[:5]
                    ],
                )

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

        Must be called while holding ``self._browse_lock``.
        """
        all_tracks: list[dict[str, Any]] = []

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
                with contextlib.suppress(Exception):
                    on_album_progress(album_idx + 1, total_albums)

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

        Must be called while holding ``self._browse_lock``.
        """
        tracks: list[dict[str, Any]] = []
        list_sub_items: list[dict[str, Any]] = []

        for item in items:
            hint = item.get("hint", "")
            subtitle = (item.get("subtitle") or "").strip()
            item_key = item.get("item_key", "")

            if hint == "action" and subtitle and item_key:
                tagged = dict(item)
                tagged["_album_title"] = album.get("title", "")
                tagged["_album_subtitle"] = album.get("subtitle", "")
                tagged["_album_item_key"] = album.get("item_key", "")
                tracks.append(tagged)
            elif hint == "list" and item_key:
                list_sub_items.append(item)

        if tracks:
            return tracks

        for sub in list_sub_items:
            try:
                self._api.browse_browse(
                    {"hierarchy": "browse", "item_key": sub["item_key"]}
                )
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
            self._api.browse_browse({"hierarchy": "genres", "pop_all": True})
            genre_items = self._paginate_browse_load("genres")
            genre_names = [g.get("title", "") for g in genre_items if g.get("title")]
            logger.info("Found %d top-level genres in Roon", len(genre_names))

            mapping: dict[str, list[str]] = {}

            for idx, genre_name in enumerate(genre_names):
                try:
                    self._api.browse_browse({"hierarchy": "genres", "pop_all": True})
                    fresh_genres = self._paginate_browse_load("genres")

                    genre_item = next(
                        (g for g in fresh_genres if g.get("title") == genre_name),
                        None,
                    )
                    if not genre_item or not genre_item.get("item_key"):
                        continue

                    self._api.browse_browse({"hierarchy": "genres", "item_key": genre_item["item_key"]})
                    genre_contents = self._paginate_browse_load("genres")

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
        Cached for 5 minutes to avoid repeated full-library scans.
        """
        if not self.is_connected():
            return {}

        now = time.time()
        if (
            _album_metadata_cache["data"] is not None
            and (now - _album_metadata_cache["timestamp"]) < _ALBUM_METADATA_CACHE_TTL
        ):
            return _album_metadata_cache["data"]

        metadata: dict[str, dict[str, Any]] = {}
        try:
            with self._albums_browse_lock:
                self._api.browse_browse({"hierarchy": "albums"})
                album_items = self._paginate_browse_load("albums")

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
                    subtitle = album.get("subtitle", "") or ""
                    parts = [p.strip() for p in subtitle.split("•")]
                    year = None
                    genres: list[str] = []
                    artist = ""
                    for part in parts:
                        if re.match(r"^\d{4}$", part):
                            year = int(part)
                        elif part and not year and re.match(r"^\d{4}", part):
                            pass
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

            with self._genres_browse_lock:
                genre_mapping = self._get_genre_mapping()
                if genre_mapping:
                    enriched = 0
                    for meta in metadata.values():
                        album_title_lower = meta.get("title", "").strip().lower()
                        mapped_genres = genre_mapping.get(album_title_lower)
                        if mapped_genres:
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

        # Store in cache (even partial results are worth caching)
        if metadata:
            _album_metadata_cache["data"] = metadata
            _album_metadata_cache["timestamp"] = time.time()

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

    def build_track_album_map(
        self,
        on_progress: Callable[[int, int], None] | None = None,
    ) -> dict[str, str]:
        """Browse Library → Albums → tracks to build a title → album mapping.

        Navigates via hierarchy: "browse" (Library → Albums → each album).
        Returns dict: exact_title → album_title.

        Both flat-tracks browse and per-album browse return the same Roon title
        strings, so an exact match works. We avoid LOWER() because SQLite's
        built-in LOWER() only handles ASCII — titles with accented characters
        would never match. setdefault ensures the first album (studio) wins
        over later compilations.
        """
        if not self.is_connected():
            return {}

        result: dict[str, str] = {}
        try:
            with self._browse_lock:
                self._api.browse_browse({"hierarchy": "browse", "pop_all": True})
                root_page = self._api.browse_load({"hierarchy": "browse", "count": 100})
                root_items = root_page.get("items", []) if root_page else []

                library_item = next(
                    (i for i in root_items if "library" in i.get("title", "").lower()),
                    None,
                )
                if not library_item:
                    logger.warning("build_track_album_map: Library not found in browse root")
                    return {}

                self._api.browse_browse(
                    {"hierarchy": "browse", "item_key": library_item["item_key"]}
                )
                lib_page = self._api.browse_load({"hierarchy": "browse", "count": 100})
                lib_items = lib_page.get("items", []) if lib_page else []

                albums_item = next(
                    (i for i in lib_items if "album" in i.get("title", "").lower()),
                    None,
                )
                if not albums_item:
                    logger.warning("build_track_album_map: Albums not found in Library")
                    return {}

                self._api.browse_browse(
                    {"hierarchy": "browse", "item_key": albums_item["item_key"]}
                )
                album_items = self._paginate_browse_load("browse")
                total_albums = len(album_items)
                logger.info("build_track_album_map: %d albums to process", total_albums)

                for idx, album in enumerate(album_items):
                    album_key = album.get("item_key", "")
                    album_title = album.get("title", "")
                    if not album_key:
                        continue

                    try:
                        self._api.browse_browse(
                            {"hierarchy": "browse", "item_key": album_key}
                        )
                        page = self._api.browse_load({"hierarchy": "browse", "count": 500})
                        items = page.get("items", []) if page else []

                        track_items = [
                            i for i in items
                            if i.get("hint") in ("action", "action_list") and i.get("item_key")
                        ]

                        if not track_items:
                            list_items = [
                                i for i in items
                                if i.get("hint") == "list" and i.get("item_key")
                            ]
                            for sub in list_items:
                                self._api.browse_browse(
                                    {"hierarchy": "browse", "item_key": sub["item_key"]}
                                )
                                sub_page = self._api.browse_load(
                                    {"hierarchy": "browse", "count": 500}
                                )
                                sub_items = sub_page.get("items", []) if sub_page else []
                                track_items.extend(
                                    i for i in sub_items
                                    if i.get("hint") in ("action", "action_list")
                                    and i.get("item_key")
                                )
                                if track_items:
                                    break

                        for t in track_items:
                            track_title = (t.get("title") or "").strip()
                            if track_title:
                                # First occurrence wins (studio album before compilations)
                                result.setdefault(track_title, album_title)

                    except Exception as exc:
                        logger.debug(
                            "build_track_album_map: album '%s' failed: %s", album_title, exc
                        )

                    if on_progress:
                        with contextlib.suppress(Exception):
                            on_progress(idx + 1, total_albums)

        except Exception as exc:
            logger.warning("build_track_album_map failed: %s", exc)

        logger.info("build_track_album_map: mapped %d unique titles to albums", len(result))
        return result

    def get_album_track_keys(self, album_item_key: str) -> list[str]:
        """Browse into an album and return its track item_keys."""
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
