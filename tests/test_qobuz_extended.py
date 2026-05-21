"""Tests for extended Qobuz API client and endpoints.

Covers:
- QobuzClient favorites (add / remove / get)
- QobuzClient playlist CRUD
- QobuzClient new releases
- FastAPI endpoints via TestClient (mocked Qobuz client)
- prepare_for_arc pipeline
- Error handling: 401, 429, network errors
"""

import json
from typing import Any
from unittest.mock import MagicMock

import httpx
import pytest
from fastapi.testclient import TestClient

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _mock_response(status_code: int, body: Any) -> httpx.Response:
    """Build a fake httpx.Response (with a dummy request so raise_for_status works)."""
    content = json.dumps(body).encode()
    request = httpx.Request("GET", "https://www.qobuz.com/api.json/0.2/fake")
    return httpx.Response(
        status_code=status_code,
        content=content,
        headers={"content-type": "application/json"},
        request=request,
    )


# ---------------------------------------------------------------------------
# QobuzClient unit tests (sync, no real network)
# ---------------------------------------------------------------------------


class TestQobuzClientFavorites:
    """Unit tests for QobuzClient favorites methods."""

    @pytest.fixture
    def client(self, mocker):
        """Return a QobuzClient with a mocked HTTP client — skips real login."""
        from backend.qobuz_api import QobuzClient

        # Patch _login so __init__ doesn't try real network calls
        mocker.patch.object(QobuzClient, "_login", return_value=None)
        c = QobuzClient.__new__(QobuzClient)
        c._token = "fake-token"
        c._user_id = 123
        c._user_display_name = "Test User"
        c._subscription = "Studio"
        c.app_id = "950096963"
        c._http = MagicMock()  # placeholder
        # Replace internal httpx client with a mock
        c._client = MagicMock()
        return c

    def test_add_favorite_track(self, client):
        client._client.post.return_value = _mock_response(200, {"status": "ok"})
        result = client.add_favorite("track", ["111", "222"])
        assert result == {"status": "ok"}
        call_kwargs = client._client.post.call_args
        assert "favorite/create" in call_kwargs[0][0]
        assert call_kwargs[1]["data"]["track_ids"] == "111,222"

    def test_add_favorite_album(self, client):
        client._client.post.return_value = _mock_response(200, {"status": "ok"})
        result = client.add_favorite("album", ["999"])
        assert result == {"status": "ok"}
        assert client._client.post.call_args[1]["data"]["album_ids"] == "999"

    def test_add_favorite_artist(self, client):
        client._client.post.return_value = _mock_response(200, {"status": "ok"})
        result = client.add_favorite("artist", ["42"])
        assert result == {"status": "ok"}
        assert client._client.post.call_args[1]["data"]["artist_ids"] == "42"

    def test_add_favorite_invalid_type(self, client):
        from backend.qobuz_api import QobuzAPIError
        with pytest.raises(QobuzAPIError, match="Invalid item_type"):
            client.add_favorite("playlist", ["1"])

    def test_add_favorite_empty_ids(self, client):
        result = client.add_favorite("track", [])
        assert result == {"status": "ok", "added": 0}
        client._client.post.assert_not_called()

    def test_remove_favorite(self, client):
        client._client.post.return_value = _mock_response(200, {"status": "ok"})
        result = client.remove_favorite("album", ["888"])
        assert result == {"status": "ok"}
        call_data = client._client.post.call_args[1]["data"]
        assert call_data["album_ids"] == "888"

    def test_get_favorites_albums(self, client):
        body = {"albums": {"items": [{"id": "1", "title": "OK Computer"}], "total": 1}}
        client._client.get.return_value = _mock_response(200, body)
        result = client.get_favorites("albums", limit=10)
        assert result["albums"]["total"] == 1
        client._client.get.assert_called_once()
        params = client._client.get.call_args[1]["params"]
        assert params["type"] == "albums"
        assert params["limit"] == 10

    def test_get_favorites_tracks(self, client):
        body = {"tracks": {"items": [], "total": 0}}
        client._client.get.return_value = _mock_response(200, body)
        result = client.get_favorites("tracks", limit=100)
        assert result["tracks"]["total"] == 0


