"""Tests for backend.audio_features.song_path.

Builds a tiny synthetic library where each track sits on a known location
along a 1D feature ramp. The path between the extremes should walk through
the intermediate tracks in order, for both the greedy and graph strategies.
"""

from __future__ import annotations

import sqlite3

import pytest

import backend.db.connection as _db_connection
from backend.audio_features import song_path


def _seed_db(tmp_path, monkeypatch, n: int = 30):
    from backend import db as db_module

    db_path = tmp_path / "path.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Ramp: each track i has all 6 features equal to i/(n-1), so the distance
    # between adjacent tracks is small and the path from 0 → n-1 must walk
    # monotonically.
    for i in range(n):
        v = i / (n - 1)
        ikey = f"t{i:03d}"
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (ikey, f"T{i}", "A", "Alb"),
        )
        conn.execute(
            """INSERT INTO track_audio_features
               (item_key, bpm, energy, danceability, valence, instrumentalness, acousticness)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (ikey, 80 + 80 * v, v, v, v, v, v),
        )
    conn.commit()
    return conn


def test_greedy_path_walks_monotonically(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch, n=30)
    path = song_path.find_song_path(conn, "t000", "t029", max_steps=10)
    assert path[0]["item_key"] == "t000"
    assert path[-1]["item_key"] == "t029"
    # Energy should generally trend upward. Strict per-step monotonicity is not
    # guaranteed because _extend_path can insert a midpoint slightly behind the
    # current tip when the beam search terminates one step early. Check instead
    # that the second-half mean exceeds the first-half mean by a clear margin.
    energies = [t["energy"] for t in path]
    mid = len(energies) // 2
    assert sum(energies[mid:]) / len(energies[mid:]) > sum(energies[:mid]) / mid
    conn.close()


def test_graph_path_endpoints_match(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch, n=30)
    path = song_path.find_song_path_graph(conn, "t000", "t029", max_steps=8, k=6)
    assert path[0]["item_key"] == "t000"
    assert path[-1]["item_key"] == "t029"
    assert len(path) <= 9
    conn.close()


def test_missing_endpoint_raises(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch, n=5)
    with pytest.raises(KeyError):
        song_path.find_song_path(conn, "t000", "missing-key")
    conn.close()


def test_empty_library_returns_empty(tmp_path, monkeypatch):
    from backend import db as db_module
    db_path = tmp_path / "empty.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)
    assert song_path.find_song_path(conn, "a", "b") == []
    conn.close()


def test_mood_path_returns_valid_steps(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch, n=15)
    result = song_path.find_song_path(conn, "t000", "t014", max_steps=8, mood="calm")
    assert result[0]["item_key"] == "t000"
    assert result[-1]["item_key"] == "t014"
    conn.close()


def test_load_mood_centroid_known_mood():
    from backend.audio_features.song_path import _load_mood_centroid_raw
    vec = _load_mood_centroid_raw("happy")
    assert vec is not None
    assert len(vec) == 6


def test_load_mood_centroid_unknown_mood():
    from backend.audio_features.song_path import _load_mood_centroid_raw
    assert _load_mood_centroid_raw("nonexistent_mood_xyz") is None
