"""Search and track conversion mixin for RoonSage."""

import logging
import random
from typing import Any

from backend.models import Track
from backend.roon_utils import is_live_version

logger = logging.getLogger(__name__)


class RoonSearchMixin:
    """Mixin providing track search and conversion methods."""

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

                for item in top_items:
                    if (item.get("hint") == "action"
                            and item.get("item_key")):
                        track = self._convert_track(item, {})
                        if track:
                            tracks.append(track)

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

    def _convert_track(
        self, roon_item: dict[str, Any], album_info: dict[str, Any]
    ) -> Track | None:
        """Convert a Roon browse item dict to our Track model."""
        item_key = roon_item.get("item_key", "")
        title = roon_item.get("title", "Unknown Track")
        subtitle = roon_item.get("subtitle", "") or ""

        parts = [p.strip() for p in subtitle.split("•")]
        artist = parts[0] if parts else "Unknown Artist"
        album = parts[1] if len(parts) > 1 else album_info.get("title", "Unknown Album")

        if not artist or artist == "Unknown Artist":
            artist = album_info.get("artist", "Unknown Artist")

        genres = album_info.get("genres", [])
        year = album_info.get("year")

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
        """Get a random sample of tracks from the library."""
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
        album_meta = self.get_all_albums_metadata()
        all_tracks = self.get_all_raw_tracks()

        results = []
        for item in all_tracks:
            album_key_val = item.get("_album_item_key", "")
            meta = album_meta.get(album_key_val, {})
            item_genres = meta.get("genres", [])
            item_year = meta.get("year")

            if genres and not any(g.lower() in [x.lower() for x in item_genres] for g in genres):
                continue
            if decades and item_year:
                decade = f"{(item_year // 10) * 10}s"
                if decade not in decades:
                    continue
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