class TestQobuzClientPlaylistManagement:
    """Unit tests for QobuzClient playlist management methods."""

    @pytest.fixture
    def client(self, mocker):
        from backend.qobuz_api import QobuzClient
        mocker.patch.object(QobuzClient, "_login", return_value=None)
        c = QobuzClient.__new__(QobuzClient)
        c._token = "fake-token"
        c._user_id = 1
        c._user_display_name = "Test"
        c._subscription = "Studio"
        c.app_id = "950096963"
        c._client = MagicMock()
        return c

    def test_get_user_playlists(self, client):
        body = {
            "playlists": {
                "items": [
                    {
                        "id": 101,
                        "name": "Late Night Jazz",
                        "tracks_count": 20,
                        "duration": 3600,
                        "created_at": "2026-05-01",
                        "updated_at": "2026-05-10",
                        "is_public": False,
                    }
                ]
            }
        }
        client._client.get.return_value = _mock_response(200, body)
        playlists = client.get_user_playlists(limit=50)
        assert len(playlists) == 1
        assert playlists[0]["name"] == "Late Night Jazz"
        assert playlists[0]["id"] == "101"

    def test_get_playlist(self, client):
        body = {"id": 101, "name": "Test", "tracks": {"items": []}}
        client._client.get.return_value = _mock_response(200, body)
        result = client.get_playlist("101")
        assert result["id"] == 101

    def test_update_playlist_name(self, client):
        client._client.post.return_value = _mock_response(200, {"id": 101, "name": "New Name"})
        client.update_playlist("101", name="New Name")
        data = client._client.post.call_args[1]["data"]
        assert data["name"] == "New Name"
        assert data["playlist_id"] == "101"

    def test_delete_playlist(self, client):
        client._client.post.return_value = _mock_response(200, {"status": "ok"})
        client.delete_playlist("101")
        data = client._client.post.call_args[1]["data"]
        assert data["playlist_id"] == "101"

    def test_remove_tracks_from_playlist(self, client):
        client._client.post.return_value = _mock_response(200, {"status": "ok"})
        client.remove_tracks_from_playlist("101", ["5", "10", "15"])
        data = client._client.post.call_args[1]["data"]
        assert data["playlist_track_ids"] == "5,10,15"
        assert data["playlist_id"] == "101"

    def test_remove_tracks_empty(self, client):
        result = client.remove_tracks_from_playlist("101", [])
        assert result == {"status": "ok", "removed": 0}
        client._client.post.assert_not_called()


class TestQobuzClientNewReleases:
    """Unit tests for QobuzClient new releases method."""

    @pytest.fixture
    def client(self, mocker):
        from backend.qobuz_api import QobuzClient
        mocker.patch.object(QobuzClient, "_login", return_value=None)
        c = QobuzClient.__new__(QobuzClient)
        c._token = "fake-token"
        c._user_id = 1
        c._user_display_name = "Test"
        c._subscription = "Studio"
        c.app_id = "950096963"
        c._client = MagicMock()
        return c

    def test_get_new_releases_no_genre(self, client):
        body = {
            "albums": {
                "items": [
                    {
                        "id": "abc123",
                        "title": "New Album",
                        "artist": {"name": "Cool Artist"},
                        "release_date_original": "2026-05-15",
                        "genre": {"name": "Jazz"},
                        "tracks_count": 10,
                        "image": {"large": "https://example.com/img.jpg"},
                    }
                ]
            }
        }
        client._client.get.return_value = _mock_response(200, body)
        albums = client.get_new_releases(limit=20)
        assert len(albums) == 1
        assert albums[0]["title"] == "New Album"
        assert albums[0]["artist"] == "Cool Artist"
        assert albums[0]["genre"] == "Jazz"
        params = client._client.get.call_args[1]["params"]
        assert params["type"] == "new-releases"
        assert "genre_id" not in params

    def test_get_new_releases_with_genre_id(self, client):
        client._client.get.return_value = _mock_response(200, {"albums": {"items": []}})
        client.get_new_releases(genre_id="6", limit=10)
        params = client._client.get.call_args[1]["params"]
        assert params["genre_id"] == "6"


