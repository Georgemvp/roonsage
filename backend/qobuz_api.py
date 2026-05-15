"""Direct Qobuz API client for playlist management.

Provides authentication, track search, playlist creation, and track
addition via Qobuz's JSON API. Independent of Roon — uses the user's
own Qobuz credentials.

App credentials (app_id + app_secret) are auto-extracted from the Qobuz
web player JavaScript bundle on every initialisation so that they never
need to be configured manually (they expire with each Qobuz deploy).

Approach inspired by SoulSync (github.com/Nezreka/SoulSync).
"""

import base64
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
    "Version/17.4 Safari/605.1.15"
)


# ---------------------------------------------------------------------------
# Credential extraction helpers
# ---------------------------------------------------------------------------

def _extract_app_credentials() -> tuple[str, str]:
    """Extract current app_id and app_secret from the Qobuz web player bundle.

    Steps:
      1. Fetch https://play.qobuz.com/login to find the bundle.js URL.
      2. Download bundle.js.
      3. Extract app_id via the production API config pattern.
      4. Extract app_secret via the timezone seed/info/extras obfuscation.
      5. Validate each candidate secret with a signed API call.

    Returns:
        (app_id, app_secret) as strings.

    Raises:
        QobuzAPIError: If credentials cannot be extracted.
    """
    logger.info("Extracting Qobuz app credentials from web player…")

    with httpx.Client(timeout=20.0, follow_redirects=True) as client:
        # ---- Step 1: find bundle URL ----------------------------------------
        resp = client.get(
            f"{QOBUZ_PLAY_URL}/login",
            headers={"User-Agent": _BROWSER_UA},
        )
        resp.raise_for_status()
        html = resp.text

        bundle_match = re.search(
            r'<script\s+src="(/resources/\d+\.\d+\.\d+-[a-z]\d+/bundle\.js)"',
            html,
        )
        if not bundle_match:
            # Broader fallback pattern
            bundle_match = re.search(
                r'src="(/resources/[^"]+bundle[^"]+\.js)"',
                html,
            )
        if not bundle_match:
            raise QobuzAPIError(
                "Kon Qobuz app credentials niet ophalen. "
                "Geen bundle.js URL gevonden in de login pagina. "
                "Qobuz heeft mogelijk hun webplayer bijgewerkt."
            )

        bundle_path = bundle_match.group(1)
        bundle_url = f"{QOBUZ_PLAY_URL}{bundle_path}"
        logger.info("Found Qobuz bundle URL: %s", bundle_url)

        # ---- Step 2: download bundle ----------------------------------------
        bundle_resp = client.get(bundle_url, headers={"User-Agent": _BROWSER_UA})
        bundle_resp.raise_for_status()
        bundle = bundle_resp.text
        logger.info("Downloaded bundle.js (%d bytes)", len(bundle))

        # ---- Step 3: extract app_id -----------------------------------------
        app_id = _extract_app_id(bundle)
        if not app_id:
            raise QobuzAPIError(
                "Kon Qobuz app_id niet vinden in bundle.js. "
                "Qobuz heeft mogelijk hun webplayer bijgewerkt."
            )
        logger.info("Extracted Qobuz app_id: %s", app_id)

        # ---- Step 4 + 5: extract and validate app_secret --------------------
        app_secret = _extract_app_secret(bundle, app_id, client)
        if not app_secret:
            raise QobuzAPIError(
                "Kon Qobuz app_secret niet valideren. "
                "Qobuz heeft mogelijk hun webplayer bijgewerkt."
            )
        logger.info("Validated Qobuz app_secret (length=%d)", len(app_secret))

    return app_id, app_secret


def _extract_app_id(bundle: str) -> str | None:
    """Extract app_id from the bundle JavaScript source."""
    # Primary pattern: production:{api:{appId:"579939560"
    m = re.search(r'production:\{api:\{appId:"(\d{9})"', bundle)
    if m:
        return m.group(1)

    # Fallback: any 9-digit number labelled app_id / appId
    patterns = [
        r'["\']?appId["\']?\s*:\s*["\'](\d{6,12})["\']',
        r'["\']?app_id["\']?\s*[:=]\s*["\'](\d{6,12})["\']',
    ]
    for pat in patterns:
        m = re.search(pat, bundle)
        if m:
            return m.group(1)

    return None


def _extract_app_secret(bundle: str, app_id: str, client: httpx.Client) -> str | None:
    """Extract and validate app_secret from timezone seed/info/extras obfuscation."""
    secrets: list[str] = []

    # Build a lookup: timezone_name → (info, extras)
    timezone_map: dict[str, tuple[str, str]] = {}
    for m in re.finditer(
        r'name:"[\w/]+/(?P<timezone>[a-z]+)"[^}]*'
        r'info:"(?P<info>[\w=]+)"[^}]*'
        r'extras:"(?P<extras>[\w=]+)"',
        bundle,
    ):
        timezone_map[m.group("timezone")] = (m.group("info"), m.group("extras"))

    # Find initialSeed calls and match against the timezone map
    for seed_m in re.finditer(
        r'[a-z]\.initialSeed\("(?P<seed>[\w=]+)",\s*window\.utimezone\.(?P<timezone>[a-z]+)\)',
        bundle,
    ):
        seed = seed_m.group("seed")
        tz = seed_m.group("timezone")
        if tz not in timezone_map:
            continue
        info, extras = timezone_map[tz]
        # Concatenate and strip trailing 44 chars, then base64-decode
        raw = seed + info + extras
        if len(raw) > 44:
            raw = raw[:-44]
        try:
            candidate = base64.b64decode(raw + "==").decode("utf-8", errors="ignore").strip("\x00")
        except Exception:
            continue
        if candidate and len(candidate) >= 16:
            secrets.append(candidate)

    # Fallback: look for 32-char hex strings that might be secrets
    if not secrets:
        for m in re.finditer(r'["\']([0-9a-f]{32})["\']', bundle):
            secrets.append(m.group(1))

    # Validate each candidate
    for secret in secrets:
        if _test_secret(app_id, secret, client):
            return secret

    return None


