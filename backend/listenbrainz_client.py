"""ListenBrainz API client for RoonSage.

Handles scrobbling, stats retrieval, feedback, and social features.
All operations are optional — the client is a no-op when no token is configured.
"""

import asyncio
import logging
import time
from typing import Any

import httpx

logger = logging.getLogger(__name__)


class ListenBrainzClient:
    """Async HTTP client wrapping the ListenBrainz API.

    Only active when a token is configured. All methods return safe defaults
    (None / empty list / False) when unconfigured or on HTTP errors.
    """

    BASE_URL = "https://api.listenbrainz.org"

    def __init__(self, token: str | None, username: str | None) -> None:
        self._token = token or ""
        self._username = username or ""
        self._client: httpx.AsyncClient | None = None
        # Rate limit state from response headers
        self._rl_remaining: int = 999
        self._rl_reset_at: float = 0.0

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(
                timeout=30.0,
                headers={"Authorization": f"Token {self._token}"},
            )
        return self._client

    async def close(self) -> None:
        """Close the underlying HTTP client."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    def _update_rate_limit(self, headers: httpx.Headers) -> None:
        """Parse X-RateLimit-* headers and update internal state."""
        try:
            remaining = headers.get("X-RateLimit-Remaining")
            reset_in = headers.get("X-RateLimit-Reset-In")
            if remaining is not None:
                self._rl_remaining = int(remaining)
            if reset_in is not None:
                self._rl_reset_at = time.monotonic() + int(reset_in)
        except (ValueError, TypeError):
            pass

    async def _wait_for_rate_limit(self) -> None:
        """Sleep if rate limit is exhausted."""
        if self._rl_remaining == 0:
            wait = self._rl_reset_at - time.monotonic()
            if wait > 0:
                logger.info("ListenBrainz rate limit hit — waiting %.1fs", wait)
                await asyncio.sleep(wait + 0.5)

    async def _get(self, path: str, params: dict | None = None) -> Any:
        """Perform a GET request. Returns parsed JSON or None on error."""
        if not self._token:
            return None
        await self._wait_for_rate_limit()
        try:
            resp = await self._get_client().get(
                f"{self.BASE_URL}{path}", params=params
            )
            self._update_rate_limit(resp.headers)
            resp.raise_for_status()
            return resp.json()
        except httpx.HTTPStatusError as exc:
            logger.warning("ListenBrainz GET %s → HTTP %s", path, exc.response.status_code)
        except Exception as exc:
            logger.warning("ListenBrainz GET %s failed: %s", path, exc)
        return None

    async def _post(self, path: str, payload: dict) -> Any:
        """Perform a POST request. Returns parsed JSON or None on error."""
        if not self._token:
            return None
        await self._wait_for_rate_limit()
        try:
            resp = await self._get_client().post(
                f"{self.BASE_URL}{path}", json=payload
            )
            self._update_rate_limit(resp.headers)
            resp.raise_for_status()
            return resp.json()
        except httpx.HTTPStatusError as exc:
            logger.warning("ListenBrainz POST %s → HTTP %s", path, exc.response.status_code)
        except Exception as exc:
            logger.warning("ListenBrainz POST %s failed: %s", path, exc)
        return None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def is_configured(self) -> bool:
        """Return True when a token is set."""
        return bool(self._token)

    async def validate_token(self) -> dict:
        """Validate the stored token via GET /1/validate-token.

        Returns: {"valid": bool, "user_name": str, "message": str}
        """
        result = await self._get("/1/validate-token")
        if result is None:
            return {"valid": False, "user_name": "", "message": "Request failed"}
        return {
            "valid": result.get("valid", False),
            "user_name": result.get("user_name", ""),
            "message": result.get("message", ""),
        }

    # ── Scrobbling ──────────────────────────────────────────────────────

    async def submit_listen(
        self,
        artist: str,
        title: str,
        album: str,
        duration_ms: int,
        listened_at: int,
    ) -> bool:
        """Submit a single completed listen (POST /1/submit-listens).

        Args:
            artist:      Track artist name.
            title:       Track title.
            album:       Album name.
            duration_ms: Track duration in milliseconds.
            listened_at: Unix timestamp of when the track finished.

        Returns:
            True on success, False on failure.
        """
        track_meta: dict[str, Any] = {
            "artist_name": artist,
            "track_name": title,
        }
        if album:
            track_meta["release_name"] = album
        if duration_ms > 0:
            track_meta["duration_ms"] = duration_ms

        payload = {
            "listen_type": "single",
            "payload": [
                {
                    "listened_at": listened_at,
                    "track_metadata": track_meta,
                }
            ],
        }
        result = await self._post("/1/submit-listens", payload)
        return result is not None and result.get("status") == "ok"

    async def submit_now_playing(self, artist: str, title: str, album: str) -> bool:
        """Submit a "playing_now" notification (POST /1/submit-listens).

        Returns True on success.
        """
        track_meta: dict[str, Any] = {"artist_name": artist, "track_name": title}
        if album:
            track_meta["release_name"] = album

        payload = {
            "listen_type": "playing_now",
            "payload": [{"track_metadata": track_meta}],
        }
        result = await self._post("/1/submit-listens", payload)
        return result is not None and result.get("status") == "ok"

    # ── Feedback ────────────────────────────────────────────────────────

    async def submit_feedback(self, recording_msid: str, score: int) -> bool:
        """Submit love (+1) or hate (-1) feedback for a recording.

        Args:
            recording_msid: ListenBrainz MessyBrainz ID for the recording.
            score:          +1 (love) or -1 (hate).

        Returns:
            True on success.
        """
        result = await self._post(
            "/1/feedback/recording-feedback",
            {"recording_msid": recording_msid, "score": score},
        )
        return result is not None and result.get("status") == "ok"

    async def get_user_feedback(self, score: int | None = None) -> list[dict]:
        """Return the user's recording feedback list.

        Args:
            score: Filter by +1 (loved) or -1 (hated). None returns all.

        Returns:
            List of feedback dicts with keys: recording_msid, score, created, track_metadata.
        """
        if not self._username:
            return []
        params: dict[str, Any] = {"count": 200}
        if score is not None:
            params["score"] = score
        result = await self._get(
            f"/1/feedback/user/{self._username}/get-feedback", params=params
        )
        if result is None:
            return []
        return result.get("feedback", [])

    # ── Statistics ──────────────────────────────────────────────────────

    async def get_top_artists(
        self, range: str = "all_time", count: int = 25
    ) -> dict:
        """Return top artists for the user.

        Args:
            range: One of: this_week, this_month, this_year, week, month,
                   quarter, year, half_yearly, all_time.
            count: Number of results.

        Returns:
            Raw LB response dict (artists list under payload.artists).
        """
        if not self._username:
            return {}
        result = await self._get(
            f"/1/stats/user/{self._username}/artists",
            params={"range": range, "count": count},
        )
        return result or {}

    async def get_top_recordings(
        self, range: str = "all_time", count: int = 25
    ) -> dict:
        """Return top recordings (tracks) for the user."""
        if not self._username:
            return {}
        result = await self._get(
            f"/1/stats/user/{self._username}/recordings",
            params={"range": range, "count": count},
        )
        return result or {}

    async def get_top_releases(
        self, range: str = "all_time", count: int = 25
    ) -> dict:
        """Return top releases (albums) for the user."""
        if not self._username:
            return {}
        result = await self._get(
            f"/1/stats/user/{self._username}/releases",
            params={"range": range, "count": count},
        )
        return result or {}

    async def get_genre_activity(self) -> list[dict]:
        """Return genre-by-hour activity for the user.

        Returns list of {genre, hour_of_day, listen_count} dicts.
        """
        if not self._username:
            return []
        # LB genre-activity endpoint may not be available on all versions.
        # Try the actual genre-activity endpoint first:
        genre_result = await self._get(
            f"/1/stats/user/{self._username}/genre-activity",
        )
        if genre_result:
            return genre_result.get("payload", {}).get("genre_activity", [])
        return []

    async def get_daily_activity(self, range: str = "all_time") -> dict:
        """Return daily listening activity heatmap (day × hour).

        Returns dict with payload.daily_activity (list of day/hour/listen_count).
        """
        if not self._username:
            return {}
        result = await self._get(
            f"/1/stats/user/{self._username}/daily-activity",
            params={"range": range},
        )
        return result or {}

    async def get_era_activity(self, range: str = "all_time") -> list[dict]:
        """Return listening activity per release year (era distribution).

        Returns list of {year, listen_count} dicts.
        """
        if not self._username:
            return []
        result = await self._get(
            f"/1/stats/user/{self._username}/year-in-music",
        )
        if result:
            return result.get("payload", {}).get("top_releases_coverart", [])
        # Fallback: recordings with year data
        recs = await self._get(
            f"/1/stats/user/{self._username}/recordings",
            params={"range": range, "count": 100},
        )
        if recs:
            items = recs.get("payload", {}).get("recordings", [])
            year_counts: dict[int, int] = {}
            for item in items:
                year = item.get("release_year")
                if year:
                    year_counts[year] = year_counts.get(year, 0) + item.get("listen_count", 1)
            return [{"year": y, "listen_count": c} for y, c in sorted(year_counts.items())]
        return []

    async def get_artist_map(self, range: str = "all_time") -> list[dict]:
        """Return listening activity mapped to artist countries.

        Returns list of {country, artist_count, listen_count} dicts.
        """
        if not self._username:
            return []
        result = await self._get(
            f"/1/stats/user/{self._username}/artist-map",
            params={"range": range},
        )
        if result is None:
            return []
        return result.get("payload", {}).get("artist_map", [])

    async def get_listening_activity(self, range: str = "all_time") -> list[dict]:
        """Return listening activity over time.

        Returns list of {from_ts, to_ts, listen_count} dicts.
        """
        if not self._username:
            return []
        result = await self._get(
            f"/1/stats/user/{self._username}/listening-activity",
            params={"range": range},
        )
        if result is None:
            return []
        return result.get("payload", {}).get("listening_activity", [])

    # ── Social ──────────────────────────────────────────────────────────

    async def get_similar_users(self) -> list[dict]:
        """Return users with similar music taste.

        Returns list of {user_name, similarity} dicts.
        """
        if not self._username:
            return []
        result = await self._get(f"/1/user/{self._username}/similar-users")
        if result is None:
            return []
        return result.get("payload", [])

    async def get_playlists_created_for(self) -> list[dict]:
        """Return LB-generated "created for you" playlists.

        Returns list of playlist dicts with identifier, title, tracks, etc.
        """
        if not self._username:
            return []
        result = await self._get(
            f"/1/user/{self._username}/playlists/createdfor",
        )
        if result is None:
            return []
        return result.get("playlists", [])


# ---------------------------------------------------------------------------
# Module-level singleton (initialised in main.py)
# ---------------------------------------------------------------------------

_lb_client: ListenBrainzClient | None = None


def get_lb_client() -> ListenBrainzClient | None:
    """Return the module-level ListenBrainz client, or None if not configured."""
    return _lb_client


def init_lb_client(token: str, username: str) -> ListenBrainzClient:
    """Initialise the module-level client. Called from main.py lifespan."""
    global _lb_client
    _lb_client = ListenBrainzClient(token=token, username=username)
    return _lb_client
