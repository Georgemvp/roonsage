"""Tests for CLAP / hybrid Song Paths (v13.2).

We seed a small synthetic library where each track has both audio features
(on a 1D ramp) and a CLAP embedding (on a different 1D ramp). The two ramps
are deliberately rotated relative to each other so CLAP-based paths and
feature-based paths can be distinguished — the hybrid blend should sit in
between.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

import pytest

pytest.importorskip("numpy")
pytest.importorskip("fastapi")

import numpy as np  # noqa: E402

from backend.audio_features import song_path  # noqa: E402


def _seed_db(tmp_path, monkeypatch, n: int = 12, with_clap: bool = True):
    from backend import db as db_module

    db_path = tmp_path / "clap_path.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Features ramp ascending with i. CLAP ramp ascending with REVERSED index
    # so the two spaces order the library differently — a CLAP-driven path
    # walks in the opposite direction from a feature-driven path through
    # this fake library.
    rng = np.random.default_rng(seed=42)
    for i in range(n):
        v = i / (n - 1)
        ikey = f"t{i:03d}"
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (ikey, f"T{i}", "A", "Alb"),
        )
        conn.execute(
            """INSERT INTO track_audio_features
               (item_key, bpm, energy, danceability, valence,
                instrumentalness, acousticness)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (ikey, 80 + 80 * v, v, v, v, v, v),
        )
        if with_clap:
            # CLAP-space ramp opposite to feature-space ramp.
            # First half of vector encodes (1 - v), with small noise so
            # cosine distances vary smoothly between neighbours.
            emb = np.zeros(song_path.__dict__.get("EMBEDDING_DIM", 512) or 512, dtype=np.float32)
            # Spread across 8 axes scaled by inverse ramp so cosine distance
            # tracks |i - j| roughly linearly across the library.
            for axis in range(8):
                emb[axis] = (1.0 - v) + 0.01 * rng.standard_normal()
            # Add a constant component so vectors aren't degenerate.
            emb[8:16] = 0.1
            conn.execute(
                """INSERT INTO clap_embeddings (item_key, embedding, model, analyzed_at)
                   VALUES (?, ?, ?, ?)""",
                (ikey, emb.tobytes(), "fake/clap", datetime.now(UTC).isoformat()),
            )
    conn.commit()
    return conn


# ---------------------------------------------------------------------------
# Backend function tests
# ---------------------------------------------------------------------------


def test_clap_path_endpoints_and_steps(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch, n=12)
    path = song_path.find_song_path_clap(conn, "t000", "t011", max_steps=6, k=4)
    assert path, "expected a non-empty path"
    assert path[0]["item_key"] == "t000"
    assert path[-1]["item_key"] == "t011"
    assert len(path) <= 7
    conn.close()


def test_hybrid_path_endpoints_and_steps(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch, n=12)
    path = song_path.find_song_path_hybrid(conn, "t000", "t011", max_steps=6, k=4)
    assert path
    assert path[0]["item_key"] == "t000"
    assert path[-1]["item_key"] == "t011"
    conn.close()


def test_clap_path_differs_from_features_path(tmp_path, monkeypatch):
    """CLAP and feature spaces are intentionally different here — paths
    through them should not produce identical orderings."""
    conn = _seed_db(tmp_path, monkeypatch, n=15)
    feature_path = song_path.find_song_path_graph(
        conn, "t000", "t007", max_steps=6, k=4
    )
    clap_path = song_path.find_song_path_clap(
        conn, "t000", "t007", max_steps=6, k=4
    )
    f_keys = [t["item_key"] for t in feature_path]
    c_keys = [t["item_key"] for t in clap_path]
    assert f_keys != c_keys, (
        f"CLAP path should differ from feature path: {f_keys} vs {c_keys}"
    )
    conn.close()


def test_hybrid_blends_clap_and_features(tmp_path, monkeypatch):
    """Hybrid distance is 0.6·CLAP + 0.4·feature — the path should not be
    strictly identical to either pure variant."""
    conn = _seed_db(tmp_path, monkeypatch, n=15)
    feature_path = song_path.find_song_path_graph(
        conn, "t000", "t010", max_steps=6, k=4
    )
    clap_path = song_path.find_song_path_clap(
        conn, "t000", "t010", max_steps=6, k=4
    )
    hybrid_path = song_path.find_song_path_hybrid(
        conn, "t000", "t010", max_steps=6, k=4
    )
    f_keys = [t["item_key"] for t in feature_path]
    c_keys = [t["item_key"] for t in clap_path]
    h_keys = [t["item_key"] for t in hybrid_path]
    assert h_keys[0] == "t000" and h_keys[-1] == "t010"
    # At least one of (vs features, vs clap) is different — hybrid blends them.
    assert h_keys != f_keys or h_keys != c_keys
    conn.close()


