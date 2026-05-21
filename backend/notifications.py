"""Notification system for RoonSage.

Provides an EventBus singleton and channel-specific notifiers (Discord,
Telegram, generic webhook).  All dispatch is fire-and-forget — notifications
never block the caller and never crash the app.
"""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import UTC, datetime
from enum import Enum
from typing import Any

import httpx

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Event types
# ---------------------------------------------------------------------------


class EventType(str, Enum):
    PLAYLIST_GENERATED = "playlist_generated"
    LIBRARY_SYNC_COMPLETE = "library_sync_complete"
    LIBRARY_SYNC_FAILED = "library_sync_failed"
    NEW_RELEASE_FOUND = "new_release_found"
    LISTENING_MILESTONE = "listening_milestone"
    LISTENBRAINZ_SYNC_COMPLETE = "lb_sync_complete"


class NotificationChannel(str, Enum):
    DISCORD = "discord"
    TELEGRAM = "telegram"
    WEBHOOK = "webhook"


# ---------------------------------------------------------------------------
# Notifiers
# ---------------------------------------------------------------------------

ACCENT_COLOR = 0xE5A00D  # #e5a00d as Discord integer


class DiscordNotifier:
    """POST to a Discord webhook with an embed."""

    def __init__(self, webhook_url: str) -> None:
        self.webhook_url = webhook_url

    async def send(self, event_type: EventType, data: dict[str, Any]) -> bool:
        """Send an embed to Discord.  Returns True on success."""
        try:
            embed = _build_discord_embed(event_type, data)
            payload = {"embeds": [embed]}
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(self.webhook_url, json=payload)
                if resp.status_code in (200, 204):
                    return True
                logger.warning(
                    "Discord notify HTTP %s: %s", resp.status_code, resp.text[:200]
                )
                return False
        except Exception as exc:
            logger.warning("Discord notify failed: %s", exc)
            return False


class TelegramNotifier:
    """POST to the Telegram Bot API using HTML-formatted messages."""

    def __init__(self, bot_token: str, chat_id: str) -> None:
        self.bot_token = bot_token
        self.chat_id = chat_id

    async def send(self, event_type: EventType, data: dict[str, Any]) -> bool:
        """Send a Telegram message.  Returns True on success."""
        try:
            text = _build_telegram_text(event_type, data)
            url = f"https://api.telegram.org/bot{self.bot_token}/sendMessage"
            payload = {
                "chat_id": self.chat_id,
                "text": text,
                "parse_mode": "HTML",
            }
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(url, json=payload)
                if resp.status_code == 200:
                    return True
                logger.warning(
                    "Telegram notify HTTP %s: %s", resp.status_code, resp.text[:200]
                )
                return False
        except Exception as exc:
            logger.warning("Telegram notify failed: %s", exc)
            return False


class GenericWebhookNotifier:
    """POST a JSON payload to any URL."""

    def __init__(self, webhook_url: str) -> None:
        self.webhook_url = webhook_url

    async def send(self, event_type: EventType, data: dict[str, Any]) -> bool:
        """POST JSON to the configured URL.  Returns True on success."""
        try:
            payload = {
                "event": event_type.value,
                "timestamp": datetime.now(UTC).isoformat(),
                "data": data,
            }
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(self.webhook_url, json=payload)
                if 200 <= resp.status_code < 300:
                    return True
                logger.warning(
                    "Webhook notify HTTP %s: %s", resp.status_code, resp.text[:200]
                )
                return False
        except Exception as exc:
            logger.warning("Webhook notify failed: %s", exc)
            return False


# ---------------------------------------------------------------------------
# Message builders
# ---------------------------------------------------------------------------

_EVENT_LABELS: dict[EventType, str] = {
    EventType.PLAYLIST_GENERATED: "🎵 Playlist gegenereerd",
    EventType.LIBRARY_SYNC_COMPLETE: "📚 Library gesynchroniseerd",
    EventType.LIBRARY_SYNC_FAILED: "❌ Library sync mislukt",
    EventType.NEW_RELEASE_FOUND: "🆕 Nieuwe releases gevonden",
    EventType.LISTENING_MILESTONE: "🏆 Luistermijlpaal",
    EventType.LISTENBRAINZ_SYNC_COMPLETE: "🎧 ListenBrainz sync klaar",
}


def _format_duration(ms: int | None) -> str:
    """Convert milliseconds to a human-readable string like '2m 34s'."""
    if not ms:
        return "–"
    secs = ms // 1000
    mins, secs = divmod(secs, 60)
    if mins:
        return f"{mins}m {secs}s"
    return f"{secs}s"


