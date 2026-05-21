"""Roon Core client — thin re-export layer.

The implementation is split across focused modules:
  - roon_utils.py       : constants, utility functions, TrackCache, RoonQueryError
  - roon_connection.py  : RoonConnectionMixin + global singleton helpers
  - roon_browse.py      : RoonBrowseMixin (Browse API navigation)
  - roon_playback.py    : RoonPlaybackMixin (zones, transport, volume)
  - roon_search.py      : RoonSearchMixin (search + track conversion)

RoonClient inherits all methods via the mixin pattern.
"""

import threading
from typing import Any

from backend.roon_browse import RoonBrowseMixin
from backend.roon_connection import RoonConnectionMixin
from backend.roon_intelligence import RoonIntelligenceMixin
from backend.roon_playback import RoonPlaybackMixin
from backend.roon_search import RoonSearchMixin
from backend.roon_utils import (
    DATE_PATTERN,
    FUZZ_THRESHOLD,
    LIVE_KEYWORDS,
    RoonQueryError,
    TrackCache,
    get_track_cache,
    is_live_version,
    normalize_artist,
    run_in_thread,
    simplify_string,
)

__all__ = [
    "RoonClient",
    "RoonQueryError",
    "TrackCache",
    "get_track_cache",
    "is_live_version",
    "normalize_artist",
    "simplify_string",
    "run_in_thread",
    "FUZZ_THRESHOLD",
    "DATE_PATTERN",
    "LIVE_KEYWORDS",
    "get_roon_client",
    "init_roon_client",
]


class RoonClient(
    RoonConnectionMixin,
    RoonBrowseMixin,
    RoonPlaybackMixin,
    RoonSearchMixin,
    RoonIntelligenceMixin,
):
    """Client for interacting with a Roon Core via roonapi."""

    RECONNECT_COOLDOWN = 30
    EXTENSION_INFO = {
        "extension_id": "com.roonsage.roon",
        "display_name": "RoonSage",
        "display_version": "1.0.0",
        "publisher": "RoonSage",
        "email": "roonsage@example.com",
        "website": "https://github.com/Georgemvp/roonsage",
    }

    def __init__(
        self,
        host: str,
        port: int = 9330,
        core_id: str = "",
        token: str = "",
        extension_info: dict[str, str] | None = None,
    ):
        self.host = host
        self.port = port
        self.core_id = core_id
        self.token = token or None
        self._api: Any = None
        self._error: str | None = None
        self._last_reconnect_attempt: float = 0.0
        self._reconnect_lock = threading.Lock()
        self._browse_lock = threading.Lock()
        self._albums_browse_lock = threading.Lock()
        self._genres_browse_lock = threading.Lock()
        self._needs_authorization = False
        # Set _connecting = True before launching the thread to close the race
        # window where is_connected() runs between t.start() and _connect()
        # flipping the flag. Otherwise is_connected() would see the default
        # False and kick off a duplicate reconnect thread.
        self._connecting = True

        if extension_info:
            self.EXTENSION_INFO = extension_info

        t = threading.Thread(target=self._connect, daemon=True)
        t.start()


# ---------------------------------------------------------------------------
# Global singleton — re-exported from roon_connection for backwards compat
# ---------------------------------------------------------------------------

from backend.roon_connection import get_roon_client, init_roon_client  # noqa: E402, F401
