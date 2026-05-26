"""Tests for setup/onboarding endpoints."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from backend.models import DefaultsConfig


@pytest.fixture
def client():
    """Create test client with mocked dependencies.

    Patches lifespan-triggered side effects (config loading, Roon/LLM init,
    library cache DB creation) so tests don't depend on real environment.
    """
    from backend.main import app
    with (
        patch("backend.routes.setup.get_config", return_value=create_mock_config()),
        patch("backend.startup.init_clients"),
        patch("backend.startup.start_background_tasks"),
    ):
        return TestClient(app)


def create_mock_config(**overrides):
    """Create a properly structured mock config for setup tests."""
    defaults = {
        "roon_host": "192.168.1.100",
        "roon_port": 9100,
        "roon_token": "token",
        "llm_provider": "anthropic",
        "llm_api_key": "key",
        "model_analysis": "claude-sonnet-4-5",
        "model_generation": "claude-haiku-4-5",
        "ollama_url": "http://localhost:11434",
        "custom_url": "",
    }
    defaults.update(overrides)
    mock = MagicMock()
    mock.roon.host = defaults["roon_host"]
    mock.roon.port = defaults["roon_port"]
    mock.roon.token = defaults["roon_token"]
    mock.llm.provider = defaults["llm_provider"]
    mock.llm.api_key = defaults["llm_api_key"]
    mock.llm.model_analysis = defaults["model_analysis"]
    mock.llm.model_generation = defaults["model_generation"]
    mock.llm.ollama_url = defaults["ollama_url"]
    mock.llm.custom_url = defaults["custom_url"]
    mock.defaults = DefaultsConfig(track_count=25)
    return mock


class TestSetupStatus:
    """Tests for GET /api/setup/status."""

    def test_status_returns_all_fields(self, client):
        """Should return full checklist state."""
        mock_roon = MagicMock()
        mock_roon.is_connected.return_value = True
        mock_roon.get_error.return_value = None

        with (
            patch("backend.routes.setup.get_config", return_value=create_mock_config()),
            patch("backend.routes.setup.get_roon_client", return_value=mock_roon),
            patch("backend.routes.setup.library_cache") as mock_cache,
            patch("backend.routes.setup.load_user_yaml_config", return_value={}),
        ):
            mock_cache.DATA_DIR = MagicMock()
            mock_cache.DATA_DIR.mkdir = MagicMock()
            # Simulate writable dir — __truediv__ returns a path-like mock
            test_file = MagicMock()
            mock_cache.DATA_DIR.__truediv__ = MagicMock(return_value=test_file)
            mock_cache.has_cached_tracks.return_value = True
            mock_cache.is_cache_stale.return_value = False
            mock_cache.get_sync_state.return_value = {
                "track_count": 1000,
                "synced_at": "2026-01-01T00:00:00",
                "is_syncing": False,
                "sync_progress": None,
                "error": None,
            }

            response = client.get("/api/setup/status")

        assert response.status_code == 200
        data = response.json()
        assert data["roon_connected"] is True
        assert data["llm_configured"] is True
        assert data["library_synced"] is True
        assert data["track_count"] == 1000
        assert data["setup_complete"] is False

    def test_status_unconfigured(self, client):
        """Should show all steps incomplete when nothing is configured."""
        with (
            patch("backend.routes.setup.get_config", return_value=create_mock_config(
                roon_host="", roon_token="", llm_api_key=""
            )),
            patch("backend.routes.setup.get_roon_client", return_value=None),
            patch("backend.routes.setup.library_cache") as mock_cache,
            patch("backend.routes.setup.load_user_yaml_config", return_value={}),
        ):
            mock_cache.DATA_DIR = MagicMock()
            mock_cache.DATA_DIR.mkdir = MagicMock()
            test_file = MagicMock()
            mock_cache.DATA_DIR.__truediv__ = MagicMock(return_value=test_file)
            mock_cache.has_cached_tracks.return_value = False
            mock_cache.get_sync_state.return_value = {
                "track_count": 0,
                "synced_at": None,
                "is_syncing": False,
                "sync_progress": None,
                "error": None,
            }

            response = client.get("/api/setup/status")

        assert response.status_code == 200
        data = response.json()
        assert data["roon_connected"] is False
        assert data["llm_configured"] is False
        assert data["library_synced"] is False
        assert data["setup_complete"] is False

    def test_status_setup_complete(self, client):
        """Should reflect setup_complete from config.user.yaml."""
        with (
            patch("backend.routes.setup.get_config", return_value=create_mock_config()),
            patch("backend.routes.setup.get_roon_client", return_value=None),
            patch("backend.routes.setup.library_cache") as mock_cache,
            patch("backend.routes.setup.load_user_yaml_config", return_value={"setup": {"complete": True}}),
        ):
            mock_cache.DATA_DIR = MagicMock()
            mock_cache.DATA_DIR.mkdir = MagicMock()
            test_file = MagicMock()
            mock_cache.DATA_DIR.__truediv__ = MagicMock(return_value=test_file)
            mock_cache.has_cached_tracks.return_value = False
            mock_cache.get_sync_state.return_value = {
                "track_count": 0, "synced_at": None,
                "is_syncing": False, "sync_progress": None, "error": None,
            }

            response = client.get("/api/setup/status")

        assert response.status_code == 200
        assert response.json()["setup_complete"] is True


class TestSetupValidateRoon:
    """Tests for POST /api/setup/validate-roon."""

    def test_validate_roon_success(self, client):
        """Should return success when Roon Core connects and is authorized."""
        mock_temp_client = MagicMock()
        mock_temp_client.wait_until_ready = AsyncMock()
        mock_temp_client.needs_authorization.return_value = False
        mock_temp_client.is_connected.return_value = True
        mock_temp_client.get_core_name.return_value = "My Roon Core"
        mock_temp_client.get_token.return_value = "roon-token-abc"
        mock_temp_client.get_core_id.return_value = "core-id-123"

        with (
            patch("backend.routes.setup.RoonClientInstance", return_value=mock_temp_client),
            patch("backend.routes.setup.update_config_values"),
            patch("backend.routes.setup.init_roon_client"),
        ):
            response = client.post("/api/setup/validate-roon", json={
                "roon_host": "192.168.1.100",
                "roon_port": 9100,
            })

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert data["core_name"] == "My Roon Core"

    def test_validate_roon_failure(self, client):
        """Should return error when Roon connection fails."""
        mock_temp_client = MagicMock()
        mock_temp_client.wait_until_ready = AsyncMock()
        mock_temp_client.needs_authorization.return_value = False
        mock_temp_client.is_connected.return_value = False
        mock_temp_client.get_error.return_value = "Connection refused"

        with patch("backend.routes.setup.RoonClientInstance", return_value=mock_temp_client):
            response = client.post("/api/setup/validate-roon", json={
                "roon_host": "192.168.1.100",
                "roon_port": 9100,
            })

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert data["error"] is not None


class TestSetupValidateAI:
    """Tests for POST /api/setup/validate-ai."""

    def test_validate_ollama_success(self, client):
        """Should validate Ollama by checking connection status."""
        mock_status = MagicMock()
        mock_status.connected = True

        with (
            patch("backend.routes.setup.get_ollama_status", return_value=mock_status),
            patch("backend.routes.setup.update_config_values", return_value=create_mock_config(llm_provider="ollama")),
            patch("backend.routes.setup.init_llm_client"),
        ):
            response = client.post("/api/setup/validate-ai", json={
                "provider": "ollama",
                "ollama_url": "http://localhost:11434",
            })

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is True
        assert "Ollama" in data["provider_name"]

    def test_validate_ollama_failure(self, client):
        """Should return error when Ollama is unreachable."""
        mock_status = MagicMock()
        mock_status.connected = False
        mock_status.error = "Connection refused"

        with patch("backend.routes.setup.get_ollama_status", return_value=mock_status):
            response = client.post("/api/setup/validate-ai", json={
                "provider": "ollama",
                "ollama_url": "http://localhost:11434",
            })

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert data["error"] is not None

    def test_validate_unknown_provider(self, client):
        """Should reject unknown providers."""
        response = client.post("/api/setup/validate-ai", json={
            "provider": "nonexistent",
        })

        assert response.status_code == 200
        data = response.json()
        assert data["success"] is False
        assert "Unknown provider" in data["error"]

    def test_validate_gemini_success(self, client):
        """Should validate Gemini by listing models."""
        mock_client_instance = MagicMock()
        mock_client_instance.models.list.return_value = [MagicMock()]

        with (
            patch("google.genai.Client", return_value=mock_client_instance),
            patch("backend.routes.setup.update_config_values", return_value=create_mock_config(llm_provider="gemini")),
            patch("backend.routes.setup.init_llm_client"),
        ):
            response = client.post("/api/setup/validate-ai", json={
                "provider": "gemini",
                "api_key": "test-key",
            })

        assert response.status_code == 200
        assert response.json()["success"] is True


class TestSetupComplete:
    """Tests for POST /api/setup/complete."""

    def test_complete_saves_flag(self, client):
        """Should save setup.complete to config.user.yaml."""
        with patch("backend.routes.setup.save_user_config") as mock_save:
            response = client.post("/api/setup/complete")

        assert response.status_code == 200
        assert response.json()["success"] is True
        mock_save.assert_called_once_with({"setup": {"complete": True}})

    def test_complete_handles_save_error(self, client):
        """Should still return success even if save fails (best-effort)."""
        with patch("backend.routes.setup.save_user_config", side_effect=Exception("disk full")):
            response = client.post("/api/setup/complete")

        assert response.status_code == 200
        assert response.json()["success"] is True
