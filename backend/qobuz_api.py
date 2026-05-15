"""Direct Qobuz API client for playlist management.

Provides authentication, track search, playlist creation, and track
addition via Qobuz's JSON API. Independent of Roon — uses the user's
own Qobuz credentials.
"""

import logging
import time
from typing import Any

import httpx

logger = logging.getLogger(__name__)

QOBUZ_API_BASE = "https://www.qobuz.com/api.json/0.2"


class QobuzAPIError(Exception):
    """Raised when a Qobuz API call fails."""


class QobuzClient:
    """Client for the Qobuz JSON API (playlist management)."""

    def __init__(self, app_id: str, email: str, password: str):
        self.app_id = app_id
        self._token: str | None = None
        self._user_id: int | None = None
        self._client = httpx.Client(timeout=20.0)
        self._login(email, password)

    def _login(self, email: str, password: str) -> None:
        """Authenticate with Qobuz and store user_auth_token."""
        try:
            resp = self._client.post(
                f"{QOBUZ_API_BASE}/user/login",
                data={
                    "email": email,
                    "password": password,
                    "app_id": self.app_id,
                },
            )
            resp.raise_for_status()
            data = resp.json()
            self._token = data["user_auth_token"]
            self._user_id = data["user"]["id"]
            logger.info("Qobuz API: logged in as user %s", self._user_id)
        except httpx.HTTPStatusError as exc:
            logger.error("Qobuz login failed: %s", exc.response.text)
            raise QobuzAPIError(f"Qobuz login failed: {exc.response.status_code}") from exc
        except KeyError as exc:
            raise QobuzAPIError("Qobuz login response missing expected fields") from exc

    def _auth_params(self, **extra: Any) -> dict[str, Any]:
        """Return base params with app_id and auth token."""
        return {"app_id": self.app_id, "user_auth_token": self._token, **extra}

    def is_authenticated(self) -> bool:
        return self._token is not None

    def search_track(self, query: str, limit: int = 5) -> list[dict[str, Any]]:
        """Search the Qobuz catalog for tracks.

        Returns list of track dicts with 'id', 'title', 'performer', etc.
        """
        try:
            resp = self._client.get(
                f"{QOBUZ_API_BASE}/track/search",
                params=self._auth_params(query=query, limit=limit),
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
                **self._auth_params(),
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
                **self._auth_params(),
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
            {"matched": [{"artist", "title", "qobuz_id", "qobuz_title"}, ...],
             "unmatched": [{"artist", "title", "reason"}, ...]}
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
                artist_score = fuzz.partial_ratio(
                    artist.lower(), result_artist.lower()
                ) if artist else 100.0
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
                    "reason": f"best_score={best_score:.0f}" if best_result else "no_results",
                })

            # Rate limit — Qobuz doesn't document limits, be conservative
            time.sleep(0.15)

        logger.info(
            "Qobuz resolve: %d matched, %d unmatched out of %d tracks",
            len(matched), len(unmatched), len(tracks),
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
            name: Playlist name
            tracks: [{"artist": "...", "title": "..."}, ...]
            description: Optional playlist description
            is_public: Whether the playlist is public

        Returns:
            {"success": bool, "playlist_id": int, "playlist_name": str,
             "tracks_saved": int, "tracks_unmatched": int,
             "unmatched_details": [...]}
        """
        # Step 1: Resolve tracks to Qobuz IDs
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

        # Step 2: Create playlist
        playlist = self.create_playlist(name, description, is_public)
        playlist_id = playlist["id"]

        # Step 3: Add tracks in batches of 50 (Qobuz limit safety)
        qobuz_ids = [t["qobuz_id"] for t in matched]
        for i in range(0, len(qobuz_ids), 50):
            batch = qobuz_ids[i : i + 50]
            self.add_tracks_to_playlist(playlist_id, batch)
            if i + 50 < len(qobuz_ids):
                time.sleep(0.3)  # Brief pause between batches

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


def init_qobuz_api_client(app_id: str, email: str, password: str) -> QobuzClient | None:
    """Initialize the Qobuz API client. Returns None on failure."""
    global _qobuz_client, _qobuz_init_error
    try:
        _qobuz_client = QobuzClient(app_id=app_id, email=email, password=password)
        _qobuz_init_error = None
        return _qobuz_client
    except QobuzAPIError as exc:
        _qobuz_init_error = str(exc)
        _qobuz_client = None
        logger.warning("Qobuz API client init failed: %s", exc)
        return None