def _test_secret(app_id: str, secret: str, client: httpx.Client) -> bool:
    """Validate an app_secret by making a signed API call.

    HTTP 400 = wrong secret; anything else (including 401) = valid secret.
    """
    try:
        ts = int(time.time())
        sig_raw = f"trackgetFileUrlformat_id27intentstreamtrack_id1{ts}{secret}"
        sig = hashlib.md5(sig_raw.encode()).hexdigest()

        resp = client.get(
            f"{QOBUZ_API_BASE}/track/getFileUrl",
            params={
                "format_id": "27",
                "intent": "stream",
                "track_id": "1",
                "request_ts": ts,
                "request_sig": sig,
                "app_id": app_id,
            },
            headers={"User-Agent": _BROWSER_UA, "X-App-Id": app_id},
        )
        # 400 = definitely wrong secret; any other response means the secret was accepted
        return resp.status_code != 400
    except Exception:
        return False


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
    X-App-Id and X-User-Auth-Token headers via the persistent httpx Session.
    """

    def __init__(self, email: str, password: str):
        self._email = email
        self._password = password
        self._app_id: str = ""
        self._app_secret: str = ""
        self._token: str | None = None
        self._user_id: int | None = None
        self._user_display: str = ""
        self._subscription: str = ""

        # Persistent session — headers are added after login
        self._client = httpx.Client(
            timeout=20.0,
            headers={"User-Agent": _BROWSER_UA},
        )

        self._authenticate()

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    def _authenticate(self) -> None:
        """Extract credentials and log in."""
        # Step 1: auto-extract app_id + app_secret from web player
        self._app_id, self._app_secret = _extract_app_credentials()

        # Step 2: set X-App-Id header on the persistent client
        self._client.headers.update({"X-App-Id": self._app_id})

        # Step 3: login
        self._login()

    def _login(self) -> None:
        """Authenticate with Qobuz and store user_auth_token.

        Tries plain-text password first; falls back to MD5 hash if rejected.
        """
        logger.info("Logging in to Qobuz as %s…", self._email)

        for attempt, password in enumerate(
            [self._password, hashlib.md5(self._password.encode()).hexdigest()],
            start=1,
        ):
            try:
                resp = self._client.get(
                    f"{QOBUZ_API_BASE}/user/login",
                    params={
                        "email": self._email,
                        "password": password,
                        "app_id": self._app_id,
                    },
                )
                if resp.status_code in (400, 401) and attempt == 1:
                    logger.info("Qobuz login: plain-text failed, trying MD5 hash…")
                    continue

                resp.raise_for_status()
                data = resp.json()

                self._token = data["user_auth_token"]
                self._user_id = data["user"]["id"]

                # Human-readable display name
                user = data.get("user", {})
                firstname = user.get("firstname", "")
                lastname = user.get("lastname", "")
                self._user_display = f"{firstname} {lastname}".strip() or user.get("login", "")

                # Subscription label
                sub = user.get("subscription") or {}
                self._subscription = (
                    sub.get("offer", {}).get("label", "")
                    or sub.get("description", "")
                    or "Onbekend"
                )

                # Attach auth token to all subsequent requests
                self._client.headers.update({"X-User-Auth-Token": self._token})
                logger.info(
                    "Qobuz: logged in as '%s' (subscription: %s)",
                    self._user_display,
                    self._subscription,
                )
                return

            except httpx.HTTPStatusError as exc:
                if attempt == 1:
                    continue  # will retry with MD5
                error_text = exc.response.text
                try:
                    error_data = exc.response.json()
                    error_text = error_data.get("message", error_text)
                except Exception:
                    pass
                logger.error(
                    "Qobuz login failed (%d): %s", exc.response.status_code, error_text
                )
                raise QobuzAPIError(
                    f"Qobuz login mislukt ({exc.response.status_code}): {error_text}"
                ) from exc

        raise QobuzAPIError("Qobuz login mislukt na beide pogingen (plain-text en MD5)")

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------

    def is_authenticated(self) -> bool:
        return self._token is not None

    @property
    def user_display(self) -> str:
        return self._user_display

    @property
    def subscription(self) -> str:
        return self._subscription

    # ------------------------------------------------------------------
    # API methods
    # ------------------------------------------------------------------

    def search_track(self, query: str, limit: int = 5) -> list[dict[str, Any]]:
        """Search the Qobuz catalog for tracks."""
        try:
            resp = self._client.get(
                f"{QOBUZ_API_BASE}/track/search",
                params={"query": query, "limit": limit, "app_id": self._app_id},
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
                "app_id": self._app_id,
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
                "app_id": self._app_id,
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
    """Initialize the Qobuz API client (auto-extracts app credentials).

    Returns None on failure and stores the error in _qobuz_init_error.
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
