"""Tests for helper logic and routes in routes/library.py.

Tests _validate_track_selection (pure function) and the FastAPI endpoints
for status, stats, filter, and curate.

Imports are intentionally lazy (inside each test/fixture) to avoid
pulling in the full dependency chain at collection time.
"""

from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# _validate_track_selection
# ---------------------------------------------------------------------------

class TestValidateTrackSelection:
    def _fn(self):
        from backend.routes.library import _validate_track_selection
        return _validate_track_selection

    def _make_key_map(self, n: int) -> dict[str, str]:
        return {str(i + 1): f"key_{i + 1}" for i in range(n)}

    def _make_meta(self, items: list[tuple[str, str]]) -> dict[str, dict]:
        return {f"key_{i + 1}": {"artist": a, "title": t} for i, (a, t) in enumerate(items)}

    def test_valid_selection_no_warnings(self):
        f = self._fn()
        key_map = self._make_key_map(4)
        meta = self._make_meta([
            ("Radiohead", "Creep"),
            ("Pearl Jam", "Black"),
            ("Nirvana", "Come as You Are"),
            ("Oasis", "Wonderwall"),
        ])
        result = f([1, 2, 3, 4], key_map, meta)
        assert result["valid"] is True
        assert result["warnings"] == []

    def test_duplicate_detected(self):
        f = self._fn()
        key_map = {"1": "key_1", "2": "key_2", "3": "key_1"}  # key_1 appears twice
        meta = {"key_1": {"artist": "Radiohead", "title": "Creep"}}
        result = f([1, 2, 3], key_map, meta)
        warning_types = [w["type"] for w in result["warnings"]]
        assert "duplicate" in warning_types

    def test_clustering_detected(self):
        f = self._fn()
        key_map = self._make_key_map(3)
        meta = self._make_meta([
            ("Radiohead", "Creep"),
            ("Radiohead", "Fake Plastic Trees"),
            ("Pearl Jam", "Black"),
        ])
        result = f([1, 2, 3], key_map, meta)
        warning_types = [w["type"] for w in result["warnings"]]
        assert "clustering" in warning_types

    def test_overrepresentation_detected(self):
        f = self._fn()
        key_map = self._make_key_map(4)
        meta = self._make_meta([
            ("Radiohead", "Creep"),
            ("Radiohead", "Fake Plastic Trees"),
            ("Radiohead", "High and Dry"),
            ("Pearl Jam", "Black"),
        ])
        result = f([1, 2, 3, 4], key_map, meta, max_per_artist=2)
        warning_types = [w["type"] for w in result["warnings"]]
        assert "overrepresented" in warning_types

    def test_unknown_number_produces_warning(self):
        f = self._fn()
        key_map = {"1": "key_1"}
        meta = {"key_1": {"artist": "A", "title": "T"}}
        result = f([1, 99], key_map, meta)
        warning_types = [w["type"] for w in result["warnings"]]
        assert "unknown_number" in warning_types

    def test_valid_is_false_when_warnings_present(self):
        f = self._fn()
        key_map = {"1": "key_1", "2": "key_1"}
        meta = {"key_1": {"artist": "A", "title": "T"}}
        result = f([1, 2], key_map, meta)
        assert result["valid"] is False

    def test_empty_selection_is_valid(self):
        f = self._fn()
        result = f([], {}, {})
        assert result["valid"] is True

    def test_custom_max_per_artist_allows_more(self):
        f = self._fn()
        key_map = self._make_key_map(3)
        meta = self._make_meta([
            ("Radiohead", "Creep"),
            ("Radiohead", "Fake Plastic Trees"),
            ("Radiohead", "High and Dry"),
        ])
        result = f([1, 2, 3], key_map, meta, max_per_artist=3)
        overrep = [w for w in result["warnings"] if w["type"] == "overrepresented"]
        assert overrep == []


# ---------------------------------------------------------------------------
# Route-level tests via FastAPI TestClient
# ---------------------------------------------------------------------------

@pytest.fixture()
def client():
    from fastapi.testclient import TestClient

    from backend.main import app
    return TestClient(app, raise_server_exceptions=False)


class TestLibraryStatusRoute:
    def test_returns_200_with_disconnected_roon(self, client):
        with patch("backend.routes.library.get_roon_client", return_value=None), \
             patch("backend.routes.library.library_cache.get_sync_state", return_value={
                 "track_count": 0,
                 "synced_at": None,
                 "is_syncing": False,
                 "sync_progress": None,
                 "error": None,
             }), \
             patch("backend.routes.library.library_cache.needs_resync", return_value=False):
            resp = client.get("/api/library/status")
        assert resp.status_code == 200
        assert resp.json()["roon_connected"] is False

    def test_returns_200_with_connected_roon(self, client):
        mock_roon = MagicMock()
        mock_roon.is_connected.return_value = True
        with patch("backend.routes.library.get_roon_client", return_value=mock_roon), \
             patch("backend.routes.library.library_cache.get_sync_state", return_value={
                 "track_count": 1000,
                 "synced_at": "2024-01-01T00:00:00",
                 "is_syncing": False,
                 "sync_progress": None,
                 "error": None,
             }), \
             patch("backend.routes.library.library_cache.needs_resync", return_value=False):
            resp = client.get("/api/library/status")
        assert resp.status_code == 200
        data = resp.json()
        assert data["roon_connected"] is True
        assert data["track_count"] == 1000


class TestLibrarySyncRoute:
    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.library.get_roon_client", return_value=None):
            resp = client.post("/api/library/sync")
        assert resp.status_code == 503

    def test_409_when_already_syncing(self, client):
        mock_roon = MagicMock()
        mock_roon.is_connected.return_value = True
        with patch("backend.routes.library.get_roon_client", return_value=mock_roon), \
             patch("backend.routes.library.library_cache.get_sync_progress",
                   return_value={"is_syncing": True}):
            resp = client.post("/api/library/sync")
        assert resp.status_code == 409


class TestLibraryStatsRoute:
    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.library.get_roon_client", return_value=None):
            resp = client.get("/api/library/stats")
        assert resp.status_code == 503

    def test_200_with_stats(self, client):
        mock_roon = MagicMock()
        mock_roon.is_connected.return_value = True
        mock_roon.get_library_stats.return_value = {
            "total_tracks": 5000,
            "genres": [{"name": "Rock", "count": 1000}],
            "decades": [{"name": "1990s", "count": 500}],
        }
        with patch("backend.routes.library.get_roon_client", return_value=mock_roon):
            resp = client.get("/api/library/stats")
        assert resp.status_code == 200
        assert resp.json()["total_tracks"] == 5000
