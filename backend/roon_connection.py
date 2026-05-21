"""Roon connection management mixin and global singleton helpers."""

import asyncio
import logging
import threading
import time
from typing import Any

logger = logging.getLogger(__name__)


class RoonConnectionMixin:
    """Mixin that provides Roon Core connection and state methods."""

    def _connect(self) -> None:
        """Attempt to connect to Roon Core."""
        self._connecting = True
        if not self.host:
            self._error = "Roon host is required"
            self._connecting = False
            return

        try:
            from roonapi import RoonApi  # type: ignore

            appinfo = self.EXTENSION_INFO

            self._api = RoonApi(
                appinfo,
                self.token,
                host=self.host,
                port=self.port,
                blocking_init=True,
            )

            if not self._api.token:
                # Not yet authorized in Roon's extension manager
                self._needs_authorization = True
                self._error = (
                    "RoonSage needs to be authorized in Roon. "
                    "Open Roon → Settings → Extensions and enable RoonSage."
                )
                return

            self._needs_authorization = False
            self._error = None
            logger.info(
                "Connected to Roon Core '%s'", self._api.core_name
            )

            # Persist token + core_id so they survive container restarts.
            if self._api.token:
                try:
                    from backend.config import save_user_config  # noqa: PLC0415
                    save_user_config({
                        "roon": {
                            "token": self._api.token,
                            "core_id": getattr(self._api, "core_id", None)
                                       or self.core_id
                                       or "",
                        }
                    })
                    logger.info("Roon token persisted to data/config.user.yaml")
                except Exception as save_err:
                    logger.warning(
                        "Failed to persist Roon token to config: %s", save_err
                    )
        except ImportError:
            self._error = "roonapi package is not installed. Run: pip install roonapi"
            self._api = None
        except Exception as e:
            self._error = f"Roon connection error: {e}"
            self._api = None
        finally:
            self._connecting = False

    def is_connected(self) -> bool:
        """Return True if connected and authorized.

        Never blocks the caller: if a connection attempt is already in progress
        (_connecting is True), or if the reconnect cooldown has not elapsed yet,
        this method returns False immediately without starting a new attempt.
        When a reconnect *is* needed it is launched in a daemon thread so it
        cannot freeze the asyncio event loop.
        """
        if self._api is not None and not self._needs_authorization:
            return True

        if self._connecting:
            return False

        now = time.time()
        with self._reconnect_lock:
            if self._api is not None and not self._needs_authorization:
                return True
            if self._connecting:
                return False
            if now - self._last_reconnect_attempt >= self.RECONNECT_COOLDOWN:
                self._last_reconnect_attempt = now
                logger.info("Attempting to reconnect to Roon Core…")
                t = threading.Thread(target=self._connect, daemon=True)
                t.start()

        return False

    def needs_authorization(self) -> bool:
        """Return True if the extension needs to be authorized in Roon."""
        return self._needs_authorization

    async def wait_until_ready(self, timeout: float = 60.0) -> None:
        """Wait until the background _connect() thread finishes (or timeout).

        Used by setup endpoints to block until the Roon registration handshake
        has either produced a token (`is_connected()` becomes True) or
        determined that the user still needs to authorize the extension
        (`needs_authorization()` becomes True). Yields back to the event loop
        between polls so the FastAPI worker stays responsive.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self._connecting:
                return
            await asyncio.sleep(0.5)

    def get_core_id(self) -> str | None:
        """Return the connected Roon Core's unique identifier."""
        if not self._api:
            return None
        return getattr(self._api, "core_id", None) or self.core_id or None

    def get_core_name(self) -> str | None:
        """Return the human-readable Roon Core name."""
        if not self._api:
            return None
        return getattr(self._api, "core_name", None)

    def get_error(self) -> str | None:
        return self._error

    def get_token(self) -> str | None:
        """Return the current Roon authorization token (safe public accessor)."""
        if not self._api:
            return None
        return getattr(self._api, "token", None)


# ---------------------------------------------------------------------------
# Global singleton
# ---------------------------------------------------------------------------

_roon_client_instance: Any = None


def get_roon_client() -> Any:
    """Get the current Roon client instance."""
    return _roon_client_instance


def init_roon_client(
    host: str,
    port: int = 9330,
    core_id: str = "",
    token: str = "",
) -> Any:
    """Initialize or reinitialize the Roon client."""
    global _roon_client_instance
    from backend.roon_client import RoonClient  # noqa: PLC0415
    _roon_client_instance = RoonClient(host=host, port=port, core_id=core_id, token=token)
    return _roon_client_instance
