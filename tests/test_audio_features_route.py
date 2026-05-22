"""Tests for the /api/audio-features routes.

Uses FastAPI's TestClient against a real app with mocked worker singletons
and a temp DB, so we exercise the routing + Pydantic models end-to-end.
"""

from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def client(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient

    from backend import db as db_module
    from backend.audio_features import worker as worker_module

    db_path = tmp_path / "routes.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)
    db_module.ensure_db_initialized().close()

    # Reset worker singleton so each test starts fresh.
    monkeypatch.setattr(worker_module, "_worker", None)

    # Import after env setup.
    from backend.main import app
    return TestClient(app)


def test_status_endpoint_returns_zero_counts(client):
    response = client.get("/api/audio-features/status")
    assert response.status_code == 200
    data = response.json()
    assert "pending" in data
    assert "complete" in data
    assert data["pending"] == 0


def test_start_requires_env(client, monkeypatch):
    monkeypatch.delenv("AUDIO_FEATURES_ENABLED", raising=False)
    response = client.post("/api/audio-features/start")
    assert response.status_code == 400


def test_start_when_enabled(client, monkeypatch):
    monkeypatch.setenv("AUDIO_FEATURES_ENABLED", "true")
    # Avoid spinning up a real asyncio task in tests.
    from backend.audio_features import worker as worker_module
    fake_worker = MagicMock()
    fake_worker.is_paused.return_value = False
    fake_worker.is_running.return_value = False
    with patch.object(worker_module, "get_features_worker", return_value=fake_worker):
        response = client.post("/api/audio-features/start")
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    fake_worker.start.assert_called_once()


def test_get_features_404_when_missing(client):
    response = client.get("/api/audio-features/nonexistent_key")
    assert response.status_code == 404


def test_get_features_returns_row(client):
    from backend.db import get_db_connection
    conn = get_db_connection()
    try:
        conn.execute("""
            INSERT INTO track_audio_features
                (item_key, file_path, bpm, camelot, energy)
            VALUES (?, ?, ?, ?, ?)
        """, ("abc", "/m/x.flac", 120.0, "8A", 0.65))
        conn.commit()
    finally:
        conn.close()
    response = client.get("/api/audio-features/abc")
    assert response.status_code == 200
    data = response.json()
    assert data["bpm"] == 120.0
    assert data["camelot"] == "8A"