class TestQobuzClientRetryLogic:
    """Test 429 retry behaviour in _api_get and _api_post."""

    @pytest.fixture
    def client(self, mocker):
        from backend.qobuz_api import QobuzClient
        mocker.patch.object(QobuzClient, "_login", return_value=None)
        c = QobuzClient.__new__(QobuzClient)
        c._token = "fake-token"
        c._user_id = 1
        c._user_display_name = "Test"
        c._subscription = "Studio"
        c.app_id = "950096963"
        c._client = MagicMock()
        return c

    def test_get_retries_on_429(self, client, mocker):
        """_api_get should retry on 429 and succeed on second attempt."""
        # Patch time.sleep to avoid slow tests
        mocker.patch("backend.qobuz_api.time.sleep")
        client._client.get.side_effect = [
            _mock_response(429, {"error": "rate limited"}),
            _mock_response(200, {"albums": {"items": []}}),
        ]
        result = client._api_get("album/getFeatured", {"type": "new-releases"}, retries=3)
        assert result == {"albums": {"items": []}}
        assert client._client.get.call_count == 2

    def test_post_retries_on_429(self, client, mocker):
        mocker.patch("backend.qobuz_api.time.sleep")
        client._client.post.side_effect = [
            _mock_response(429, {"error": "rate limited"}),
            _mock_response(200, {"status": "ok"}),
        ]
        result = client._api_post("favorite/create", {"track_ids": "1"}, retries=3)
        assert result == {"status": "ok"}
        assert client._client.post.call_count == 2

    def test_raises_after_exhausting_retries(self, client, mocker):
        from backend.qobuz_api import QobuzAPIError
        mocker.patch("backend.qobuz_api.time.sleep")
        client._client.get.return_value = _mock_response(429, {"error": "rate limited"})
        with pytest.raises(QobuzAPIError, match="rate limited"):
            client._api_get("album/getFeatured", {}, retries=2)


# ---------------------------------------------------------------------------
# FastAPI endpoint tests (mocked Qobuz client singleton)
# ---------------------------------------------------------------------------


@pytest.fixture
def api_client(mocker):
    """TestClient with mocked Qobuz client."""
    from backend.main import app
    return TestClient(app)


def _make_mock_qobuz_client() -> MagicMock:
    mock = MagicMock()
    mock.is_authenticated.return_value = True
    mock._user_display_name = "Test User"
    return mock


