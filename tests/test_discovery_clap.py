"""Tests for the CLAP-powered "Sounds Like Your Week" discovery section.

The CLAP model itself is never loaded — we write fake float32 vectors
directly into ``clap_embeddings`` so the cosine math is the only thing under
test.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

pytest.importorskip("numpy")

import numpy as np  # noqa: E402

import backend.db as _db  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def tmp_db(tmp_path, monkeypatch):
    db_path = tmp_path / "test_discovery_clap.db"
    monkeypatch.setattr(_db, "DB_PATH", db_path)
    monkeypatch.setattr(_db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(_db, "_schema_initialized", False)
    from backend.db import ensure_db_initialized
    conn = ensure_db_initialized()
    conn.close()
    return db_path


def _conn():
    from backend.db import get_db_connection
    return get_db_connection()


def _axis_vec(axis: int, dim: int = 512) -> bytes:
    v = np.zeros(dim, dtype=np.float32)
    v[axis] = 1.0
    return v.tobytes()


def _insert_track(conn, item_key, title, artist, album="Album", is_live=0):
    conn.execute(
        "INSERT OR REPLACE INTO tracks (item_key, title, artist, album, is_live) VALUES (?, ?, ?, ?, ?)",
        (item_key, title, artist, album, is_live),
    )


def _insert_embedding(conn, item_key, axis):
    conn.execute(
        "INSERT OR REPLACE INTO clap_embeddings (item_key, embedding, model) VALUES (?, ?, ?)",
        (item_key, _axis_vec(axis), "fake"),
    )


def _insert_history(conn, artist, title, days_ago=0, skipped=0):
    ts = (datetime.now(UTC) - timedelta(days=days_ago)).strftime("%Y-%m-%d %H:%M:%S")
    conn.execute(
        "INSERT INTO listening_history (artist, track_title, timestamp, skipped) VALUES (?, ?, ?, ?)",
        (artist, title, ts, skipped),
    )


# ---------------------------------------------------------------------------
# get_sounds_like_your_week
# ---------------------------------------------------------------------------


class TestSoundsLikeYourWeek:
    def test_returns_empty_when_no_embeddings(self, tmp_db):
        from backend.discovery import get_sounds_like_your_week
        out = get_sounds_like_your_week()
        assert out["tracks"] == []
        assert "CLAP" in (out["message"] or "")

    def test_returns_empty_when_too_few_recent_plays(self, tmp_db):
        from backend.discovery import get_sounds_like_your_week
        conn = _conn()
        try:
            _insert_track(conn, "k1", "A1", "X")
            _insert_embedding(conn, "k1", 0)
            # 1 play in last week, none in last 30 days otherwise → < 3 in both windows
            _insert_history(conn, "X", "A1", days_ago=2)
            conn.commit()
        finally:
            conn.close()
        out = get_sounds_like_your_week()
        assert out["tracks"] == []
        assert out["source_count"] == 1
        # Falls back to 30 days but still <3
        assert out["window_days"] == 30

    def test_ranks_unplayed_closest_to_weekly_centroid(self, tmp_db):
        from backend.discovery import get_sounds_like_your_week
        conn = _conn()
        try:
            # Played tracks all on axis 0 → centroid points along axis 0
            for i in range(3):
                key = f"played{i}"
                _insert_track(conn, key, f"Played {i}", "Artist0")
                _insert_embedding(conn, key, 0)
                _insert_history(conn, "Artist0", f"Played {i}", days_ago=2)

            # Unplayed pool: one on axis 0 (close), one on axis 1 (far)
            _insert_track(conn, "near", "Near Match", "ArtistN")
            _insert_embedding(conn, "near", 0)
            _insert_track(conn, "far", "Far Match", "ArtistF")
            _insert_embedding(conn, "far", 1)
            conn.commit()
        finally:
            conn.close()

        out = get_sounds_like_your_week(limit=5)
        keys = [t["item_key"] for t in out["tracks"]]
        # Played tracks must NOT appear; near must outrank far
        assert "played0" not in keys
        assert keys[0] == "near"
        assert "far" in keys  # included but below near
        assert out["tracks"][0]["match_pct"] >= out["tracks"][-1]["match_pct"]
        assert out["window_days"] == 7
        assert out["source_count"] == 3

    def test_falls_back_to_30_day_window(self, tmp_db):
        from backend.discovery import get_sounds_like_your_week
        conn = _conn()
        try:
            # Only old plays (15-25 days ago), enough for the 30-day fallback
            for i in range(3):
                key = f"played{i}"
                _insert_track(conn, key, f"Played {i}", "Artist0")
                _insert_embedding(conn, key, 0)
                _insert_history(conn, "Artist0", f"Played {i}", days_ago=15 + i)

            _insert_track(conn, "near", "Near", "ArtistN")
            _insert_embedding(conn, "near", 0)
            conn.commit()
        finally:
            conn.close()

        out = get_sounds_like_your_week(limit=5)
        assert out["window_days"] == 30
        assert any(t["item_key"] == "near" for t in out["tracks"])

    def test_excludes_live_tracks_from_recommendations(self, tmp_db):
        from backend.discovery import get_sounds_like_your_week
        conn = _conn()
        try:
            for i in range(3):
                key = f"p{i}"
                _insert_track(conn, key, f"Played {i}", "A")
                _insert_embedding(conn, key, 0)
                _insert_history(conn, "A", f"Played {i}", days_ago=1)
            # Live unplayed track on the same axis — should be filtered out
            _insert_track(conn, "live1", "Live Concert", "B", is_live=1)
            _insert_embedding(conn, "live1", 0)
            conn.commit()
        finally:
            conn.close()

        out = get_sounds_like_your_week()
        assert not any(t["item_key"] == "live1" for t in out["tracks"])


# ---------------------------------------------------------------------------
# /api/discovery/sections — only includes the section when CLAP is enabled
# ---------------------------------------------------------------------------


class TestDiscoverySectionsRoute:
    def test_section_omitted_when_clap_disabled(self, tmp_db, monkeypatch):
        # Even with embeddings present, disabling CLAP should suppress the section.
        monkeypatch.setattr("backend.routes.discovery.get_clap_enabled", lambda: False)
        conn = _conn()
        try:
            _insert_track(conn, "k", "T", "A")
            _insert_embedding(conn, "k", 0)
            conn.commit()
        finally:
            conn.close()

        from backend.routes.discovery import _sounds_like_your_week_section
        assert _sounds_like_your_week_section() is None

    def test_section_omitted_when_no_embeddings(self, tmp_db, monkeypatch):
        monkeypatch.setattr("backend.routes.discovery.get_clap_enabled", lambda: True)
        from backend.routes.discovery import _sounds_like_your_week_section
        assert _sounds_like_your_week_section() is None

    def test_section_included_when_clap_on_and_data_present(self, tmp_db, monkeypatch):
        monkeypatch.setattr("backend.routes.discovery.get_clap_enabled", lambda: True)
        conn = _conn()
        try:
            for i in range(3):
                key = f"p{i}"
                _insert_track(conn, key, f"P{i}", "A")
                _insert_embedding(conn, key, 0)
                _insert_history(conn, "A", f"P{i}", days_ago=1)
            _insert_track(conn, "n", "Near", "B")
            _insert_embedding(conn, "n", 0)
            conn.commit()
        finally:
            conn.close()

        from backend.routes.discovery import _sounds_like_your_week_section
        section = _sounds_like_your_week_section()
        assert section is not None
        assert section["tracks"]
