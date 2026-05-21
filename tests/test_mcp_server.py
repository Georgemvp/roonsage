"""Tests for mcp_server.py — verifies each tool calls the correct endpoint."""

import json
import os

# Clear proxy env vars before httpx is instantiated — the sandbox sets
# ALL_PROXY=socks5h://... but socksio is not installed in CI/test envs.
for _var in ("ALL_PROXY", "all_proxy", "HTTPS_PROXY", "https_proxy",
             "HTTP_PROXY", "http_proxy", "FTP_PROXY", "ftp_proxy",
             "GRPC_PROXY", "grpc_proxy"):
    os.environ.pop(_var, None)

from unittest.mock import AsyncMock, MagicMock, patch  # noqa: E402

import httpx  # noqa: E402
import pytest  # noqa: E402

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_response(data: dict | list, status_code: int = 200) -> MagicMock:
    """Return a mock httpx.Response that returns *data* as JSON."""
    resp = MagicMock(spec=httpx.Response)
    resp.status_code = status_code
    resp.json.return_value = data
    resp.raise_for_status = MagicMock()
    resp.text = json.dumps(data)
    return resp


def _make_error_response(status_code: int, text: str = "error") -> MagicMock:
    """Return a mock httpx.Response that raises HTTPStatusError on raise_for_status."""
    resp = MagicMock(spec=httpx.Response)
    resp.status_code = status_code
    resp.text = text
    exc = httpx.HTTPStatusError(text, request=MagicMock(), response=resp)
    resp.raise_for_status = MagicMock(side_effect=exc)
    return resp


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def patch_clients():
    """Replace the persistent httpx.AsyncClient instances with async mocks.

    Yields (mock_client, mock_stream_client, mock_playback_client).
    Use ``mock_client, *_ = patch_clients`` when only the general client
    is needed, so the fixture remains forward-compatible.
    """
    with (
        patch("mcp_server._client") as mock_client,
        patch("mcp_server._stream_client") as mock_stream_client,
        patch("mcp_server._playback_client") as mock_playback_client,
    ):
        mock_client.request = AsyncMock()
        mock_client.post = AsyncMock()
        mock_stream_client.request = AsyncMock()
        mock_stream_client.post = AsyncMock()
        mock_playback_client.request = AsyncMock()
        mock_playback_client.post = AsyncMock()
        yield mock_client, mock_stream_client, mock_playback_client


# ---------------------------------------------------------------------------
# get_library_stats
# ---------------------------------------------------------------------------

