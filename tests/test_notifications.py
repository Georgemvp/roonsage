"""Tests for the notifications module — message builders, notifiers, and EventBus."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.notifications import (
    ACCENT_COLOR,
    DiscordNotifier,
    EventBus,
    EventType,
    GenericWebhookNotifier,
    TelegramNotifier,
    _build_description,
    _build_discord_embed,
    _build_telegram_text,
    _format_duration,
    configure_from_settings,
)

# ---------------------------------------------------------------------------
# _format_duration
# ---------------------------------------------------------------------------

class TestFormatDuration:
    def test_none_returns_dash(self):
        assert _format_duration(None) == "–"

    def test_zero_returns_dash(self):
        assert _format_duration(0) == "–"

    def test_seconds_only(self):
        assert _format_duration(45_000) == "45s"

    def test_minutes_and_seconds(self):
        assert _format_duration(154_000) == "2m 34s"

    def test_exactly_one_minute(self):
        assert _format_duration(60_000) == "1m 0s"


# ---------------------------------------------------------------------------
# _build_description
# ---------------------------------------------------------------------------

class TestBuildDescription:
    def test_playlist_generated(self):
        data = {"playlist_name": "Chill Vibes", "track_count": 20, "duration_ms": 3600_000}
        desc = _build_description(EventType.PLAYLIST_GENERATED, data)
        assert "Chill Vibes" in desc
        assert "20" in desc

    def test_playlist_generated_includes_prompt(self):
        data = {"playlist_name": "X", "track_count": 5, "prompt": "mellow jazz"}
        desc = _build_description(EventType.PLAYLIST_GENERATED, data)
        assert "mellow jazz" in desc

    def test_library_sync_complete(self):
        data = {"track_count": 5000, "new_tracks": 42, "duration_ms": 12_000}
        desc = _build_description(EventType.LIBRARY_SYNC_COMPLETE, data)
        assert "5000" in desc
        assert "42" in desc

    def test_library_sync_complete_without_new_tracks(self):
        data = {"track_count": 100}
        desc = _build_description(EventType.LIBRARY_SYNC_COMPLETE, data)
        assert "100" in desc

    def test_library_sync_failed(self):
        data = {"error": "Connection timeout"}
        desc = _build_description(EventType.LIBRARY_SYNC_FAILED, data)
        assert "Connection timeout" in desc

    def test_new_release_found(self):
        data = {"artist": "Radiohead", "album": "OKNOTOK"}
        desc = _build_description(EventType.NEW_RELEASE_FOUND, data)
        assert "Radiohead" in desc
        assert "OKNOTOK" in desc

    def test_listening_milestone(self):
        data = {"message": "You hit 1000 scrobbles!"}
        desc = _build_description(EventType.LISTENING_MILESTONE, data)
        assert "1000 scrobbles" in desc

    def test_listenbrainz_sync_complete_with_stats(self):
        data = {"synced_stats": ["top_artists", "top_albums"]}
        desc = _build_description(EventType.LISTENBRAINZ_SYNC_COMPLETE, data)
        assert "top_artists" in desc

    def test_listenbrainz_sync_complete_empty_stats(self):
        data = {"synced_stats": []}
        desc = _build_description(EventType.LISTENBRAINZ_SYNC_COMPLETE, data)
        assert "bijgewerkt" in desc.lower()


# ---------------------------------------------------------------------------
# _build_discord_embed
# ---------------------------------------------------------------------------

class TestBuildDiscordEmbed:
    def test_structure(self):
        embed = _build_discord_embed(EventType.PLAYLIST_GENERATED, {"playlist_name": "X", "track_count": 1})
        assert "title" in embed
        assert "description" in embed
        assert embed["color"] == ACCENT_COLOR
        assert "timestamp" in embed
        assert embed["footer"]["text"] == "RoonSage"

    def test_title_matches_event_label(self):
        embed = _build_discord_embed(EventType.LIBRARY_SYNC_COMPLETE, {"track_count": 1})
        assert "Library" in embed["title"] or "gesynchroniseerd" in embed["title"]


# ---------------------------------------------------------------------------
# _build_telegram_text
# ---------------------------------------------------------------------------

class TestBuildTelegramText:
    def test_contains_html_bold_title(self):
        text = _build_telegram_text(EventType.LIBRARY_SYNC_FAILED, {"error": "boom"})
        assert "<b>" in text and "</b>" in text

    def test_contains_description_body(self):
        text = _build_telegram_text(EventType.LIBRARY_SYNC_FAILED, {"error": "oh no"})
        assert "oh no" in text


# ---------------------------------------------------------------------------
# DiscordNotifier
# ---------------------------------------------------------------------------

class TestDiscordNotifier:
    @pytest.mark.asyncio
    async def test_returns_true_on_204(self):
        mock_resp = MagicMock()
        mock_resp.status_code = 204

        with patch("backend.notifications.httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=mock_resp)
            mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

            notifier = DiscordNotifier("https://discord.example/webhook")
            result = await notifier.send(EventType.PLAYLIST_GENERATED, {"track_count": 10})

        assert result is True

    @pytest.mark.asyncio
    async def test_returns_false_on_http_error(self):
        mock_resp = MagicMock()
        mock_resp.status_code = 429
        mock_resp.text = "rate limited"

        with patch("backend.notifications.httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=mock_resp)
            mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

            notifier = DiscordNotifier("https://discord.example/webhook")
            result = await notifier.send(EventType.PLAYLIST_GENERATED, {})

        assert result is False

    @pytest.mark.asyncio
    async def test_returns_false_on_exception(self):
        with patch("backend.notifications.httpx.AsyncClient") as mock_cls:
            mock_cls.return_value.__aenter__ = AsyncMock(side_effect=RuntimeError("network down"))
            mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

            notifier = DiscordNotifier("https://discord.example/webhook")
            result = await notifier.send(EventType.PLAYLIST_GENERATED, {})

        assert result is False


# ---------------------------------------------------------------------------
# TelegramNotifier
# ---------------------------------------------------------------------------

class TestTelegramNotifier:
    @pytest.mark.asyncio
    async def test_returns_true_on_200(self):
        mock_resp = MagicMock()
        mock_resp.status_code = 200

        with patch("backend.notifications.httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=mock_resp)
            mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

            notifier = TelegramNotifier("bot_token", "chat_id")
            result = await notifier.send(EventType.NEW_RELEASE_FOUND, {"artist": "X", "album": "Y"})

        assert result is True


# ---------------------------------------------------------------------------
# GenericWebhookNotifier
# ---------------------------------------------------------------------------

class TestGenericWebhookNotifier:
    @pytest.mark.asyncio
    async def test_returns_true_on_200(self):
        mock_resp = MagicMock()
        mock_resp.status_code = 200

        with patch("backend.notifications.httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=mock_resp)
            mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

            notifier = GenericWebhookNotifier("https://my.webhook.test/")
            result = await notifier.send(EventType.PLAYLIST_GENERATED, {"playlist_name": "Test"})

        assert result is True

    @pytest.mark.asyncio
    async def test_payload_contains_event_key(self):
        captured = {}
        mock_resp = MagicMock()
        mock_resp.status_code = 200

        async def fake_post(url, json=None, **kw):
            captured.update(json or {})
            return mock_resp

        with patch("backend.notifications.httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_client.post = fake_post
            mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
            mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

            notifier = GenericWebhookNotifier("https://my.webhook.test/")
            await notifier.send(EventType.NEW_RELEASE_FOUND, {"artist": "Miles Davis"})

        assert captured.get("event") == EventType.NEW_RELEASE_FOUND.value
        assert "timestamp" in captured
        assert captured["data"]["artist"] == "Miles Davis"


# ---------------------------------------------------------------------------
# EventBus
# ---------------------------------------------------------------------------

class TestEventBusConfigure:
    def setup_method(self):
        # Reset singleton state for isolation
        EventBus._instance = None

    def teardown_method(self):
        EventBus._instance = None

    def test_configure_creates_discord_notifier(self):
        bus = EventBus()
        bus.configure(discord_webhook_url="https://discord.example/hook")
        assert bus._discord is not None
        assert bus._telegram is None
        assert bus._webhook is None

    def test_configure_creates_telegram_notifier(self):
        bus = EventBus()
        bus.configure(telegram_bot_token="tok", telegram_chat_id="123")
        assert bus._telegram is not None

    def test_configure_with_no_urls_creates_no_notifiers(self):
        bus = EventBus()
        bus.configure()
        assert bus._discord is None
        assert bus._telegram is None
        assert bus._webhook is None

    def test_default_enabled_events(self):
        bus = EventBus()
        bus.configure()
        assert EventType.PLAYLIST_GENERATED.value in bus._enabled_events
        assert EventType.LIBRARY_SYNC_COMPLETE.value in bus._enabled_events

    def test_custom_enabled_events(self):
        bus = EventBus()
        bus.configure(enabled_events=["new_release_found"])
        assert "new_release_found" in bus._enabled_events
        assert EventType.PLAYLIST_GENERATED.value not in bus._enabled_events


class TestEventBusEmitAsync:
    def setup_method(self):
        EventBus._instance = None

    def teardown_method(self):
        EventBus._instance = None

    @pytest.mark.asyncio
    async def test_emit_async_skips_disabled_event(self):
        bus = EventBus()
        bus.configure(
            discord_webhook_url="https://discord.example/hook",
            enabled_events=["library_sync_complete"],  # not playlist_generated
        )
        dispatch_called = []

        async def fake_dispatch(event_type, data, notifiers):
            dispatch_called.append(event_type)

        bus._dispatch = fake_dispatch
        await bus.emit_async(EventType.PLAYLIST_GENERATED, {})
        assert len(dispatch_called) == 0

    @pytest.mark.asyncio
    async def test_emit_async_skips_when_no_notifiers(self):
        bus = EventBus()
        bus.configure(enabled_events=[EventType.PLAYLIST_GENERATED.value])
        # No Discord/Telegram/Webhook configured
        dispatch_called = []

        async def fake_dispatch(event_type, data, notifiers):
            dispatch_called.append(event_type)

        bus._dispatch = fake_dispatch
        await bus.emit_async(EventType.PLAYLIST_GENERATED, {})
        assert len(dispatch_called) == 0


class TestConfigureFromSettings:
    def setup_method(self):
        EventBus._instance = None

    def teardown_method(self):
        EventBus._instance = None

    def test_wires_discord_from_settings_dict(self):
        configure_from_settings({"discord_webhook_url": "https://discord.example/hook"})
        from backend.notifications import event_bus
        assert event_bus._discord is not None
