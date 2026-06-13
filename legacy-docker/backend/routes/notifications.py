"""Notification configuration and history endpoints for RoonSage."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel

from backend.config import get_notifications_config, save_notifications_config
from backend.db import get_connection
from backend.notifications import NotificationChannel, configure_from_settings, event_bus

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/notifications", tags=["notifications"])


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class NotificationsConfigResponse(BaseModel):
    discord_webhook_url: str
    telegram_bot_token: str  # redacted
    telegram_chat_id: str
    webhook_url: str
    enabled_events: list[str]
    discord_configured: bool
    telegram_configured: bool
    webhook_configured: bool


class NotificationsConfigUpdate(BaseModel):
    discord_webhook_url: str | None = None
    telegram_bot_token: str | None = None
    telegram_chat_id: str | None = None
    webhook_url: str | None = None
    enabled_events: list[str] | None = None


class TestNotificationRequest(BaseModel):
    channel: str  # "discord" | "telegram" | "webhook"
    # Optionally override stored values for in-form testing before saving
    discord_webhook_url: str | None = None
    telegram_bot_token: str | None = None
    telegram_chat_id: str | None = None
    webhook_url: str | None = None


class TestNotificationResponse(BaseModel):
    success: bool
    error: str


class NotificationLogEntry(BaseModel):
    id: int
    timestamp: str
    event_type: str
    channel: str
    success: bool
    error_message: str | None


# ---------------------------------------------------------------------------
# Helper: redact sensitive tokens for the response
# ---------------------------------------------------------------------------


def _redact(token: str) -> str:
    """Return a safe display string for a secret token."""
    if not token:
        return ""
    if len(token) <= 8:
        return "•" * len(token)
    return token[:4] + "•" * (len(token) - 8) + token[-4:]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.get("/config", response_model=NotificationsConfigResponse)
async def get_notifications_config_endpoint() -> Any:
    """Return current notification configuration (tokens are redacted)."""
    cfg = get_notifications_config()
    return NotificationsConfigResponse(
        discord_webhook_url=cfg["discord_webhook_url"],
        telegram_bot_token=_redact(cfg["telegram_bot_token"]),
        telegram_chat_id=cfg["telegram_chat_id"],
        webhook_url=cfg["webhook_url"],
        enabled_events=cfg["enabled_events"],
        discord_configured=bool(cfg["discord_webhook_url"]),
        telegram_configured=bool(cfg["telegram_bot_token"] and cfg["telegram_chat_id"]),
        webhook_configured=bool(cfg["webhook_url"]),
    )


@router.post("/config", response_model=NotificationsConfigResponse)
async def update_notifications_config(body: NotificationsConfigUpdate) -> Any:
    """Save notification configuration and reconfigure the live EventBus."""
    existing = get_notifications_config()

    # Merge: only update fields that were explicitly supplied
    updates: dict[str, Any] = {}
    if body.discord_webhook_url is not None:
        updates["discord_webhook_url"] = body.discord_webhook_url
    if body.telegram_bot_token is not None:
        updates["telegram_bot_token"] = body.telegram_bot_token
    if body.telegram_chat_id is not None:
        updates["telegram_chat_id"] = body.telegram_chat_id
    if body.webhook_url is not None:
        updates["webhook_url"] = body.webhook_url
    if body.enabled_events is not None:
        updates["enabled_events"] = body.enabled_events

    if updates:
        save_notifications_config(updates)

    # Re-configure the live singleton so changes take effect immediately
    merged = {**existing, **updates}
    configure_from_settings(merged)

    return NotificationsConfigResponse(
        discord_webhook_url=merged["discord_webhook_url"],
        telegram_bot_token=_redact(merged.get("telegram_bot_token", "")),
        telegram_chat_id=merged.get("telegram_chat_id", ""),
        webhook_url=merged["webhook_url"],
        enabled_events=merged["enabled_events"],
        discord_configured=bool(merged["discord_webhook_url"]),
        telegram_configured=bool(
            merged.get("telegram_bot_token") and merged.get("telegram_chat_id")
        ),
        webhook_configured=bool(merged["webhook_url"]),
    )


@router.post("/test", response_model=TestNotificationResponse)
async def test_notification(body: TestNotificationRequest) -> Any:
    """Send a test notification to the requested channel.

    Callers may pass override values so the test uses the values currently
    typed in the form (without requiring a save first).
    """
    cfg = get_notifications_config()

    try:
        channel = NotificationChannel(body.channel)
    except ValueError:
        return TestNotificationResponse(
            success=False,
            error=f"Onbekend kanaal: {body.channel!r}. Kies 'discord', 'telegram' of 'webhook'.",
        )

    discord_url = body.discord_webhook_url or cfg["discord_webhook_url"]
    tg_token = body.telegram_bot_token or cfg["telegram_bot_token"]
    tg_chat = body.telegram_chat_id or cfg["telegram_chat_id"]
    wh_url = body.webhook_url or cfg["webhook_url"]

    success, error = await event_bus.send_test(
        channel,
        discord_url=discord_url,
        telegram_token=tg_token,
        telegram_chat=tg_chat,
        webhook_url=wh_url,
    )
    return TestNotificationResponse(success=success, error=error)


@router.get("/history", response_model=list[NotificationLogEntry])
async def get_notification_history() -> Any:
    """Return the last 50 sent notifications from the log."""
    try:
        with get_connection() as conn:
            rows = conn.execute(
                "SELECT id, timestamp, event_type, channel, success, error_message "
                "FROM notification_log "
                "ORDER BY timestamp DESC LIMIT 50"
            ).fetchall()
        return [
            NotificationLogEntry(
                id=r["id"],
                timestamp=r["timestamp"],
                event_type=r["event_type"],
                channel=r["channel"],
                success=bool(r["success"]),
                error_message=r["error_message"],
            )
            for r in rows
        ]
    except Exception as exc:
        logger.warning("Failed to read notification_log: %s", exc)
        return []
