"""Last.fm API client for RoonSage.

Handles authentication (token-based OAuth-like flow), scrobbling,
now-playing notifications, and data retrieval (similar artists, tags,
top artists/tracks).  All operations are optional — the client is a
no-op when not configured.

Last.fm API notes
-----------------
- Base URL: https://ws.audioscrobbler.com/2.0/
- Unsigned GET  : api_key only (read-only data endpoints)
- Signed POST   : api_key + api_sig (MD5 of sorted params + secret) + sk
- api_sig param : md5( sorted_concat(params_without_format) + secret )
  where params_without_format means all params except "format".
"""

import hashlib
import logging
from typing import Any

import httpx

logger = logging.getLogger(__name__)

_BASE_URL = "https://ws.audioscrobbler.com/2.0/"
_AUTH_URL = "https://www.last.fm/api/auth/"


class LastFmClient:
    """Async HTTP client wrapping the Last.fm API.

    Only active when api_key + api_secret are configured.  Session key is
    required for write operations (scrobble, now_playing).

    All methods return safe defaults (None / empty list / False) when
    unconfigured or on HTTP errors.
    """

    def __init__(
        self,
        api_key: str | None,
        api_secret: str | None,
        session_key: str | None = None,
        username: str | None = None,
    ) -> None:
        self._api_key = api_key or ""
        self._api_secret = api_secret or ""
        self._session_key = session_key or ""
        self._username = username or ""
        self._client: httpx.AsyncClient | None = None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=30.0)
        return self._client

    async def close(self) -> None:
        """Close the underlying HTTP client."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    def _sign(self, params: dict[str, str]) -> str:
        """Generate Last.fm API signature (MD5 of sorted params + secret).

        The signature is computed over all parameters *except* "format".
        Params must be str→str (numeric values converted by the caller).
        """
        # Sort keys alphabetically, concatenate key+value pairs
        sig_str = "".join(
            f"{k}{v}"
            for k, v in sorted(params.items())
            if k != "format"
        )
        sig_str += self._api_secret
        return hashlib.md5(sig_str.encode("utf-8")).hexdigest()

    def _base_params(self) -> dict[str, str]:
        """Return common unsigned params."""
        return {"api_key": self._api_key, "format": "json"}

    def _signed_params(self, method: str, extra: dict[str, str] | None = None) -> dict[str, str]:
        """Build a signed param dict for write/auth operations."""
        params: dict[str, str] = {
            "method":  method,
            "api_key": self._api_key,
            "format":  "json",
        }
        if extra:
            params.update(extra)
        if self._session_key:
            params["sk"] = self._session_key
        # Sign without "format"
        params["api_sig"] = self._sign({k: v for k, v in params.items() if k != "format"})
        return params

    async def _get(self, params: dict[str, str]) -> Any:
        """Perform a GET request to the Last.fm API."""
        if not self._api_key:
            return None
        try:
            resp = await self._get_client().get(_BASE_URL, params=params)
            resp.raise_for_status()
            data = resp.json()
            if "error" in data:
                logger.warning(
                    "Last.fm GET error %s: %s",
                    data.get("error"),
                    data.get("message", ""),
                )
                return None
            return data
        except httpx.HTTPStatusError as exc:
            logger.warning("Last.fm GET HTTP %s: %s", exc.response.status_code, exc.request.url)
        except Exception as exc:
            logger.warning("Last.fm GET failed: %s", exc)
        return None

    async def _post(self, params: dict[str, str]) -> Any:
        """Perform a POST request to the Last.fm API."""
        if not self._api_key or not self._api_secret:
            return None
        try:
            resp = await self._get_client().post(_BASE_URL, data=params)
            resp.raise_for_status()
            data = resp.json()
            if "error" in data:
                logger.warning(
                    "Last.fm POST error %s: %s",
                    data.get("error"),
                    data.get("message", ""),
                )
                return None
            return data
        except httpx.HTTPStatusError as exc:
            logger.warning("Last.fm POST HTTP %s: %s", exc.response.status_code, exc.request.url)
        except Exception as exc:
            logger.warning("Last.fm POST failed: %s", exc)
        return None

    # ------------------------------------------------------------------
    # Configuration helpers
    # ------------------------------------------------------------------

    def is_configured(self) -> bool:
        """Return True when api_key + api_secret are both set."""
        return bool(self._api_key and self._api_secret)

    def can_scrobble(self) -> bool:
        """Return True when scrobbling is possible (has key, secret, and session)."""
        return bool(self._api_key and self._api_secret and self._session_key)

    def update_session_key(self, session_key: str) -> None:
        """Update the session key (called after successful auth)."""
        self._session_key = session_key

    def update_username(self, username: str) -> None:
        """Update the stored username."""
        self._username = username

    def get_auth_url(self, token: str) -> str:
        """Return the Last.fm URL the user must open to authorise the token."""
        return f"{_AUTH_URL}?api_key={self._api_key}&token={token}"

    # ------------------------------------------------------------------
    # Auth flow
    # ------------------------------------------------------------------

    async def get_auth_token(self) -> str | None:
        """Request a temporary auth token (auth.getToken).

        Returns the token string, or None on failure.
        The caller must direct the user to ``get_auth_url(token)`` to
        authorise the token in a browser.
        """
        params: dict[str, str] = {
            "method":  "auth.getToken",
            "api_key": self._api_key,
            "format":  "json",
        }
        params["api_sig"] = self._sign({k: v for k, v in params.items() if k != "format"})
        data = await self._post(params)
        if data is None:
            return None
        return data.get("token")

    async def get_session(self, token: str) -> dict | None:
        """Exchange an authorised token for a permanent session key (auth.getSession).

        Args:
            token: The temporary token the user already authorised.

        Returns:
            Dict with keys ``name`` (username) and ``key`` (session key),
            or None on failure.
        """
        params: dict[str, str] = {
            "method":  "auth.getSession",
            "api_key": self._api_key,
            "token":   token,
            "format":  "json",
        }
        params["api_sig"] = self._sign({k: v for k, v in params.items() if k != "format"})
        data = await self._post(params)
        if data is None:
            return None
        session = data.get("session")
        if not session:
            return None
        return {
            "name": session.get("name", ""),
            "key":  session.get("key", ""),
        }

    # ------------------------------------------------------------------
    # Scrobbling
    # ------------------------------------------------------------------

    async def update_now_playing(
        self,
        artist: str,
        track: str,
        album: str = "",
        duration: int = 0,
    ) -> bool:
        """Notify Last.fm of a now-playing track (track.updateNowPlaying).

        Returns True on success.
        """
        if not self.can_scrobble():
            return False
        extra: dict[str, str] = {
            "artist": artist,
            "track":  track,
        }
        if album:
            extra["album"] = album
        if duration > 0:
            extra["duration"] = str(duration)

        data = await self._post(self._signed_params("track.updateNowPlaying", extra))
        return data is not None and "nowplaying" in data

    async def scrobble(
        self,
        artist: str,
        track: str,
        timestamp: int,
        album: str = "",
        duration: int = 0,
    ) -> bool:
        """Submit a single scrobble (track.scrobble).

        Args:
            artist:    Artist name.
            track:     Track title.
            timestamp: Unix timestamp when playback started.
            album:     Album name (optional).
            duration:  Track duration in seconds (optional).

        Returns:
            True on success.
        """
        if not self.can_scrobble():
            return False
        extra: dict[str, str] = {
            "artist":    artist,
            "track":     track,
            "timestamp": str(timestamp),
        }
        if album:
            extra["album"] = album
        if duration > 0:
            extra["duration"] = str(duration)

        data = await self._post(self._signed_params("track.scrobble", extra))
        if data is None:
            return False
        scrobbles = data.get("scrobbles", {})
        attr = scrobbles.get("@attr", {})
        return int(attr.get("accepted", 0)) > 0

    # ------------------------------------------------------------------
    # Data retrieval
    # ------------------------------------------------------------------

    async def get_similar_artists(
        self, artist: str, limit: int = 20
    ) -> list[dict]:
        """Return similar artists via artist.getSimilar.

        Returns a list of dicts with keys: name, match (similarity 0–1),
        url, mbid.
        """
        if not self._api_key:
            return []
        params = {
            **self._base_params(),
            "method": "artist.getSimilar",
            "artist": artist,
            "limit":  str(limit),
            "autocorrect": "1",
        }
        data = await self._get(params)
        if data is None:
            return []
        similar = data.get("similarartists", {}).get("artist", [])
        if isinstance(similar, dict):
            similar = [similar]
        return [
            {
                "name":  a.get("name", ""),
                "match": float(a.get("match", 0)),
                "mbid":  a.get("mbid", ""),
                "url":   a.get("url", ""),
            }
            for a in similar
            if a.get("name")
        ]

    async def get_artist_tags(self, artist: str) -> list[dict]:
        """Return top tags for an artist via artist.getTopTags.

        Returns a list of dicts with keys: name, count.
        """
        if not self._api_key:
            return []
        params = {
            **self._base_params(),
            "method": "artist.getTopTags",
            "artist": artist,
            "autocorrect": "1",
        }
        data = await self._get(params)
        if data is None:
            return []
        tags = data.get("toptags", {}).get("tag", [])
        if isinstance(tags, dict):
            tags = [tags]
        return [
            {"name": t.get("name", ""), "count": int(t.get("count", 0))}
            for t in tags
            if t.get("name")
        ][:20]

    async def get_user_top_artists(
        self, period: str = "3month", limit: int = 50
    ) -> list[dict]:
        """Return the user's top artists via user.getTopArtists.

        Args:
            period: overall | 7day | 1month | 3month | 6month | 12month
            limit:  Number of results (max 1000).

        Returns:
            List of dicts with keys: name, playcount, rank, mbid.
        """
        if not self._api_key or not self._username:
            return []
        params = {
            **self._base_params(),
            "method": "user.getTopArtists",
            "user":   self._username,
            "period": period,
            "limit":  str(limit),
        }
        data = await self._get(params)
        if data is None:
            return []
        artists = data.get("topartists", {}).get("artist", [])
        if isinstance(artists, dict):
            artists = [artists]
        return [
            {
                "name":      a.get("name", ""),
                "playcount": int(a.get("playcount", 0)),
                "rank":      int(a.get("@attr", {}).get("rank", 0)),
                "mbid":      a.get("mbid", ""),
            }
            for a in artists
            if a.get("name")
        ]

    async def get_user_top_tracks(
        self, period: str = "3month", limit: int = 50
    ) -> list[dict]:
        """Return the user's top tracks via user.getTopTracks.

        Args:
            period: overall | 7day | 1month | 3month | 6month | 12month
            limit:  Number of results (max 1000).

        Returns:
            List of dicts with keys: name, artist, playcount, rank, mbid.
        """
        if not self._api_key or not self._username:
            return []
        params = {
            **self._base_params(),
            "method": "user.getTopTracks",
            "user":   self._username,
            "period": period,
            "limit":  str(limit),
        }
        data = await self._get(params)
        if data is None:
            return []
        tracks = data.get("toptracks", {}).get("track", [])
        if isinstance(tracks, dict):
            tracks = [tracks]
        return [
            {
                "name":      t.get("name", ""),
                "artist":    t.get("artist", {}).get("name", "") if isinstance(t.get("artist"), dict) else str(t.get("artist", "")),
                "playcount": int(t.get("playcount", 0)),
                "rank":      int(t.get("@attr", {}).get("rank", 0)),
                "mbid":      t.get("mbid", ""),
            }
            for t in tracks
            if t.get("name")
        ]

    async def get_track_info(
        self,
        artist: str,
        title: str,
        username: str | None = None,
    ) -> dict | None:
        """Fetch track metadata from Last.fm (track.getInfo).

        Returns the raw "track" dict from Last.fm, or None on failure.
        Includes listeners, playcount, and top tags.
        """
        params: dict[str, str] = {
            **self._base_params(),
            "method": "track.getInfo",
            "artist": artist,
            "track": title,
            "autocorrect": "1",
        }
        if username or self._username:
            params["username"] = username or self._username
        data = await self._get(params)
        if data is None:
            return None
        return data.get("track")

    async def validate(self) -> dict:
        """Check that the credentials are valid.

        Tries to fetch user info (user.getInfo).  Returns
        ``{"valid": bool, "username": str, "message": str}``.
        """
        if not self._api_key:
            return {"valid": False, "username": "", "message": "API key not set"}
        username = self._username or ""
        if not username:
            return {"valid": False, "username": "", "message": "Username not set"}
        params = {
            **self._base_params(),
            "method": "user.getInfo",
            "user":   username,
        }
        data = await self._get(params)
        if data is None:
            return {"valid": False, "username": "", "message": "Request failed or invalid credentials"}
        user = data.get("user", {})
        name = user.get("name", "")
        if name:
            return {"valid": True, "username": name, "message": "OK"}
        return {"valid": False, "username": "", "message": "User not found"}


# ---------------------------------------------------------------------------
# Module-level singleton (initialised in main.py)
# ---------------------------------------------------------------------------

_lf_client: LastFmClient | None = None


def get_lf_client() -> LastFmClient | None:
    """Return the module-level Last.fm client, or None if not configured."""
    return _lf_client


def init_lf_client(
    api_key: str,
    api_secret: str,
    session_key: str = "",
    username: str = "",
) -> LastFmClient:
    """Initialise the module-level client. Called from main.py lifespan."""
    global _lf_client
    _lf_client = LastFmClient(
        api_key=api_key,
        api_secret=api_secret,
        session_key=session_key,
        username=username,
    )
    return _lf_client
