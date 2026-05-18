"""Direct Qobuz API client for playlist management.

Provides authentication, track search, playlist creation, track addition,
favorites management, playlist CRUD, and new release browsing via Qobuz's
JSON API. Independent of Roon — uses the user's own Qobuz credentials.

Only app_id is extracted from the Qobuz web player — app_secret is NOT
needed for playlist management, track search, or login operations.
"""

import hashlib
import logging
import re
import time
from typing import Any

import httpx

logger = logging.getLogger(__name__)

QOBUZ_API_BASE = "https://www.qobuz.com/api.json/0.2"
QOBUZ_PLAY_URL = "https://play.qobuz.com"

_BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.2.1 Safari/605.1.15"
)

# Known working app_ids from established third-party Qobuz tools.
# These are tried in order during login. The web player's current app_id
# often requires a different auth flow (PKCE/OAuth) that doesn't work
# with simple GET user/login.
_KNOWN_APP_IDS = [
    "950096963",   # Used by QobuzDownloaderX-MOD, widely tested
    "579939560",   # Used across multiple regions (JP, NZ, UK, CA)
    "942852567",   # Used by LMS Qobuz plugin
]


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class QobuzAPIError(Exception):
    """Raised when a Qobuz API call fails."""


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

class QobuzClient:
    """Client for the Qobuz JSON API (playlist management).

    Authenticates once on construction. All subsequent API calls include
    X-App-Id and X-User-Auth-Token headers via the persistent httpx client.

    app_secret is NOT required — only app_id is extracted from the web player.
    The endpoints used (user/login, track/search, playlist/create,
    playlist/addTracks) do not require request signing.
    """

    def __init__(self, email: str, password: str):
        self._token: str | None = None
        self._user_id: int | None = None
        self._user_display_name: str | None = None
        self._subscription: str | None = None

        # API client — no redirects (API calls should not redirect)
        self._client = httpx.Client(
            timeout=20.0,
            follow_redirects=False,
            headers={"User-Agent": _BROWSER_UA},
        )

        # Scrape client — follows redirects (needed for web player pages)
        self._scrape_client = httpx.Client(
            timeout=20.0,
            follow_redirects=True,
            headers={"User-Agent": _BROWSER_UA},
        )

        # app_id is resolved during _login (known list first, then extracted)
        self.app_id: str | None = None
        self._login(email, password)

        # Close scrape client — only needed during init
        self._scrape_client.close()

    # ------------------------------------------------------------------
    # Credential extraction
    # ------------------------------------------------------------------

    def _extract_app_id(self) -> str | None:
        """Extract the current app_id from the Qobuz web player bundle.

        Only the app_id is needed — app_secret is NOT required for
        playlist management and search operations.
        """
        try:
            logger.info("Extracting Qobuz app_id from web player...")

            # Use scrape client (follows redirects) for web player pages
            resp = self._scrape_client.get(
                f"{QOBUZ_PLAY_URL}/login",
                headers={"User-Agent": _BROWSER_UA},
            )
            resp.raise_for_status()

            # Find bundle.js URL
            bundle_match = re.search(
                r'<script[^>]+src="(/resources/\d+\.\d+\.\d+-[a-z]\d+/bundle\.js)"',
                resp.text,
            )
            if not bundle_match:
                bundle_match = re.search(r'"(/resources/[^"]*bundle[^"]*\.js)"', resp.text)

            if not bundle_match:
                logger.error("Could not find bundle.js URL in Qobuz login page")
                return None

            bundle_url = f"{QOBUZ_PLAY_URL}{bundle_match.group(1)}"
            logger.info("Found bundle URL: %s", bundle_url)

            bundle_resp = self._scrape_client.get(bundle_url)
            bundle_resp.raise_for_status()

            # Extract app_id — try multiple patterns
            for pattern in [
                r'production:\{api:\{appId:"(\d{9})"',
                r'app_id\s*[:=]\s*"(\d{9})"',
                r'"app_id"\s*:\s*"(\d{9})"',
                r'appId\s*[:=]\s*"(\d{9})"',
            ]:
                match = re.search(pattern, bundle_resp.text)
                if match:
                    app_id = match.group(1)
                    logger.info("Extracted Qobuz app_id: %s", app_id)
                    return app_id

            logger.error("Could not extract app_id from Qobuz bundle")
            return None

        except Exception as exc:
            logger.error("Qobuz app_id extraction failed: %s", exc)
            return None

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    def _login(self, email: str, password: str) -> None:
        """Login to Qobuz API.

        Tries known working app_ids first, then falls back to extracting
        from the web player. For each app_id, tries both plain-text and
        MD5-hashed password.

        Does NOT use X-App-Id header during login — only app_id query param.
        Sets X-App-Id and X-User-Auth-Token headers AFTER successful login.
        """
        # Known app_ids first, then extracted from web player as fallback
        app_ids_to_try = list(_KNOWN_APP_IDS)
        extracted = self._extract_app_id()
        if extracted and extracted not in app_ids_to_try:
            app_ids_to_try.append(extracted)

        password_md5 = hashlib.md5(password.encode("utf-8")).hexdigest()

        last_error = ""
        for app_id in app_ids_to_try:
            for pw_label, pw in [("plain", password), ("md5", password_md5)]:
                try:
                    resp = self._client.get(
                        f"{QOBUZ_API_BASE}/user/login",
                        params={
                            "email": email,
                            "password": pw,
                            "app_id": app_id,
                        },
                    )

                    if resp.status_code == 200:
                        data = resp.json()
                        token = data.get("user_auth_token")
                        if not token:
                            last_error = "Geen auth token in response"
                            continue

                        self.app_id = app_id
                        self._token = token
                        self._user_id = data["user"]["id"]
                        self._user_display_name = data["user"].get("display_name", email)
                        self._subscription = data["user"].get("credential", {}).get("label", "Onbekend")

                        # Set persistent headers for all future API calls
                        self._client.headers["X-App-Id"] = app_id
                        self._client.headers["X-User-Auth-Token"] = self._token

                        logger.info(
                            "Qobuz login geslaagd (app_id=%s, pw=%s): %s (%s)",
                            app_id, pw_label,
                            self._user_display_name, self._subscription,
                        )
                        return

                    # Parse error message
                    try:
                        msg = resp.json().get("message", f"HTTP {resp.status_code}")
                    except Exception:
                        msg = f"HTTP {resp.status_code}"

                    # "Invalid or missing app_id" → skip to next app_id
                    if "app_id" in msg.lower():
                        logger.debug("app_id %s rejected: %s", app_id, msg)
                        break  # No point trying MD5 with same invalid app_id

                    # "User authentication is required" → different auth flow needed
                    if "authentication is required" in msg.lower():
                        logger.debug("app_id %s requires different auth flow, skipping", app_id)
                        break  # Skip to next app_id

                    last_error = msg
                    logger.debug("Login failed (app_id=%s, pw=%s): %s", app_id, pw_label, msg)

                except Exception as exc:
                    last_error = str(exc)
                    logger.debug("Login exception (app_id=%s, pw=%s): %s", app_id, pw_label, exc)

        raise QobuzAPIError(f"Qobuz login mislukt: {last_error}")

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------

    def is_authenticated(self) -> bool:
        return self._token is not None

    @property
    def user_display(self) -> str:
        return self._user_display_name or ""

    @property
    def subscription(self) -> str:
        return self._subscription or ""

    # ------------------------------------------------------------------
    # API methods
    # ------------------------------------------------------------------

    def search_track(self, query: str, limit: int = 5) -> list[dict[str, Any]]:
        """Search the Qobuz catalog for tracks."""
        try:
            resp = self._client.get(
                f"{QOBUZ_API_BASE}/track/search",
                params={"query": query, "limit": limit},
            )
            resp.raise_for_status()
            return resp.json().get("tracks", {}).get("items", [])
        except Exception as exc:
            logger.warning("Qobuz track search failed for '%s': %s", query, exc)
            return []

    def create_playlist(
        self,
        name: str,
        description: str = "",
        is_public: bool = False,
    ) -> dict[str, Any]:
        """Create a new playlist on Qobuz. Returns the playlist dict with 'id'."""
        resp = self._client.post(
            f"{QOBUZ_API_BASE}/playlist/create",
            data={
                "name": name,
                "description": description,
                "is_public": str(is_public).lower(),
            },
        )
        resp.raise_for_status()
        data = resp.json()
        logger.info("Qobuz playlist created: '%s' (id=%s)", name, data.get("id"))
        return data

    def add_tracks_to_playlist(
        self,
        playlist_id: int,
        track_ids: list[int],
    ) -> dict[str, Any]:
        """Add tracks to an existing Qobuz playlist by track IDs."""
        if not track_ids:
            return {"status": "ok", "tracks_added": 0}
        ids_csv = ",".join(str(tid) for tid in track_ids)
        resp = self._client.post(
            f"{QOBUZ_API_BASE}/playlist/addTracks",
            data={
                "playlist_id": playlist_id,
                "track_ids": ids_csv,
            },
        )
        resp.raise_for_status()
        return resp.json()

    def resolve_tracks(
        self,
        tracks: list[dict[str, str]],
    ) -> dict[str, list[dict]]:
        """Resolve artist+title pairs to Qobuz track IDs via search + fuzzy matching.

        Args:
            tracks: List of {"artist": "...", "title": "..."} dicts.

        Returns:
            {"matched": [...], "unmatched": [...]}
        """
        from rapidfuzz import fuzz

        matched: list[dict] = []
        unmatched: list[dict] = []

        for track in tracks:
            artist = track.get("artist", "")
            title = track.get("title", "")
            query = f"{artist} {title}" if artist else title

            results = self.search_track(query, limit=5)

            best_result: dict | None = None
            best_score: float = 0.0

            for result in results:
                result_title = result.get("title", "")
                result_artist = (
                    result.get("performer", {}).get("name", "")
                    or result.get("artist", {}).get("name", "")
                )
                title_score = fuzz.ratio(title.lower(), result_title.lower())
                artist_score = (
                    fuzz.partial_ratio(artist.lower(), result_artist.lower())
                    if artist
                    else 100.0
                )
                score = title_score * 0.6 + artist_score * 0.4

                if score > best_score:
                    best_score = score
                    best_result = result

            if best_result and best_score >= 60:
                matched.append({
                    "artist": artist,
                    "title": title,
                    "qobuz_id": best_result["id"],
                    "qobuz_title": best_result.get("title", ""),
                })
            else:
                unmatched.append({
                    "artist": artist,
                    "title": title,
                    "reason": (
                        f"best_score={best_score:.0f}" if best_result else "no_results"
                    ),
                })

            # Rate-limit to be conservative — Qobuz doesn't document limits
            time.sleep(0.15)

        logger.info(
            "Qobuz resolve: %d matched, %d unmatched out of %d tracks",
            len(matched),
            len(unmatched),
            len(tracks),
        )
        return {"matched": matched, "unmatched": unmatched}

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _api_get(self, endpoint: str, params: dict | None = None, retries: int = 3) -> dict[str, Any]:
        """GET request with 429 retry logic."""
        params = params or {}
        for attempt in range(retries):
            try:
                resp = self._client.get(f"{QOBUZ_API_BASE}/{endpoint}", params=params)
                if resp.status_code == 429:
                    wait = 2 ** attempt  # 1s, 2s, 4s
                    logger.warning("Qobuz 429 on GET %s, retrying in %ds (attempt %d/%d)", endpoint, wait, attempt + 1, retries)
                    time.sleep(wait)
                    continue
                resp.raise_for_status()
                return resp.json()
            except httpx.HTTPStatusError:
                raise
        raise QobuzAPIError(f"Qobuz GET {endpoint} failed after {retries} retries (rate limited)")

    def _api_post(self, endpoint: str, data: dict | None = None, retries: int = 3) -> dict[str, Any]:
        """POST request with 429 retry logic."""
        data = data or {}
        for attempt in range(retries):
            try:
                resp = self._client.post(f"{QOBUZ_API_BASE}/{endpoint}", data=data)
                if resp.status_code == 429:
                    wait = 2 ** attempt
                    logger.warning("Qobuz 429 on POST %s, retrying in %ds (attempt %d/%d)", endpoint, wait, attempt + 1, retries)
                    time.sleep(wait)
                    continue
                resp.raise_for_status()
                return resp.json()
            except httpx.HTTPStatusError:
                raise
        raise QobuzAPIError(f"Qobuz POST {endpoint} failed after {retries} retries (rate limited)")

    # ------------------------------------------------------------------
    # Favorites
    # ------------------------------------------------------------------

    def add_favorite(self, item_type: str, item_ids: list[str]) -> dict[str, Any]:
        """Add items to Qobuz favorites.

        Args:
            item_type: 'track', 'album', or 'artist'
            item_ids:  List of Qobuz IDs to favorite.
        """
        if not item_ids:
            return {"status": "ok", "added": 0}
        ids_csv = ",".join(str(i) for i in item_ids)
        key_map = {"track": "track_ids", "album": "album_ids", "artist": "artist_ids"}
        key = key_map.get(item_type)
        if not key:
            raise QobuzAPIError(f"Invalid item_type '{item_type}'. Must be track, album, or artist.")
        result = self._api_post("favorite/create", {key: ids_csv})
        logger.info("Qobuz favorites add: type=%s ids=%s -> %s", item_type, ids_csv, result)
        return result

    def remove_favorite(self, item_type: str, item_ids: list[str]) -> dict[str, Any]:
        """Remove items from Qobuz favorites.

        Args:
            item_type: 'track', 'album', or 'artist'
            item_ids:  List of Qobuz IDs to un-favorite.
        """
        if not item_ids:
            return {"status": "ok", "removed": 0}
        ids_csv = ",".join(str(i) for i in item_ids)
        key_map = {"track": "track_ids", "album": "album_ids", "artist": "artist_ids"}
        key = key_map.get(item_type)
        if not key:
            raise QobuzAPIError(f"Invalid item_type '{item_type}'. Must be track, album, or artist.")
        result = self._api_post("favorite/delete", {key: ids_csv})
        logger.info("Qobuz favorites remove: type=%s ids=%s -> %s", item_type, ids_csv, result)
        return result

    def get_favorites(self, item_type: str, limit: int = 500) -> dict[str, Any]:
        """Get user's Qobuz favorites.

        Args:
            item_type: 'tracks', 'albums', or 'artists' (plural form for list endpoints)
            limit:     Maximum number of items to fetch.
        """
        result = self._api_get("favorite/getUserFavorites", {
            "type": item_type,
            "limit": limit,
            "offset": 0,
        })
        return result

    # ------------------------------------------------------------------
    # Playlist management
    # ------------------------------------------------------------------

    def get_user_playlists(self, limit: int = 50) -> list[dict[str, Any]]:
        """Get all user playlists from Qobuz."""
        result = self._api_get("playlist/getUserPlaylists", {"limit": limit, "offset": 0})
        playlists = result.get("playlists", {}).get("items", [])
        return [
            {
                "id": str(p.get("id", "")),
                "name": p.get("name", ""),
                "tracks_count": p.get("tracks_count", 0),
                "duration": p.get("duration", 0),
                "created_at": p.get("created_at", ""),
                "updated_at": p.get("updated_at", ""),
                "is_public": p.get("is_public", False),
            }
            for p in playlists
        ]

    def get_playlist(self, playlist_id: str) -> dict[str, Any]:
        """Get playlist details with tracks."""
        return self._api_get("playlist/get", {"playlist_id": playlist_id, "extra": "tracks"})

    def update_playlist(
        self,
        playlist_id: str,
        name: str | None = None,
        description: str | None = None,
    ) -> dict[str, Any]:
        """Update playlist name and/or description."""
        data: dict = {"playlist_id": playlist_id}
        if name is not None:
            data["name"] = name
        if description is not None:
            data["description"] = description
        result = self._api_post("playlist/update", data)
        logger.info("Qobuz playlist updated: id=%s name=%s", playlist_id, name)
        return result

    def delete_playlist(self, playlist_id: str) -> dict[str, Any]:
        """Delete a Qobuz playlist."""
        result = self._api_post("playlist/delete", {"playlist_id": playlist_id})
        logger.info("Qobuz playlist deleted: id=%s", playlist_id)
        return result

    def remove_tracks_from_playlist(
        self,
        playlist_id: str,
        playlist_track_ids: list[str],
    ) -> dict[str, Any]:
        """Remove tracks from a Qobuz playlist by their positional IDs within the playlist.

        Note: playlist_track_ids are the position IDs within the playlist,
        not the global Qobuz track IDs.
        """
        if not playlist_track_ids:
            return {"status": "ok", "removed": 0}
        ids_csv = ",".join(str(i) for i in playlist_track_ids)
        result = self._api_post("playlist/deleteTracks", {
            "playlist_id": playlist_id,
            "playlist_track_ids": ids_csv,
        })
        logger.info("Qobuz playlist tracks removed: playlist=%s tracks=%s", playlist_id, ids_csv)
        return result

    def add_tracks_to_playlist_by_id(
        self,
        playlist_id: str,
        track_ids: list[str],
    ) -> dict[str, Any]:
        """Add tracks to an existing Qobuz playlist by track IDs (string version).

        Complement to add_tracks_to_playlist which takes int IDs.
        """
        if not track_ids:
            return {"status": "ok", "tracks_added": 0}
        ids_csv = ",".join(str(tid) for tid in track_ids)
        resp = self._client.post(
            f"{QOBUZ_API_BASE}/playlist/addTracks",
            data={
                "playlist_id": playlist_id,
                "track_ids": ids_csv,
            },
        )
        resp.raise_for_status()
        return resp.json()

    # ------------------------------------------------------------------
    # Discovery / New releases
    # ------------------------------------------------------------------

    def get_new_releases(self, genre_id: str | None = None, limit: int = 50) -> list[dict[str, Any]]:
        """Get featured / new release albums from Qobuz.

        Args:
            genre_id: Optional Qobuz genre ID to filter (e.g. "6" for Jazz).
            limit:    Number of albums to return.
        """
        params: dict = {"type": "new-releases", "limit": limit, "offset": 0}
        if genre_id:
            params["genre_id"] = genre_id
        result = self._api_get("album/getFeatured", params)
        albums = result.get("albums", {}).get("items", [])
        return [
            {
                "id": str(a.get("id", "")),
                "title": a.get("title", ""),
                "artist": a.get("artist", {}).get("name", ""),
                "release_date": a.get("release_date_original", a.get("released_at", "")),
                "genre": a.get("genre", {}).get("name", ""),
                "tracks_count": a.get("tracks_count", 0),
                "image_url": a.get("image", {}).get("large", ""),
            }
            for a in albums
        ]

    def search_artist(self, query: str, limit: int = 5) -> list[dict[str, Any]]:
        """Search for artists on Qobuz by name."""
        try:
            resp = self._client.get(
                f"{QOBUZ_API_BASE}/artist/search",
                params={"query": query, "limit": limit},
            )
            resp.raise_for_status()
            return resp.json().get("artists", {}).get("items", [])
        except Exception as exc:
            logger.warning("Qobuz artist search failed for '%s': %s", query, exc)
            return []

    # ------------------------------------------------------------------
    # Save playlist (original, kept for backward compat)
    # ------------------------------------------------------------------

    def save_playlist(
        self,
        name: str,
        tracks: list[dict[str, str]],
        description: str = "",
        is_public: bool = False,
    ) -> dict[str, Any]:
        """Full pipeline: resolve tracks → create playlist → add tracks.

        Args:
            name: Playlist name.
            tracks: [{"artist": "...", "title": "..."}, ...]
            description: Optional playlist description.
            is_public: Whether the playlist is public.

        Returns:
            Success/failure dict with counts and unmatched details.
        """
        resolved = self.resolve_tracks(tracks)
        matched = resolved["matched"]
        unmatched_list = resolved["unmatched"]

        if not matched:
            return {
                "success": False,
                "error": "Geen enkele track gevonden op Qobuz",
                "tracks_saved": 0,
                "tracks_unmatched": len(unmatched_list),
                "unmatched_details": unmatched_list[:10],
            }

        playlist = self.create_playlist(name, description, is_public)
        playlist_id = playlist["id"]

        qobuz_ids = [t["qobuz_id"] for t in matched]
        for i in range(0, len(qobuz_ids), 50):
            batch = qobuz_ids[i : i + 50]
            self.add_tracks_to_playlist(playlist_id, batch)
            if i + 50 < len(qobuz_ids):
                time.sleep(0.3)

        return {
            "success": True,
            "playlist_id": playlist_id,
            "playlist_name": name,
            "tracks_saved": len(matched),
            "tracks_unmatched": len(unmatched_list),
            "unmatched_details": unmatched_list[:10],
        }


# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

_qobuz_client: QobuzClient | None = None
_qobuz_init_error: str | None = None


def get_qobuz_api_client() -> QobuzClient | None:
    """Return the Qobuz API client singleton, or None if not configured."""
    return _qobuz_client


def get_qobuz_api_error() -> str | None:
    """Return the initialization error, if any."""
    return _qobuz_init_error


def init_qobuz_api_client(email: str, password: str) -> QobuzClient | None:
    """Initialize the Qobuz API client (auto-extracts app_id from web player).

    Returns None on failure and stores the error in _qobuz_init_error.
    app_secret is NOT needed — only app_id is extracted.
    """
    global _qobuz_client, _qobuz_init_error
    try:
        _qobuz_client = QobuzClient(email=email, password=password)
        _qobuz_init_error = None
        return _qobuz_client
    except QobuzAPIError as exc:
        _qobuz_init_error = str(exc)
        _qobuz_client = None
        logger.warning("Qobuz API client init failed: %s", exc)
        return None
