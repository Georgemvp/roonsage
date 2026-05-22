"""Async MusicBrainz API client for track metadata enrichment.

MusicBrainz policy:
- Rate limit: 1 request/second (enforced via asyncio.Semaphore + per-request sleep).
- User-Agent required: "AppName/Version (contact_url)" — missing UA → 403.
- All endpoints use JSON format (?fmt=json).
"""

import asyncio
import logging
from typing import Any

import httpx
from rapidfuzz import fuzz
from unidecode import unidecode

logger = logging.getLogger(__name__)

MB_BASE = "https://musicbrainz.org/ws/2"
MB_USER_AGENT = "RoonSage/10.0 (https://github.com/Georgemvp/roonsage)"

# MusicBrainz requires max 1 request/second per their rate-limit policy.
# Semaphore (1 slot) + timestamp-based sleep ensures exactly 1.0 s between
# consecutive requests, even when multiple coroutines share this client.
_mb_semaphore = asyncio.Semaphore(1)
_last_mb_request_time: float = 0.0

# Minimum fuzzy score (0–100) to consider a MusicBrainz match valid.
MB_MATCH_THRESHOLD = 85


def _normalize(text: str) -> str:
    """Lowercase, strip accents, remove common noise for fuzzy comparison."""
    return unidecode(text or "").lower().strip()


def _score_recording(recording: dict, artist: str, title: str) -> float:
    """Score a MusicBrainz recording hit against the query artist + title.

    Returns a combined 0–100 score.  Both halves must individually exceed
    the threshold to accept the match (artist is weighted 40 %, title 60 %).
    """
    mb_title = _normalize(recording.get("title", ""))
    query_title = _normalize(title)
    title_score = fuzz.ratio(query_title, mb_title)

    # MusicBrainz returns artist-credit list; try all credited artists
    credits = recording.get("artist-credit", [])
    artist_names = []
    for credit in credits:
        if isinstance(credit, dict) and "artist" in credit:
            artist_names.append(credit["artist"].get("name", ""))
        elif isinstance(credit, str):
            artist_names.append(credit)

    query_artist = _normalize(artist)
    artist_score = max(
        (fuzz.ratio(query_artist, _normalize(a)) for a in artist_names),
        default=0,
    )

    # Weighted combination — title is a stronger signal
    return 0.4 * artist_score + 0.6 * title_score


class MusicBrainzClient:
    """Lightweight async client for MusicBrainz Web Service v2.

    Usage::

        client = MusicBrainzClient()
        mbid, tags = await client.lookup_recording("Miles Davis", "So What")
        await client.close()

    The client is safe to share across coroutines; the semaphore ensures
    the 1-req/sec rate limit is respected globally.
    """

    def __init__(self) -> None:
        self._http: httpx.AsyncClient | None = None

    def _client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(
                headers={"User-Agent": MB_USER_AGENT},
                timeout=20.0,
            )
        return self._http

    async def close(self) -> None:
        if self._http is not None:
            await self._http.aclose()
            self._http = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def search_recording(
        self,
        artist: str,
        title: str,
    ) -> dict[str, Any] | None:
        """Search MusicBrainz for a recording matching artist + title.

        Returns the best-matching recording dict (raw MB JSON), or None when
        no hit exceeds MB_MATCH_THRESHOLD.
        """
        query = f'artist:"{artist}" recording:"{title}"'
        params = {"query": query, "fmt": "json", "limit": 5}

        data = await self._get("/recording", params=params)
        if not isinstance(data, dict):
            return None

        recordings = data.get("recordings", [])
        if not recordings:
            return None

        # Pick best scoring candidate
        best: dict | None = None
        best_score = 0.0
        for rec in recordings:
            score = _score_recording(rec, artist, title)
            if score > best_score:
                best_score = score
                best = rec

        if best_score < MB_MATCH_THRESHOLD:
            logger.debug(
                "MB: no confident match for '%s - %s' (best score %.0f < %d)",
                artist, title, best_score, MB_MATCH_THRESHOLD,
            )
            return None

        logger.debug(
            "MB: matched '%s - %s' → mbid=%s (score %.0f)",
            artist, title, best.get("id"), best_score,
        )
        return best

    async def get_recording_tags(self, mbid: str) -> list[str]:
        """Fetch tags for a MusicBrainz recording by MBID.

        Returns a list of tag names sorted by vote count (most popular first).
        """
        data = await self._get(f"/recording/{mbid}", params={"inc": "tags", "fmt": "json"})
        if not isinstance(data, dict):
            return []

        raw_tags = data.get("tags", [])
        # Sort by count descending so the most-voted tags come first
        raw_tags.sort(key=lambda t: -t.get("count", 0))
        return [t["name"] for t in raw_tags if t.get("name")]

    async def lookup_recording(
        self,
        artist: str,
        title: str,
        fetch_tags: bool = True,
    ) -> tuple[str | None, list[str], str | None, str | None]:
        """One-stop lookup: search + optional tag fetch.

        Falls back to the primary artist (before the first comma) when the full
        Roon performer string (e.g. "Eagles, Danny Kortchmar") yields no match,
        since MusicBrainz only indexes the main credited artist.

        Pass ``fetch_tags=False`` to skip the second MB request (tag lookup) when
        Last.fm is configured and covers tags — halves the number of MB calls.

        Returns:
            (mbid, tags, release_date, country)
            All fields may be None / [] on failure.
        """
        recording = await self.search_recording(artist, title)

        # Fallback: try primary artist only (before first comma)
        if recording is None and "," in artist:
            primary_artist = artist.split(",")[0].strip()
            recording = await self.search_recording(primary_artist, title)

        if recording is None:
            return None, [], None, None

        mbid: str | None = recording.get("id")
        if not mbid:
            return None, [], None, None

        # Grab release date from the first release in the recording (if present)
        releases = recording.get("releases", [])
        release_date: str | None = None
        country: str | None = None
        if releases:
            first = releases[0]
            release_date = first.get("date") or first.get("release-events", [{}])[0].get("date")
            country = first.get("country")

        if not fetch_tags:
            return mbid, [], release_date, country

        tags = await self.get_recording_tags(mbid)
        return mbid, tags, release_date, country

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _get(self, path: str, params: dict | None = None) -> dict | None:
        """GET a MusicBrainz endpoint, respecting the 1 req/sec rate limit.

        Returns the parsed JSON dict, or None on network / parse error.
        """
        global _last_mb_request_time
        async with _mb_semaphore:
            # Sleep only as long as needed to honour the 1 req/s policy.
            elapsed = asyncio.get_event_loop().time() - _last_mb_request_time
            if elapsed < 1.0:
                await asyncio.sleep(1.0 - elapsed)
            try:
                resp = await self._client().get(f"{MB_BASE}{path}", params=params)
                resp.raise_for_status()
                data = resp.json()
            except httpx.HTTPStatusError as exc:
                logger.warning("MB HTTP %d for %s: %s", exc.response.status_code, path, exc.response.text[:120])
                data = None
            except Exception as exc:
                logger.warning("MB request error for %s: %s", path, exc)
                data = None
            finally:
                _last_mb_request_time = asyncio.get_event_loop().time()

        return data


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_mb_client: MusicBrainzClient | None = None


def get_mb_client() -> MusicBrainzClient:
    """Return the shared MusicBrainzClient instance (created on first call)."""
    global _mb_client
    if _mb_client is None:
        _mb_client = MusicBrainzClient()
    return _mb_client
