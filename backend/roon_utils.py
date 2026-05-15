"""Utility functions, constants, and TrackCache for RoonSage."""

import asyncio
import hashlib
import logging
import re
import time
from functools import wraps
from typing import Any

from unidecode import unidecode

from backend.models import Track

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FUZZ_THRESHOLD = 60
DATE_PATTERN = r"\d{4}[-/]\d{2}[-/]\d{2}"
LIVE_KEYWORDS = r"\b(?:live|concert|sbd|bootleg)\b"


# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------


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
# Decorator
# ---------------------------------------------------------------------------


def run_in_thread(func):
    """Decorator that runs a sync function in asyncio's default thread pool."""
    @wraps(func)
    async def wrapper(*args, **kwargs):
        return await asyncio.to_thread(func, *args, **kwargs)
    return wrapper


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
        max_tracks: int = 0,
    ) -> str:
        key_data = {
            "genres": sorted(genres or []),
            "decades": sorted(decades or []),
            "exclude_live": exclude_live,
            "max_tracks": max_tracks,
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
        max_tracks: int = 0,
    ) -> list[Track] | None:
        key = self._make_key(genres, decades, exclude_live, max_tracks)
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
        max_tracks: int = 0,
        tracks: list[Track] = (),  # type: ignore[assignment]
    ) -> None:
        key = self._make_key(genres, decades, exclude_live, max_tracks)
        if key not in self._cache and len(self._cache) >= self._max_entries:
            self._evict_oldest()
        self._cache[key] = (list(tracks), time.time())
        logger.info("Cached %d tracks (key=%s)", len(list(tracks)), key[:8])

    def clear(self) -> None:
        self._cache.clear()
        logger.info("Track cache cleared")


_track_cache = TrackCache()


def get_track_cache() -> TrackCache:
    return _track_cache


# ---------------------------------------------------------------------------
# Exception
# ---------------------------------------------------------------------------


class RoonQueryError(Exception):
    """Raised when a Roon library query fails."""
