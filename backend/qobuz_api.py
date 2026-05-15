"""Direct Qobuz API client for playlist management.

Provides authentication, track search, playlist creation, and track
addition via Qobuz's JSON API. Independent of Roon — uses the user's
own Qobuz credentials.

Only app_id is extracted from the Qobuz web player — app_secret is NOT
needed for playlist management, track search, or login operations.
"""

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

        self._client = httpx.Client(
            timeout=20.0,
            follow_redirects=True,
            headers={"User-Agent": _BROWSER_UA},
        )

        # Extract app_id from web player (no app_secret needed)
        self.app_id = self._extract_app_id()
        if not self.app_id:
            raise QobuzAPIError("Kon Qobuz app_id niet ophalen uit de webplayer")

        # Set app_id header for all subsequent requests
        self._client.headers["X-App-Id"] = self.app_id

        self._login(email, password)

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

            resp = self._client.get(
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

            bundle_resp = self._client.get(bundle_url)
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
        """Login via GET request with query params."""
        try:
            resp = self._client.get(
                f"{QOBUZ_API_BASE}/user/login",
                params={
                    "email": email,
                    "password": password,
                    "app_id": self.app_id,
                },
            )

            if resp.status_code == 401:
                raise QobuzAPIError("Ongeldig e-mailadres of wachtwoord")
            elif resp.status_code == 400:
                try:
                    msg = resp.json().get("message", "Login mislukt")
                except Exception:
                    msg = "Login mislukt"
                raise QobuzAPIError(f"Qobuz login fout: {msg}")

            resp.raise_for_status()
            data = resp.json()

            self._token = data["user_auth_token"]
            self._user_id = data["user"]["id"]

            user = data.get("user", {})
            firstname = user.get("firstname", "")
            lastname = user.get("lastname", "")
            self._user_display_name = (
                f"{firstname} {lastname}".strip() or user.get("login", email)
            )

            sub = user.get("subscription") or {}
            self._subscription = (
                sub.get("offer", {}).get("label", "")
                or sub.get("description", "")
                or user.get("credential", {}).get("label", "Onbekend")
            )

            # Set auth token header for all subsequent requests
            self._client.headers["X-User-Auth-Token"] = self._token

            logger.info(
                "Qobuz login geslaagd: %s (abonnement: %s)",
                self._user_display_name,
                self._subscription,
            )

        except QobuzAPIError:
            raise
        except httpx.HTTPStatusError as exc:
            raise QobuzAPIError(f"Qobuz API fout: HTTP {exc.response.status_code}") from exc
        except KeyError as exc:
            raise QobuzAPIError("Onverwacht antwoord van Qobuz API") from exc

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