def test_clap_path_missing_endpoint_raises(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch, n=6)
    with pytest.raises(KeyError):
        song_path.find_song_path_clap(conn, "t000", "missing-key")
    conn.close()


def test_clap_path_empty_when_no_embeddings(tmp_path, monkeypatch):
    """Graceful fallback: empty list when no CLAP embeddings exist."""
    conn = _seed_db(tmp_path, monkeypatch, n=5, with_clap=False)
    assert song_path.find_song_path_clap(conn, "t000", "t004") == []
    assert song_path.find_song_path_hybrid(conn, "t000", "t004") == []
    conn.close()


# ---------------------------------------------------------------------------
# Route-level tests
# ---------------------------------------------------------------------------


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    """FastAPI TestClient with a fresh DB and Roon mocked out."""
    from fastapi.testclient import TestClient

    from backend import db as db_module

    db_path = tmp_path / "route_clap_path.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    # Force schema init on a real connection so subsequent get_db_connection()
    # calls operate on the same file.
    seed_conn = sqlite3.connect(str(db_path))
    seed_conn.row_factory = sqlite3.Row
    db_module.init_schema(seed_conn)

    from fastapi import FastAPI

    from backend.routes import song_path as song_path_route

    app = FastAPI()
    app.include_router(song_path_route.router)
    return TestClient(app), seed_conn


def _seed_clap(conn, n=8):
    rng = np.random.default_rng(seed=7)
    for i in range(n):
        v = i / (n - 1)
        ikey = f"r{i:03d}"
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (ikey, f"R{i}", "A", "Alb"),
        )
        conn.execute(
            """INSERT INTO track_audio_features
               (item_key, bpm, energy, danceability, valence,
                instrumentalness, acousticness)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (ikey, 80 + 60 * v, v, v, v, v, v),
        )
        emb = np.zeros(512, dtype=np.float32)
        for axis in range(8):
            emb[axis] = v + 0.01 * rng.standard_normal()
        emb[8:16] = 0.1
        conn.execute(
            """INSERT INTO clap_embeddings (item_key, embedding, model, analyzed_at)
               VALUES (?, ?, ?, ?)""",
            (ikey, emb.tobytes(), "fake/clap", datetime.now(UTC).isoformat()),
        )
    conn.commit()


def test_route_method_clap_requires_embeddings(app_client):
    client, conn = app_client
    # Seed features only, no CLAP embeddings.
    conn.execute(
        "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
        ("a", "A", "X", "Y"),
    )
    conn.execute(
        "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
        ("b", "B", "X", "Y"),
    )
    conn.commit()

    resp = client.post(
        "/api/song-path",
        json={
            "from_track_id": "a",
            "to_track_id": "b",
            "method": "clap",
            "max_steps": 4,
        },
    )
    assert resp.status_code == 400
    assert "CLAP" in resp.json()["detail"]


def test_route_method_hybrid_requires_embeddings(app_client):
    client, _ = app_client
    resp = client.post(
        "/api/song-path",
        json={
            "from_track_id": "a",
            "to_track_id": "b",
            "method": "hybrid",
            "max_steps": 4,
        },
    )
    assert resp.status_code == 400
    assert "CLAP" in resp.json()["detail"]


def test_route_method_clap_returns_path(app_client):
    client, conn = app_client
    _seed_clap(conn, n=8)
    resp = client.post(
        "/api/song-path",
        json={
            "from_track_id": "r000",
            "to_track_id": "r007",
            "method": "clap",
            "max_steps": 5,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["method"] == "clap"
    assert body["path"][0]["item_key"] == "r000"
    assert body["path"][-1]["item_key"] == "r007"


def test_route_method_hybrid_returns_path(app_client):
    client, conn = app_client
    _seed_clap(conn, n=8)
    resp = client.post(
        "/api/song-path",
        json={
            "from_track_id": "r000",
            "to_track_id": "r007",
            "method": "hybrid",
            "max_steps": 5,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["method"] == "hybrid"
    assert body["path"][0]["item_key"] == "r000"
    assert body["path"][-1]["item_key"] == "r007"


def test_route_default_method_is_features(app_client):
    client, conn = app_client
    _seed_clap(conn, n=8)  # any seeded DB works
    resp = client.post(
        "/api/song-path",
        json={
            "from_track_id": "r000",
            "to_track_id": "r007",
            "max_steps": 5,
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["method"] == "features"
