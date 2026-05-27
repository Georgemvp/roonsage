"""Tests for backend.lyrics.mood_lyrics — mood-centroid playlists.

The real GTE-multilingual model is never loaded. We monkeypatch
``embedder.embed_text`` to return axis-aligned vectors so the centroid math
collapses to a clean integer ranking.
"""

from __future__ import annotations

import sqlite3

import pytest

pytest.importorskip("numpy")

from backend.lyrics import embedder, mood_lyrics  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _seed_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "moods.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)
    return conn


# A handful of mood→axis mappings sufficient for testing. Any query whose
# text contains one of the keywords below picks that axis. Unknowns → axis 7.
_AXIS_MAP = {
    "loss": 0, "rain": 0, "alone": 0, "tears": 0, "goodbye": 0, "fading": 0,
    "love": 1, "heart": 1, "together": 1, "kiss": 1, "forever": 1, "darling": 1,
    "rise": 2, "fight": 2, "strong": 2, "overcome": 2, "freedom": 2, "stand": 2,
    "remember": 3, "old days": 3, "childhood": 3, "home": 3, "memory": 3, "time": 3,
    "dance": 6, "sun": 6, "laugh": 6, "party": 6, "celebrate": 6, "alive": 6,
}


def _fake_embed_text(text: str):
    import numpy as np

    v = np.zeros(embedder.EMBEDDING_DIM, dtype=np.float32)
    tl = text.lower()
    for kw, axis in _AXIS_MAP.items():
        if kw in tl:
            v[axis] = 1.0
            return v
    v[7] = 1.0
    return v


def _insert_track_with_embedding(conn, item_key, lyrics_text, title=None, artist="A"):
    import numpy as np

    conn.execute(
        "INSERT OR REPLACE INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
        (item_key, title or item_key, artist, "Alb"),
    )
    conn.execute(
        """INSERT OR REPLACE INTO lyrics_data
           (item_key, lyrics, source, extracted_at)
           VALUES (?, ?, 'tag', '2026-01-01')""",
        (item_key, lyrics_text),
    )
    vec = _fake_embed_text(lyrics_text)
    conn.execute(
        """INSERT OR REPLACE INTO lyrics_embeddings
           (item_key, embedding, model_version) VALUES (?, ?, 'fake')""",
        (item_key, np.asarray(vec, dtype=np.float32).tobytes()),
    )


# ---------------------------------------------------------------------------
# mood_centroid
# ---------------------------------------------------------------------------


class TestMoodCentroid:
    def test_unknown_mood_raises(self, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
        with pytest.raises(KeyError):
            mood_lyrics.mood_centroid("not-a-mood")

    def test_centroid_is_unit_vector(self, monkeypatch):
        import numpy as np
        monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
        c = mood_lyrics.mood_centroid("melancholic")
        assert pytest.approx(float(np.linalg.norm(c)), abs=1e-6) == 1.0


# ---------------------------------------------------------------------------
# get_lyrics_mood_playlist
# ---------------------------------------------------------------------------


class TestMoodPlaylist:
    def test_returns_empty_when_no_embeddings(self, tmp_path, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            assert mood_lyrics.get_lyrics_mood_playlist("melancholic", 10, conn) == []
        finally:
            conn.close()

    def test_ranks_thematically_matching_tracks_first(self, tmp_path, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            # Melancholic candidates
            _insert_track_with_embedding(conn, "mel1", "loss and tears")
            _insert_track_with_embedding(conn, "mel2", "alone in the rain")
            # Joyful candidates
            _insert_track_with_embedding(conn, "joy1", "dance under the sun")
            # Empowering candidate
            _insert_track_with_embedding(conn, "emp1", "rise and fight")
            conn.commit()

            results = mood_lyrics.get_lyrics_mood_playlist("melancholic", 4, conn)
            assert results
            top_keys = [r["item_key"] for r in results[:2]]
            assert "mel1" in top_keys and "mel2" in top_keys
            assert all("similarity" in r and r["similarity"] is not None for r in results)
            assert all(r["mood"] == "melancholic" for r in results)
        finally:
            conn.close()

    def test_deduplicates_by_artist_title(self, tmp_path, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            # Same artist+title across two item_keys (different "editions")
            _insert_track_with_embedding(conn, "a1", "loss and tears",
                                         title="Sad Song", artist="Same Artist")
            _insert_track_with_embedding(conn, "a2", "loss and tears",
                                         title="Sad Song", artist="Same Artist")
            conn.commit()

            results = mood_lyrics.get_lyrics_mood_playlist("melancholic", 10, conn)
            seen = {(r["artist"], r["title"]) for r in results}
            assert len(seen) == len(results)
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# get_moods_with_counts
# ---------------------------------------------------------------------------


class TestMoodsWithCounts:
    def test_returns_zero_counts_when_index_empty(self, tmp_path, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            out = mood_lyrics.get_moods_with_counts(conn)
            assert {m["mood"] for m in out} == set(mood_lyrics.available_moods())
            assert all(m["track_count"] == 0 for m in out)
        finally:
            conn.close()

    def test_counts_only_above_threshold(self, tmp_path, monkeypatch):
        monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
        conn = _seed_db(tmp_path, monkeypatch)
        try:
            _insert_track_with_embedding(conn, "mel1", "loss and tears")
            _insert_track_with_embedding(conn, "joy1", "dance and laugh")
            conn.commit()
            out = {m["mood"]: m["track_count"] for m in mood_lyrics.get_moods_with_counts(conn)}
            # Both moods should pick up at least one track above the 0.2 floor.
            assert out["melancholic"] >= 1
            assert out["joyful"] >= 1
        finally:
            conn.close()