def _build_discord_embed(
    event_type: EventType, data: dict[str, Any]
) -> dict[str, Any]:
    title = _EVENT_LABELS.get(event_type, event_type.value)
    description = _build_description(event_type, data)
    return {
        "title": title,
        "description": description,
        "color": ACCENT_COLOR,
        "timestamp": datetime.now(UTC).isoformat(),
        "footer": {"text": "RoonSage"},
    }


def _build_telegram_text(event_type: EventType, data: dict[str, Any]) -> str:
    title = _EVENT_LABELS.get(event_type, event_type.value)
    body = _build_description(event_type, data)
    return f"<b>{title}</b>\n{body}"


def _build_description(event_type: EventType, data: dict[str, Any]) -> str:
    """Return a human-readable body for any event type."""
    if event_type == EventType.PLAYLIST_GENERATED:
        name = data.get("playlist_name") or data.get("playlist_title", "Onbekend")
        count = data.get("track_count", "?")
        duration = _format_duration(data.get("duration_ms"))
        prompt = data.get("prompt", "")
        lines = [f"**{name}** · {count} nummers · {duration}"]
        if prompt:
            lines.append(f"Verzoek: _{prompt[:120]}_")
        return "\n".join(lines)

    if event_type == EventType.LIBRARY_SYNC_COMPLETE:
        count = data.get("track_count", "?")
        new = data.get("new_tracks")
        duration = _format_duration(data.get("duration_ms"))
        parts = [f"{count} nummers · {duration}"]
        if new is not None:
            parts.append(f"{new} nieuw")
        return " · ".join(parts)

    if event_type == EventType.LIBRARY_SYNC_FAILED:
        err = data.get("error", "Onbekende fout")
        return f"Fout: {err[:200]}"

    if event_type == EventType.LISTENBRAINZ_SYNC_COMPLETE:
        stats = data.get("synced_stats", [])
        if stats:
            return f"Statistieken bijgewerkt: {', '.join(stats)}"
        return "Alle statistieken bijgewerkt."

    if event_type == EventType.NEW_RELEASE_FOUND:
        artist = data.get("artist", "Onbekend")
        album = data.get("album", "Onbekend")
        return f"{artist} – {album}"

    if event_type == EventType.LISTENING_MILESTONE:
        msg = data.get("message", "")
        return msg or "Nieuwe mijlpaal bereikt!"

    # Fallback: dump data as compact JSON
    return json.dumps(data, ensure_ascii=False)[:300]


# ---------------------------------------------------------------------------
# Notification log helper
# ---------------------------------------------------------------------------


def _log_notification(
    event_type: EventType,
    channel: NotificationChannel,
    success: bool,
    error_message: str | None = None,
) -> None:
    """Write a row to the notification_log table (best-effort, never raises)."""
    try:
        from backend.db import get_connection  # noqa: PLC0415

        with get_connection() as conn:
            conn.execute(
                "INSERT INTO notification_log "
                "(timestamp, event_type, channel, success, error_message) "
                "VALUES (datetime('now'), ?, ?, ?, ?)",
                (
                    event_type.value,
                    channel.value,
                    1 if success else 0,
                    error_message,
                ),
            )
            conn.commit()
    except Exception as exc:
        logger.debug("notification_log write failed: %s", exc)


# ---------------------------------------------------------------------------
# EventBus
# ---------------------------------------------------------------------------


