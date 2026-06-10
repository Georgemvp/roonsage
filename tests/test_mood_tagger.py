"""Tests for backend.audio_features.mood_tagger with mocked CLAP encoders.

We never load the real CLAP model. ``_embed_text`` is patched to return
unit vectors along distinct axes for "calm"-like vs "energetic"-like
prompts; CLAP audio embeddings are seeded directly into ``clap_embeddings``
so K-Means has predictable inputs.
"""

from __future__ import annotations

import sqlite3

import pytest

pytest.importorskip("numpy")
pytest.importorskip("sklearn")

import numpy as np  # noqa: E402

import backend.db.connection as _db_connection  # noqa: E402
from backend.audio_features import clap_search, mood_tagger  # noqa: E402

EMBED_DIM = clap_search.EMBEDDING_DIM


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _axis_vec(axis: int) -> np.ndarray:
    v = np.zeros(EMBED_DIM, dtype=np.float32)
    v[axis] = 1.0
    return v


def _fake_embed_text(text: str) -> np.ndarray:
    """Return a unit vector along axis 0 for calm-ish prompts, axis 1 otherwise."""
    tl = text.lower()
    if any(w in tl for w in ("calm", "ambient", "peaceful", "soothing", "dreamy", "ethereal", "atmospheric")):
        return _axis_vec(0)
    if any(w in tl for w in ("energetic", "upbeat", "fast", "high energy", "driving")):
        return _axis_vec(1)
    # Other moods → axis 2 so they never win.
    return _axis_vec(2)


@pytest.fixture
def seeded_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "moods.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Patch the CLAP text encoder for the mood tagger.
    monkeypatch.setattr(clap_search, "_embed_text", _fake_embed_text)

    # Seed 12 calm tracks (axis 0) + 12 energetic tracks (axis 1).
    rows: list[tuple[str, np.ndarray]] = []
    for i in range(12):
        rows.append((f"calm-{i}", _axis_vec(0)))
    for i in range(12):
        rows.append((f"energy-{i}", _axis_vec(1)))

    for key, vec in rows:
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (key, key, "A", "Alb"),
        )
        conn.execute(
            "INSERT INTO clap_embeddings (item_key, embedding, model) VALUES (?, ?, ?)",
            (key, vec.tobytes(), "fake/clap"),
        )
    conn.commit()
    return conn


# ---------------------------------------------------------------------------
# run_mood_tagging
# ---------------------------------------------------------------------------


def test_run_mood_tagging_assigns_moods(seeded_db):
    out = mood_tagger.run_mood_tagging(conn=seeded_db, k=2)
    assert out["status"] == "complete"
    assert out["n_tracks"] == 24
    assert out["n_clusters"] == 2

    # Each track should have a primary mood from the default vocabulary.
    rows = seeded_db.execute(
        "SELECT track_id, mood_primary, mood_secondary, confidence FROM track_mood_tags"
    ).fetchall()
    assert len(rows) == 24
    moods_seen = {r["mood_primary"] for r in rows}
    # Both classes are present, so we expect distinct primary moods.
    assert len(moods_seen) >= 2
    for r in rows:
        assert r["mood_primary"] in mood_tagger.DEFAULT_MOODS
        assert 0.0 <= r["confidence"] <= 1.0 + 1e-6


def test_run_mood_tagging_below_minimum_returns_failed(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "tiny.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Seed only 3 embeddings — well below the floor.
    for i in range(3):
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (f"k{i}", f"t{i}", "A", "Al"),
        )
        conn.execute(
            "INSERT INTO clap_embeddings (item_key, embedding, model) VALUES (?, ?, ?)",
            (f"k{i}", _axis_vec(0).tobytes(), "fake/clap"),
        )
    conn.commit()
    monkeypatch.setattr(clap_search, "_embed_text", _fake_embed_text)

    out = mood_tagger.run_mood_tagging(conn=conn, k=4)
    assert out["status"] == "failed"
    assert "at least" in out["error"]


def test_get_mood_tag_counts_returns_descending(seeded_db):
    mood_tagger.run_mood_tagging(conn=seeded_db, k=2)
    counts = mood_tagger.get_mood_tag_counts(seeded_db)
    assert counts, "expected at least one mood"
    # All track_counts should be > 0 and sorted descending.
    assert all(c["track_count"] > 0 for c in counts)
    assert counts == sorted(counts, key=lambda c: -c["track_count"])
    assert sum(c["track_count"] for c in counts) == 24


def test_get_tracks_for_mood_returns_only_matching(seeded_db):
    mood_tagger.run_mood_tagging(conn=seeded_db, k=2)
    counts = mood_tagger.get_mood_tag_counts(seeded_db)
    top_mood = counts[0]["mood"]
    tracks = mood_tagger.get_tracks_for_mood(seeded_db, top_mood, limit=200)
    assert tracks, "top mood should return tracks"
    for t in tracks:
        # Track must carry the mood as primary or secondary.
        assert top_mood in (t["mood_primary"], t["mood_secondary"])


def test_get_mood_for_track_returns_none_when_missing(seeded_db):
    assert mood_tagger.get_mood_for_track(seeded_db, "nonexistent") is None


def test_status_starts_idle(seeded_db):
    s = mood_tagger.get_status(seeded_db)
    assert s["status"] == "idle"


def test_status_complete_after_run(seeded_db):
    mood_tagger.run_mood_tagging(conn=seeded_db, k=2)
    s = mood_tagger.get_status(seeded_db)
    assert s["status"] == "complete"
    assert s["n_tracks"] == 24
    assert s["n_clusters"] == 2
    assert s["finished_at"]


def test_get_mood_tags_for_keys(seeded_db):
    mood_tagger.run_mood_tagging(conn=seeded_db, k=2)
    keys = ["calm-0", "calm-1", "energy-0", "missing"]
    out = mood_tagger.get_mood_tags_for_keys(seeded_db, keys)
    # missing key should not appear
    assert "missing" not in out
    assert set(out.keys()) <= {"calm-0", "calm-1", "energy-0"}
    for moods in out.values():
        assert 1 <= len(moods) <= 2
        for m in moods:
            assert m in mood_tagger.DEFAULT_MOODS


def test_rerun_wipes_previous_tags(seeded_db):
    mood_tagger.run_mood_tagging(conn=seeded_db, k=2)
    # Insert a stale row that no longer matches any real track.
    seeded_db.execute(
        "INSERT INTO track_mood_tags (track_id, mood_primary) VALUES (?, ?)",
        ("ghost-track", "happy"),
    )
    seeded_db.commit()
    assert seeded_db.execute(
        "SELECT COUNT(*) AS n FROM track_mood_tags WHERE track_id='ghost-track'"
    ).fetchone()["n"] == 1

    mood_tagger.run_mood_tagging(conn=seeded_db, k=2)
    assert seeded_db.execute(
        "SELECT COUNT(*) AS n FROM track_mood_tags WHERE track_id='ghost-track'"
    ).fetchone()["n"] == 0
