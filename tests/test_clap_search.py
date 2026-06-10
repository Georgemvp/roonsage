"""Tests for backend.audio_features.clap_search with a mocked CLAP model.

The real ``laion-clap`` checkpoint is ~600 MB so we never load it here.
Instead we patch ``get_model`` to return a stub whose audio/text encoders
emit deterministic vectors, and verify the storage + cosine-search math.
"""

from __future__ import annotations

import sqlite3

import pytest

pytest.importorskip("numpy")

import backend.db.connection as _db_connection  # noqa: E402
from backend.audio_features import clap_search  # noqa: E402


class _FakeModel:
    """Stand-in for laion_clap.CLAP_Module returning predictable vectors."""

    def get_audio_embedding_from_filelist(self, paths, use_tensor=False):  # noqa: D401
        import numpy as np
        # Map filename suffix → unit vector along one axis so cosines are crisp.
        out = []
        for p in paths:
            v = np.zeros(clap_search.EMBEDDING_DIM, dtype=np.float32)
            if "calm" in p:
                v[0] = 1.0
            elif "energetic" in p:
                v[1] = 1.0
            else:
                v[2] = 1.0
            out.append(v)
        return np.stack(out)

    def get_text_embedding(self, texts, use_tensor=False):  # noqa: D401
        import numpy as np
        out = []
        for t in texts:
            v = np.zeros(clap_search.EMBEDDING_DIM, dtype=np.float32)
            tl = t.lower()
            if "calm" in tl or "ambient" in tl:
                v[0] = 1.0
            elif "energetic" in tl or "loud" in tl:
                v[1] = 1.0
            else:
                v[2] = 1.0
            out.append(v)
        return np.stack(out)


@pytest.fixture
def seeded_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "clap.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    samples = [
        ("c1", "Calm 1", "/music/calm1.flac"),
        ("c2", "Calm 2", "/music/calm2.flac"),
        ("e1", "Energy 1", "/music/energetic1.flac"),
        ("e2", "Energy 2", "/music/energetic2.flac"),
    ]
    for k, title, path in samples:
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (k, title, "A", "Alb"),
        )
        conn.execute(
            "INSERT INTO track_audio_features (item_key, file_path) VALUES (?, ?)",
            (k, path),
        )
    conn.commit()
    return conn


def test_batch_analyze_stores_embeddings(seeded_db, monkeypatch):
    monkeypatch.setattr(clap_search, "get_model", lambda: _FakeModel())
    monkeypatch.setattr("backend.config.get_clap_model", lambda: "fake/clap")
    out = clap_search.batch_analyze_clap(seeded_db)
    assert out["status"] == "complete"
    assert out["n_done"] == 4
    row = seeded_db.execute("SELECT COUNT(*) AS n FROM clap_embeddings").fetchone()
    assert row["n"] == 4


def test_search_by_text_ranks_semantically(seeded_db, monkeypatch):
    monkeypatch.setattr(clap_search, "get_model", lambda: _FakeModel())
    monkeypatch.setattr("backend.config.get_clap_model", lambda: "fake/clap")
    clap_search.batch_analyze_clap(seeded_db)

    results = clap_search.search_by_text(seeded_db, "calm ambient piano", limit=4)
    # "calm/ambient" → axis 0, so calm tracks should rank above energy tracks.
    assert results, "expected at least one result"
    top_ids = [r["item_key"] for r in results[:2]]
    assert "c1" in top_ids or "c2" in top_ids
    assert all(0.0 <= r["similarity"] <= 1.0 for r in results)


def test_search_returns_empty_when_no_embeddings(seeded_db, monkeypatch):
    monkeypatch.setattr(clap_search, "get_model", lambda: _FakeModel())
    assert clap_search.search_by_text(seeded_db, "anything", limit=10) == []


def test_get_model_returns_none_when_disabled(monkeypatch):
    clap_search.reset_model()
    monkeypatch.setattr("backend.config.get_clap_enabled", lambda: False)
    assert clap_search.get_model() is None


def test_status_starts_idle(seeded_db):
    s = clap_search.get_status(seeded_db)
    assert s["status"] == "idle"
