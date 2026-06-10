"""Tests for backend.lyrics.cross_modal — blended lyrics+CLAP similarity.

We never load any real model. Both ``clap_embeddings`` and ``lyrics_embeddings``
are populated directly with axis-aligned vectors so the cosine math is
predictable, and ``embedder.embed_text`` is monkeypatched for the
``get_thematic_taste`` path.
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

import pytest

pytest.importorskip("numpy")

import numpy as np  # noqa: E402

import backend.db.connection as _db_connection  # noqa: E402
from backend.lyrics import cross_modal, embedder  # noqa: E402

LYRICS_DIM = embedder.EMBEDDING_DIM  # 768
CLAP_DIM = 512


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _seed_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "cm.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)
    return conn


def _vec(axis, dim):
    v = np.zeros(dim, dtype=np.float32)
    v[axis] = 1.0
    return v.tobytes()


def _insert(conn, item_key, lyr_axis, clap_axis, *, artist="A", title=None):
    conn.execute(
        "INSERT OR REPLACE INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
        (item_key, title or item_key, artist, "Alb"),
    )
    if lyr_axis is not None:
        conn.execute(
            """INSERT OR REPLACE INTO lyrics_embeddings
               (item_key, embedding, model_version) VALUES (?, ?, 'fake')""",
            (item_key, _vec(lyr_axis, LYRICS_DIM)),
        )
    if clap_axis is not None:
        conn.execute(
            "INSERT OR REPLACE INTO clap_embeddings (item_key, embedding, model) VALUES (?, ?, 'fake')",
            (item_key, _vec(clap_axis, CLAP_DIM)),
        )


def _add_history(conn, artist, title, n=1):
    ts = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
    for _ in range(n):
        conn.execute(
            "INSERT INTO listening_history (artist, track_title, timestamp) VALUES (?, ?, ?)",
            (artist, title, ts),
        )


# ---------------------------------------------------------------------------
# cross_modal_similarity
# ---------------------------------------------------------------------------


class TestCrossModalSimilarity:
    def test_returns_empty_when_seed_missing(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            assert cross_modal.cross_modal_similarity("ghost", conn, 10) == []
        finally:
            conn.close()

    def test_returns_empty_when_only_one_embedding(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            _insert(conn, "seed", lyr_axis=0, clap_axis=None)
            _insert(conn, "other", lyr_axis=0, clap_axis=0)
            conn.commit()
            assert cross_modal.cross_modal_similarity("seed", conn, 10) == []
        finally:
            conn.close()

    def test_blends_lyrics_and_clap(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            # Seed at axis 0 on both modalities
            _insert(conn, "seed", lyr_axis=0, clap_axis=0, title="Seed", artist="S")
            # Candidate matching both modalities → max score
            _insert(conn, "both",  lyr_axis=0, clap_axis=0, title="Both", artist="X")
            # Matches lyrics only
            _insert(conn, "lyric", lyr_axis=0, clap_axis=1, title="Lyric", artist="Y")
            # Matches audio only
            _insert(conn, "audio", lyr_axis=1, clap_axis=0, title="Audio", artist="Z")
            # Matches neither
            _insert(conn, "none",  lyr_axis=2, clap_axis=2, title="None", artist="W")
            conn.commit()

            results = cross_modal.cross_modal_similarity("seed", conn, 10)
            keys = [r["item_key"] for r in results]
            assert keys, "expected results"
            # Seed must never appear in its own neighbours
            assert "seed" not in keys
            # "both" must outrank the single-modality matches.
            assert keys[0] == "both"
            # Both single-modality matches get 0.5; the unrelated one gets ~0.
            assert results[0]["combined_similarity"] > results[-1]["combined_similarity"]
            # Confirm the per-axis scores survived to the response.
            both_row = next(r for r in results if r["item_key"] == "both")
            assert both_row["lyrics_similarity"] == pytest.approx(1.0, abs=1e-4)
            assert both_row["clap_similarity"] == pytest.approx(1.0, abs=1e-4)
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# get_thematic_taste
# ---------------------------------------------------------------------------


def _stub_embed_text(text: str):
    """Map any 'loss'/'tears' query → axis 0 (melancholic family)."""
    v = np.zeros(LYRICS_DIM, dtype=np.float32)
    tl = text.lower()
    melancholic_kw = {"loss", "rain", "alone", "tears", "goodbye", "fading"}
    joyful_kw = {"dance", "sun", "laugh", "party", "celebrate", "alive"}
    if any(kw in tl for kw in melancholic_kw):
        v[0] = 1.0
    elif any(kw in tl for kw in joyful_kw):
        v[1] = 1.0
    else:
        v[2] = 1.0
    return v


class TestThematicTaste:
    def test_returns_message_when_too_few_top_tracks(self, tmp_path, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _stub_embed_text)
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            out = cross_modal.get_thematic_taste(conn)
            assert out["moods"] == []
            assert "Not enough" in (out["message"] or "")
        finally:
            conn.close()

    def test_ranks_melancholic_when_user_plays_axis0_tracks(self, tmp_path, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _stub_embed_text)
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            # 3 user-played tracks, lyrics axis 0 = melancholic
            for i in range(3):
                key = f"k{i}"
                _insert(conn, key, lyr_axis=0, clap_axis=None,
                        title=f"T{i}", artist=f"A{i}")
                _add_history(conn, f"A{i}", f"T{i}", n=5)
            conn.commit()

            out = cross_modal.get_thematic_taste(conn)
            assert out["moods"], "expected at least one mood entry"
            assert out["n_source_tracks"] == 3
            # Melancholic should rank above joyful for an axis-0 user
            scores = {m["mood"]: m["score"] for m in out["moods"]}
            assert scores["melancholic"] > scores["joyful"]
            # Top of the ranking is melancholic
            assert out["moods"][0]["mood"] == "melancholic"
            assert all(0.0 <= m["score"] <= 1.0 for m in out["moods"])
        finally:
            conn.close()