class TestFavoritesEndpoints:
    def test_add_favorite_success(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.add_favorite.return_value = {"status": "ok"}
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.post("/api/qobuz/favorite/add", json={"type": "album", "ids": ["123"]})
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True
        assert data["type"] == "album"

    def test_add_favorite_no_client(self, api_client, mocker):
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=None)

        resp = api_client.post("/api/qobuz/favorite/add", json={"type": "album", "ids": ["123"]})
        assert resp.status_code == 400
        assert "not configured" in resp.json()["detail"].lower()

    def test_remove_favorite_success(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.remove_favorite.return_value = {"status": "ok"}
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.post("/api/qobuz/favorite/remove", json={"type": "track", "ids": ["456"]})
        assert resp.status_code == 200
        assert resp.json()["success"] is True

    def test_get_favorites_albums(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.get_favorites.return_value = {
            "albums": {"items": [{"id": "1", "title": "Test"}], "total": 1}
        }
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/favorites?type=albums")
        assert resp.status_code == 200
        data = resp.json()
        assert data["total"] == 1
        assert len(data["items"]) == 1

    def test_get_favorites_invalid_type(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/favorites?type=playlists")
        assert resp.status_code == 400


class TestPlaylistEndpoints:
    def test_list_playlists(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.get_user_playlists.return_value = [
            {
                "id": "101",
                "name": "My Playlist",
                "tracks_count": 15,
                "duration": 3600,
                "created_at": "2026-05-01",
                "updated_at": "2026-05-10",
                "is_public": False,
            }
        ]
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/playlists")
        assert resp.status_code == 200
        data = resp.json()
        assert data["total"] == 1
        assert data["playlists"][0]["name"] == "My Playlist"

    def test_get_playlist(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.get_playlist.return_value = {"id": 101, "name": "Test", "tracks": {"items": []}}
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/playlist/101")
        assert resp.status_code == 200
        assert resp.json()["id"] == 101

    def test_update_playlist_rename(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.update_playlist.return_value = {"id": 101, "name": "New Name"}
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.put("/api/qobuz/playlist/101", json={"name": "New Name"})
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True
        assert data["playlist_id"] == "101"

    def test_update_playlist_add_tracks(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.add_tracks_to_playlist_by_id.return_value = {"status": "ok"}
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.put("/api/qobuz/playlist/101", json={"add_track_ids": ["111", "222"]})
        assert resp.status_code == 200
        data = resp.json()
        assert data["tracks_added"] == 2

    def test_delete_playlist(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.delete_playlist.return_value = {"status": "ok"}
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.delete("/api/qobuz/playlist/101")
        assert resp.status_code == 200
        assert resp.json()["success"] is True

    def test_no_client_returns_400(self, api_client, mocker):
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=None)
        resp = api_client.get("/api/qobuz/playlists")
        assert resp.status_code == 400


class TestNewReleasesEndpoint:
    def test_new_releases_no_genre(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.get_new_releases.return_value = [
            {
                "id": "abc",
                "title": "Fresh Album",
                "artist": "New Artist",
                "release_date": "2026-05-18",
                "genre": "Electronic",
                "tracks_count": 12,
                "image_url": "",
            }
        ]
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/new-releases")
        assert resp.status_code == 200
        data = resp.json()
        assert data["total"] == 1
        assert data["albums"][0]["title"] == "Fresh Album"

    def test_new_releases_with_genre_id(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.get_new_releases.return_value = []
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/new-releases?genre_id=6&limit=10")
        assert resp.status_code == 200
        mock_client.get_new_releases.assert_called_once_with("6", 10)


class TestPrepareForArcEndpoint:
    def test_prepare_for_arc_success(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.resolve_tracks.return_value = {
            "matched": [
                {"artist": "Radiohead", "title": "Karma Police", "qobuz_id": 111},
                {"artist": "Portishead", "title": "Glory Box", "qobuz_id": 222},
            ],
            "unmatched": [],
        }
        mock_client.create_playlist.return_value = {"id": 999}
        mock_client.add_tracks_to_playlist.return_value = {"status": "ok"}
        mock_client.search_track.return_value = [{"album": {"id": "55"}}]
        mock_client.add_favorite.return_value = {"status": "ok"}
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        payload = {
            "playlist_name": "Late Night Vibes",
            "track_items": [
                {"title": "Karma Police", "artist": "Radiohead"},
                {"title": "Glory Box", "artist": "Portishead"},
            ],
            "add_to_favorites": True,
        }
        resp = api_client.post("/api/qobuz/prepare-for-arc", json=payload)
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True
        assert data["tracks_resolved"] == 2
        assert data["tracks_skipped"] == 0
        assert "Late Night Vibes" in data["playlist_name"]
        assert data["playlist_id"] == "999"

    def test_prepare_for_arc_no_matches(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mock_client.resolve_tracks.return_value = {
            "matched": [],
            "unmatched": [{"artist": "Unknown", "title": "Unreachable", "reason": "no_results"}],
        }
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        payload = {
            "playlist_name": "Test",
            "track_items": [{"title": "Unreachable", "artist": "Unknown"}],
            "add_to_favorites": False,
        }
        resp = api_client.post("/api/qobuz/prepare-for-arc", json=payload)
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is False
        assert data["tracks_skipped"] == 1

    def test_prepare_for_arc_empty_tracks(self, api_client, mocker):
        mock_client = _make_mock_qobuz_client()
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        payload = {"playlist_name": "Empty", "track_items": [], "add_to_favorites": False}
        resp = api_client.post("/api/qobuz/prepare-for-arc", json=payload)
        assert resp.status_code == 400

    def test_prepare_for_arc_no_client(self, api_client, mocker):
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=None)
        payload = {
            "playlist_name": "Test",
            "track_items": [{"title": "Song", "artist": "Artist"}],
            "add_to_favorites": False,
        }
        resp = api_client.post("/api/qobuz/prepare-for-arc", json=payload)
        assert resp.status_code == 400


class TestErrorHandling:
    """Test error handling for various failure scenarios."""

    def test_401_unauthorized_propagated(self, api_client, mocker):
        """Qobuz 401 should surface as a 502 from the API."""
        from backend.qobuz_api import QobuzAPIError
        mock_client = _make_mock_qobuz_client()
        mock_client.add_favorite.side_effect = QobuzAPIError("Invalid or expired user_auth_token")
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.post("/api/qobuz/favorite/add", json={"type": "album", "ids": ["1"]})
        assert resp.status_code == 502
        assert "token" in resp.json()["detail"].lower()

    def test_network_error_returns_500(self, api_client, mocker):
        """A network/connection error should return 500."""
        mock_client = _make_mock_qobuz_client()
        mock_client.get_user_playlists.side_effect = Exception("Connection refused")
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/playlists")
        assert resp.status_code == 500
        assert "Connection refused" in resp.json()["detail"]

    def test_qobuz_api_error_returns_502(self, api_client, mocker):
        from backend.qobuz_api import QobuzAPIError
        mock_client = _make_mock_qobuz_client()
        mock_client.get_new_releases.side_effect = QobuzAPIError("Qobuz API unavailable")
        mocker.patch("backend.routes.qobuz_playlist.get_qobuz_api_client", return_value=mock_client)

        resp = api_client.get("/api/qobuz/new-releases")
        assert resp.status_code == 502