class EventBus:
    """Singleton event bus.

    Call ``emit(event_type, data)`` from anywhere (sync or async).
    Dispatch runs in a background asyncio task — the caller is never blocked.
    """

    _instance: EventBus | None = None

    def __new__(cls) -> EventBus:
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self) -> None:
        if self._initialized:
            return
        self._initialized = True
        self._discord: DiscordNotifier | None = None
        self._telegram: TelegramNotifier | None = None
        self._webhook: GenericWebhookNotifier | None = None
        self._enabled_events: set[str] = set()
        self._loop: asyncio.AbstractEventLoop | None = None

    # ------------------------------------------------------------------
    # Configuration
    # ------------------------------------------------------------------

    def configure(
        self,
        discord_webhook_url: str = "",
        telegram_bot_token: str = "",
        telegram_chat_id: str = "",
        webhook_url: str = "",
        enabled_events: list[str] | None = None,
    ) -> None:
        """(Re-)configure notifiers from current settings."""
        self._discord = DiscordNotifier(discord_webhook_url) if discord_webhook_url else None
        self._telegram = (
            TelegramNotifier(telegram_bot_token, telegram_chat_id)
            if telegram_bot_token and telegram_chat_id
            else None
        )
        self._webhook = GenericWebhookNotifier(webhook_url) if webhook_url else None

        if enabled_events is None:
            # Default: notify on the two most useful events
            self._enabled_events = {
                EventType.PLAYLIST_GENERATED.value,
                EventType.LIBRARY_SYNC_COMPLETE.value,
            }
        else:
            self._enabled_events = set(enabled_events)

    def set_event_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        """Store the running loop so sync callers can schedule tasks."""
        self._loop = loop

    # ------------------------------------------------------------------
    # Emit
    # ------------------------------------------------------------------

    def emit(self, event_type: EventType, data: dict[str, Any]) -> None:
        """Fire-and-forget: schedule async dispatch without blocking the caller."""
        if event_type.value not in self._enabled_events:
            return

        notifiers = [
            (NotificationChannel.DISCORD, self._discord),
            (NotificationChannel.TELEGRAM, self._telegram),
            (NotificationChannel.WEBHOOK, self._webhook),
        ]
        active = [(ch, n) for ch, n in notifiers if n is not None]
        if not active:
            return

        # Schedule on the running loop (works from both sync and async contexts)
        try:
            loop = self._loop or asyncio.get_event_loop()
        except RuntimeError:
            logger.debug("EventBus.emit: no event loop available, skipping")
            return

        if loop.is_running():
            asyncio.run_coroutine_threadsafe(
                self._dispatch(event_type, data, active), loop
            )
        else:
            logger.debug("EventBus.emit: loop not running, skipping")

    async def emit_async(
        self, event_type: EventType, data: dict[str, Any]
    ) -> None:
        """Async variant — schedules dispatch as a background asyncio task."""
        if event_type.value not in self._enabled_events:
            return

        notifiers = [
            (NotificationChannel.DISCORD, self._discord),
            (NotificationChannel.TELEGRAM, self._telegram),
            (NotificationChannel.WEBHOOK, self._webhook),
        ]
        active = [(ch, n) for ch, n in notifiers if n is not None]
        if not active:
            return

        asyncio.create_task(self._dispatch(event_type, data, active))

    # ------------------------------------------------------------------
    # Internal dispatch
    # ------------------------------------------------------------------

    async def _dispatch(
        self,
        event_type: EventType,
        data: dict[str, Any],
        notifiers: list[tuple[NotificationChannel, Any]],
    ) -> None:
        for channel, notifier in notifiers:
            try:
                success = await notifier.send(event_type, data)
                _log_notification(event_type, channel, success)
            except Exception as exc:
                logger.warning(
                    "Unexpected error dispatching %s via %s: %s",
                    event_type.value,
                    channel.value,
                    exc,
                )
                _log_notification(event_type, channel, False, str(exc))

    # ------------------------------------------------------------------
    # Test helper
    # ------------------------------------------------------------------

    async def send_test(
        self,
        channel: NotificationChannel,
        *,
        discord_url: str = "",
        telegram_token: str = "",
        telegram_chat: str = "",
        webhook_url: str = "",
    ) -> tuple[bool, str]:
        """Send a test notification to a single channel.

        Returns (success, error_message).
        """
        event_type = EventType.PLAYLIST_GENERATED
        data = {
            "playlist_name": "Test Playlist",
            "track_count": 25,
            "duration_ms": 5400000,
            "prompt": "Dit is een testmelding van RoonSage.",
        }

        try:
            if channel == NotificationChannel.DISCORD:
                notifier: Any = DiscordNotifier(discord_url or "")
            elif channel == NotificationChannel.TELEGRAM:
                notifier = TelegramNotifier(telegram_token or "", telegram_chat or "")
            else:
                notifier = GenericWebhookNotifier(webhook_url or "")

            success = await notifier.send(event_type, data)
            return success, "" if success else "HTTP-fout — controleer de logs."
        except Exception as exc:
            return False, str(exc)


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

event_bus = EventBus()


def configure_from_settings(settings: dict[str, Any]) -> None:
    """Convenience helper called at startup and after config saves."""
    event_bus.configure(
        discord_webhook_url=settings.get("discord_webhook_url", ""),
        telegram_bot_token=settings.get("telegram_bot_token", ""),
        telegram_chat_id=settings.get("telegram_chat_id", ""),
        webhook_url=settings.get("webhook_url", ""),
        enabled_events=settings.get("enabled_events"),
    )
