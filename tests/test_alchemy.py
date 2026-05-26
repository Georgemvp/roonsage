"""Tests for backend.audio_features.alchemy.

Verifies the add/subtract math and the cosine-similarity ranking.
"""

from __future__ import annotations

import sqlite3

import pytest

from backend.audio_features import alchemy


def _seed_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "alchemy.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Two clusters: "calm" (low energy/danceability) and "hype" (high).
    # The user marks 2 calm as +, 1 hype as -. Result should rank the
    # remaining calm tracks ahead of the remaining hype tracks.
    samples = [
        # (key, bpm, energy, dance, valence, instr, acoustic)
        ("calm1", 80, 0.10, 0.10, 0.30, 0.80, 0.80),
        ("calm2", 82, 0.12, 0.10, 0.30, 0.80, 0.80),
        ("calm3", 78, 0.11, 0.12, 0.30, 0.80, 0.80),
        ("calm4", 84, 0.13, 0.11, 0.30, 0.80, 0.80),
        ("hype1", 140, 0.90, 0.90, 0.70, 0.05, 0.05),
        ("hype2", 142, 0.92, 0.91, 0.70, 0.05, 0.05),
        ("hype3", 138, 0.91, 0.92, 0.70, 0.05, 0.05),
        ("hype4", 144, 0.93, 0.90, 0.70, 0.05, 0.05),
    ]
    for k, bpm, e, d, v, i, a in samples:
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (k, k, "A", "Alb"),
        )
        conn.execute(
            """INSERT INTO track_audio_features
               (item_key, bpm, energy, danceability, valence, instrumentalness, acousticness)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (k, bpm, e, d, v, i, a),
        )
    conn.commit()
    return conn


def test_alchemy_prefers_calm_when_calm_added(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch)
    out = alchemy.compute_alchemy(
        conn,
        add_track_ids=["calm1", "calm2"],
        subtract_track_ids=["hype1"],
        limit=4,
    )
    assert out["results"], "expected at least one match"
    top_keys = [r["item_key"] for r in out["results"][:3]]
    # The remaining calm tracks should dominate the top of the ranking.
    assert sum(1 for k in top_keys if k.startswith("calm")) >= 2
    # Inputs are excluded from results.
    assert "calm1" not in [r["item_key"] for r in out["results"]]
    assert "calm2" not in [r["item_key"] for r in out["results"]]
    assert "hype1" not in [r["item_key"] for r in out["results"]]
    conn.close()


def test_alchemy_requires_add_tracks(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch)
    with pytest.raises(ValueError, match="ADD track"):
        alchemy.compute_alchemy(conn, add_track_ids=[], subtract_track_ids=[])
    conn.close()


def test_alchemy_rejects_unanalyzed_tracks(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch)
    with pytest.raises(KeyError):
        alchemy.compute_alchemy(conn, add_track_ids=["ghost"], subtract_track_ids=[])
    conn.close()


def test_alchemy_target_vector_arithmetic(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch)
    out = alchemy.compute_alchemy(
        conn,
        add_track_ids=["calm1"],
        subtract_track_ids=["hype1"],
        limit=1,
    )
    # The target should reflect "add - 0.5*subtract" in the *normalized* space.
    # We can't predict exact normalized values, but cosine similarity to the
    # nearest match should be high (>0.5).
    assert out["results"][0]["similarity"] > 0.5
    conn.close()