class TestGetLibraryStats:
    @pytest.mark.asyncio
    async def test_calls_correct_endpoint(self, patch_clients):
        mock_client, *_ = patch_clients
        payload = {"total": 5000, "genres": ["Jazz", "Rock"], "decades": ["1990s"]}
        mock_client.request.return_value = _make_response(payload)

        from mcp_server import get_library_stats
        _result = await get_library_stats()

        mock_client.request.assert_called_once()
        call_args = mock_client.request.call_args
        assert call_args[0][0] == "GET"
        assert "/api/library/stats/cached" in call_args[0][1]

    @pytest.mark.asyncio
    async def test_returns_json_string(self, patch_clients):
        mock_client, *_ = patch_clients
        payload = {"total": 100, "genres": [], "decades": []}
        mock_client.request.return_value = _make_response(payload)

        from mcp_server import get_library_stats
        result = await get_library_stats()

        parsed = json.loads(result)
        assert parsed["total"] == 100

    @pytest.mark.asyncio
    async def test_connect_error_returns_unavailable_message(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.side_effect = httpx.ConnectError("refused")

        from mcp_server import get_library_stats
        result = await get_library_stats()

        assert "not reachable" in result.lower() or "RoonSage" in result

    @pytest.mark.asyncio
    async def test_http_error_returns_error_string(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_error_response(500, "internal error")

        from mcp_server import get_library_stats
        result = await get_library_stats()

        assert "error" in result.lower()


# ---------------------------------------------------------------------------
# filter_tracks
# ---------------------------------------------------------------------------

class TestFilterTracks:
    @pytest.mark.asyncio
    async def test_calls_filter_endpoint_with_body(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.post.return_value = _make_response({
            "tracks": [], "total_matching": 0, "returned": 0,
        })

        from mcp_server import filter_tracks
        await filter_tracks(genres=["Jazz"], decades=["1990s"], exclude_live=True)

        mock_client.post.assert_called_once()
        url = mock_client.post.call_args[0][0]
        assert "/api/library/filter" in url
        body = mock_client.post.call_args[1]["json"]
        assert body["genres"] == ["Jazz"]
        assert body["decades"] == ["1990s"]
        assert body["exclude_live"] is True

    @pytest.mark.asyncio
    async def test_compact_mode_raises_default_max_tracks_to_500(self, patch_clients):
        mock_client, *_ = patch_clients
        # compact mode makes 2 POST calls: /api/library/filter then /api/library/filter/session
        mock_client.post.return_value = _make_response({
            "tracks": [], "total_matching": 0, "returned": 0,
            "session_id": "abc123",
        })

        from mcp_server import filter_tracks
        await filter_tracks(output_format="compact")

        # First call is the filter endpoint — check its body
        first_call_body = mock_client.post.call_args_list[0][1]["json"]
        assert first_call_body["max_tracks"] == 500

    @pytest.mark.asyncio
    async def test_json_mode_keeps_default_max_tracks_200(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.post.return_value = _make_response({
            "tracks": [], "total_matching": 0, "returned": 0,
        })

        from mcp_server import filter_tracks
        await filter_tracks(output_format="json")

        body = mock_client.post.call_args[1]["json"]
        assert body["max_tracks"] == 200

    @pytest.mark.asyncio
    async def test_exclude_keywords_included_in_body(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.post.return_value = _make_response({
            "tracks": [], "total_matching": 0, "returned": 0,
        })

        from mcp_server import filter_tracks
        await filter_tracks(exclude_keywords=["christmas", "live"])

        body = mock_client.post.call_args[1]["json"]
        assert body["exclude_keywords"] == ["christmas", "live"]

    @pytest.mark.asyncio
    async def test_connect_error_returns_unavailable(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.post.side_effect = httpx.ConnectError("refused")

        from mcp_server import filter_tracks
        result = await filter_tracks()

        assert "RoonSage" in result or "not reachable" in result.lower()

    @pytest.mark.asyncio
    async def test_http_error_returns_error_message(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.post.return_value = _make_error_response(503, "service unavailable")

        from mcp_server import filter_tracks
        result = await filter_tracks()

        assert "error" in result.lower()


# ---------------------------------------------------------------------------
# curate_and_play
# ---------------------------------------------------------------------------

class TestCurateAndPlay:
    @pytest.mark.asyncio
    async def test_calls_curate_endpoint_with_correct_params(self, patch_clients):
        _, _, mock_playback = patch_clients
        mock_playback.post.return_value = _make_response({
            "success": True, "tracks_queued": 5, "zone_name": "Woonkamer",
        })

        from mcp_server import curate_and_play
        _result = await curate_and_play(
            track_numbers=[1, 5, 12],
            session_id="sess-abc",
            zone_id="zone-123",
        )

        mock_playback.post.assert_called_once()
        url = mock_playback.post.call_args[0][0]
        assert "/api/library/filter/curate" in url
        body = mock_playback.post.call_args[1]["json"]
        assert body["track_numbers"] == [1, 5, 12]
        assert body["session_id"] == "sess-abc"
        assert body["zone_id"] == "zone-123"

    @pytest.mark.asyncio
    async def test_result_contains_success_and_count(self, patch_clients):
        _, _, mock_playback = patch_clients
        mock_playback.post.return_value = _make_response({
            "success": True, "tracks_queued": 10, "zone_name": "Office",
        })

        from mcp_server import curate_and_play
        result = await curate_and_play(
            track_numbers=list(range(10)),
            session_id="s1",
            zone_id="z1",
            playlist_name="Test Playlist",
        )
        data = json.loads(result)
        assert data["success"] is True
        assert data["tracks_queued"] == 10
        assert data["playlist_name"] == "Test Playlist"

    @pytest.mark.asyncio
    async def test_append_mode_passed_to_api(self, patch_clients):
        _, _, mock_playback = patch_clients
        mock_playback.post.return_value = _make_response({
            "success": True, "tracks_queued": 3, "zone_name": "Kitchen",
        })

        from mcp_server import curate_and_play
        await curate_and_play(
            track_numbers=[1, 2, 3],
            session_id="s2",
            zone_id="z2",
            append=True,
        )
        body = mock_playback.post.call_args[1]["json"]
        assert body["append"] is True

    @pytest.mark.asyncio
    async def test_missing_numbers_shown_in_warning(self, patch_clients):
        _, _, mock_playback = patch_clients
        mock_playback.post.return_value = _make_response({
            "success": True, "tracks_queued": 2,
            "zone_name": "Living Room", "missing_numbers": [99, 100],
        })

        from mcp_server import curate_and_play
        result = await curate_and_play(
            track_numbers=[1, 2, 99, 100],
            session_id="s3",
            zone_id="z3",
        )
        data = json.loads(result)
        assert "warning" in data

    @pytest.mark.asyncio
    async def test_connect_error_returns_unavailable(self, patch_clients):
        _, _, mock_playback = patch_clients
        mock_playback.post.side_effect = httpx.ConnectError("refused")

        from mcp_server import curate_and_play
        result = await curate_and_play(
            track_numbers=[1], session_id="s", zone_id="z"
        )
        assert "RoonSage" in result or "not reachable" in result.lower()


# ---------------------------------------------------------------------------
# search_qobuz
# ---------------------------------------------------------------------------

class TestSearchQobuz:
    @pytest.mark.asyncio
    async def test_calls_qobuz_search_endpoint(self, patch_clients):
        mock_client, *_ = patch_clients
        payload = {"tracks": [{"title": "So What", "artist": "Miles Davis"}]}
        mock_client.request.return_value = _make_response(payload)

        from mcp_server import search_qobuz
        _result = await search_qobuz(query="Miles Davis", limit=5)

        call_args = mock_client.request.call_args
        assert call_args[0][0] == "POST"
        assert "/api/roon/qobuz-search" in call_args[0][1]
        body = call_args[1]["json"]
        assert body["query"] == "Miles Davis"
        assert body["limit"] == 5

    @pytest.mark.asyncio
    async def test_returns_json_string_on_success(self, patch_clients):
        mock_client, *_ = patch_clients
        payload = {"tracks": []}
        mock_client.request.return_value = _make_response(payload)

        from mcp_server import search_qobuz
        result = await search_qobuz(query="test")

        parsed = json.loads(result)
        assert "tracks" in parsed

    @pytest.mark.asyncio
    async def test_connect_error_returns_unavailable(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.side_effect = httpx.ConnectError("refused")

        from mcp_server import search_qobuz
        result = await search_qobuz(query="test")

        assert "RoonSage" in result or "not reachable" in result.lower()

    @pytest.mark.asyncio
    async def test_default_limit_is_10(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"tracks": []})

        from mcp_server import search_qobuz
        await search_qobuz(query="jazz")

        body = mock_client.request.call_args[1]["json"]
        assert body["limit"] == 10


# ---------------------------------------------------------------------------
# transport_control
# ---------------------------------------------------------------------------

class TestTransportControl:
    @pytest.mark.asyncio
    async def test_calls_transport_endpoint_with_action(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"success": True})

        from mcp_server import transport_control
        await transport_control(zone_id="zone-1", action="play")

        call_args = mock_client.request.call_args
        assert call_args[0][0] == "POST"
        assert "/api/roon/transport" in call_args[0][1]
        body = call_args[1]["json"]
        assert body["zone_id"] == "zone-1"
        assert body["action"] == "play"

    @pytest.mark.asyncio
    async def test_value_included_when_provided(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"success": True})

        from mcp_server import transport_control
        await transport_control(zone_id="z", action="shuffle", value="true")

        body = mock_client.request.call_args[1]["json"]
        assert body["value"] == "true"

    @pytest.mark.asyncio
    async def test_position_seconds_included_for_seek(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"success": True})

        from mcp_server import transport_control
        await transport_control(zone_id="z", action="seek", position_seconds=90)

        body = mock_client.request.call_args[1]["json"]
        assert body["position_seconds"] == 90
        assert "seek_offset" not in body

    @pytest.mark.asyncio
    async def test_optional_params_omitted_when_none(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"success": True})

        from mcp_server import transport_control
        await transport_control(zone_id="z", action="next")

        body = mock_client.request.call_args[1]["json"]
        assert "value" not in body
        assert "position_seconds" not in body
        assert "seek_offset" not in body

    @pytest.mark.asyncio
    async def test_connect_error_returns_unavailable(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.side_effect = httpx.ConnectError("refused")

        from mcp_server import transport_control
        result = await transport_control(zone_id="z", action="pause")

        assert "RoonSage" in result or "not reachable" in result.lower()


# ---------------------------------------------------------------------------
# volume_control
# ---------------------------------------------------------------------------

class TestVolumeControl:
    @pytest.mark.asyncio
    async def test_calls_volume_endpoint(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"success": True, "volume": 50})

        from mcp_server import volume_control
        _result = await volume_control(zone_name="Woonkamer", action="set", value=50)

        call_args = mock_client.request.call_args
        assert call_args[0][0] == "POST"
        assert "/api/roon/volume" in call_args[0][1]
        body = call_args[1]["json"]
        assert body["zone_name"] == "Woonkamer"
        assert body["action"] == "set"
        assert body["value"] == 50

    @pytest.mark.asyncio
    async def test_value_omitted_when_none(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"success": True})

        from mcp_server import volume_control
        await volume_control(zone_name="Office", action="mute")

        body = mock_client.request.call_args[1]["json"]
        assert "value" not in body

    @pytest.mark.asyncio
    async def test_returns_json_on_success(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_response({"success": True, "volume": 75})

        from mcp_server import volume_control
        result = await volume_control(zone_name="Kitchen", action="get")

        parsed = json.loads(result)
        assert parsed["success"] is True

    @pytest.mark.asyncio
    async def test_connect_error_returns_unavailable(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.side_effect = httpx.ConnectError("refused")

        from mcp_server import volume_control
        result = await volume_control(zone_name="z", action="mute")

        assert "RoonSage" in result or "not reachable" in result.lower()

    @pytest.mark.asyncio
    async def test_http_error_returns_error_string(self, patch_clients):
        mock_client, *_ = patch_clients
        mock_client.request.return_value = _make_error_response(404, "zone not found")

        from mcp_server import volume_control
        result = await volume_control(zone_name="unknown", action="set", value=10)

        assert "error" in result.lower()
