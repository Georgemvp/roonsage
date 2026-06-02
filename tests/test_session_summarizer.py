"""Tests for backend.session_summarizer — session detection, energy curve, helpers."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta
from unittest.mock import patch

from backend import db as db_module
from backend import session_summarizer

# ---------------------------------------------------------------------------
# DB setup helpers
# ---------------------------------------------------------------------------

BASE = datetime(2026, 6, 1, 10, 0, 0)  # fixed past reference time


def _setup_db(tmp_path, monkeypatch):
    db_path = tmp_path / "test.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)
    conn.close()
    return db_path


def _ts(base: datetime, minutes_offset: int = 0) -> str:
    return (base + timedelta(minutes=minutes_offset)).strftime("%Y-%m-%d %H:%M:%S")


def _insert_listens(db_path, listens: list[dict]) -> None:
    conn = sqlite3.connect(str(db_path))
    for listen in listens:
        conn.execute(
            """INSERT INTO listening_history
               (timestamp, zone_name, track_title, artist, album, genre,
                played_seconds, duration_seconds, skipped, source)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'library')""",
            (
                listen["timestamp"],
                listen.get("zone_name", "Living Room"),
                listen.get("track_title", "Track"),
                listen.get("artist", "Artist"),
                listen.get("album", ""),
                listen.get("genre", ""),
                listen.get("played_seconds", 240),
                listen.get("duration_seconds", 240),
                listen.get("skipped", 0),
            ),
        )
    conn.commit()
    conn.close()


def _insert_tracks_with_features(db_path, entries: list[dict]) -> None:
    conn = sqlite3.connect(str(db_path))
    for e in entries:
        conn.execute(
            "INSERT OR IGNORE INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (e["item_key"], e["title"], e["artist"], e.get("album", "")),
        )
        conn.execute(
            """INSERT OR IGNORE INTO track_audio_features (item_key, bpm, energy)
               VALUES (?, ?, ?)""",
            (e["item_key"], e.get("bpm", 120), e.get("energy")),
        )
    conn.commit()
    conn.close()


# ---------------------------------------------------------------------------
# detect_sessions
# ---------------------------------------------------------------------------


class TestDetectSessions:
    def test_no_listens_returns_zero(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        assert session_summarizer.detect_sessions() == 0

    def test_single_session_detected(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        listens = [
            {"timestamp": _ts(BASE, i), "track_title": f"Track {i}", "artist": "A"}
            for i in range(5)
        ]
        _insert_listens(db_path, listens)
        assert session_summarizer.detect_sessions() == 1

    def test_gap_splits_into_two_sessions(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        # 4 listens, then 35-minute gap, then 4 more
        before = [{"timestamp": _ts(BASE, i), "track_title": f"T{i}", "artist": "A"} for i in range(4)]
        after = [{"timestamp": _ts(BASE, 35 + i), "track_title": f"T{10 + i}", "artist": "A"} for i in range(4)]
        _insert_listens(db_path, before + after)
        assert session_summarizer.detect_sessions() == 2

    def test_min_tracks_filters_small_sessions(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        # Only 2 listens — below default min_tracks=3
        listens = [{"timestamp": _ts(BASE, i), "track_title": f"T{i}", "artist": "A"} for i in range(2)]
        _insert_listens(db_path, listens)
        assert session_summarizer.detect_sessions(min_tracks=3) == 0

    def test_delay_guard_skips_too_recent(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        now = datetime.now()
        # Insert 4 listens that ended only 1 minute ago — within delay_minutes=5
        listens = [
            {"timestamp": _ts(now, -(4 - i)), "track_title": f"T{i}", "artist": "A"}
            for i in range(4)
        ]
        _insert_listens(db_path, listens)
        assert session_summarizer.detect_sessions(delay_minutes=5) == 0

    def test_no_redetection_after_existing_session(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        listens = [
            {"timestamp": _ts(BASE, i), "track_title": f"T{i}", "artist": "A"}
            for i in range(5)
        ]
        _insert_listens(db_path, listens)
        first = session_summarizer.detect_sessions()
        assert first == 1
        second = session_summarizer.detect_sessions()
        assert second == 0

    def test_session_stores_correct_metadata(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        listens = [
            {"timestamp": _ts(BASE, i), "track_title": f"T{i}", "artist": "A",
             "genre": "Jazz", "played_seconds": 180}
            for i in range(4)
        ]
        _insert_listens(db_path, listens)
        session_summarizer.detect_sessions()
        result = session_summarizer.list_sessions()
        assert result["total"] == 1
        session = result["sessions"][0]
        assert session["track_count"] == 4
        assert "Jazz" in session["genres"]
        assert session["summarized"] is False


# ---------------------------------------------------------------------------
# _energy_curve (batch query)
# ---------------------------------------------------------------------------


class TestEnergyCurve:
    def test_returns_energy_for_known_tracks(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_tracks_with_features(db_path, [
            {"item_key": "k1", "title": "Song A", "artist": "Artist X", "energy": 0.75},
            {"item_key": "k2", "title": "Song B", "artist": "Artist Y", "energy": 0.40},
        ])
        listens = [
            {"track_title": "Song A", "artist": "Artist X"},
            {"track_title": "Song B", "artist": "Artist Y"},
        ]
        curve = session_summarizer._energy_curve(listens)
        assert len(curve) == 2
        assert abs(curve[0] - 0.75) < 0.01
        assert abs(curve[1] - 0.40) < 0.01

    def test_skips_unknown_tracks(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        listens = [{"track_title": "Missing Song", "artist": "Nobody"}]
        assert session_summarizer._energy_curve(listens) == []

    def test_returns_empty_for_no_listens(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        assert session_summarizer._energy_curve([]) == []

    def test_case_insensitive_matching(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_tracks_with_features(db_path, [
            {"item_key": "k1", "title": "SONG X", "artist": "BAND A", "energy": 0.60},
        ])
        listens = [{"track_title": "song x", "artist": "band a"}]
        curve = session_summarizer._energy_curve(listens)
        assert len(curve) == 1
        assert abs(curve[0] - 0.60) < 0.01

    def test_partial_artist_match(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_tracks_with_features(db_path, [
            {"item_key": "k1", "title": "Song", "artist": "The Big Band", "energy": 0.50},
        ])
        listens = [{"track_title": "Song", "artist": "Big Band"}]
        curve = session_summarizer._energy_curve(listens)
        assert len(curve) == 1

    def test_skips_listens_missing_title_or_artist(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        listens = [
            {"track_title": "", "artist": "Artist"},
            {"track_title": "Title", "artist": ""},
            {},
        ]
        assert session_summarizer._energy_curve(listens) == []


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------


class TestQueryHelpers:
    def _seed_sessions(self, db_path) -> None:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        for i in range(3):
            conn.execute(
                """INSERT INTO listening_sessions
                   (started_at, ended_at, zone_name, track_count,
                    total_duration_minutes, genres_json,
                    summary_text, mood_arc, standout_tracks_json,
                    energy_curve_json, summarized)
                   VALUES (?, ?, ?, ?, ?, '["Rock"]', '', '', '[]', '[]', 0)""",
                (
                    f"2026-06-0{i+1} 10:00:00",
                    f"2026-06-0{i+1} 11:00:00",
                    "Living Room",
                    10 + i,
                    60.0,
                ),
            )
        conn.commit()
        conn.close()

    def test_list_sessions_returns_all(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        self._seed_sessions(db_path)
        result = session_summarizer.list_sessions()
        assert result["total"] == 3
        assert len(result["sessions"]) == 3

    def test_list_sessions_pagination(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        self._seed_sessions(db_path)
        result = session_summarizer.list_sessions(limit=2, offset=0)
        assert len(result["sessions"]) == 2

    def test_get_session_returns_none_for_missing(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        assert session_summarizer.get_session(999) is None

    def test_get_session_includes_listens(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        self._seed_sessions(db_path)
        sessions = session_summarizer.list_sessions()["sessions"]
        session_id = sessions[0]["id"]
        out = session_summarizer.get_session(session_id)
        assert out is not None
        assert "listens" in out

    def test_session_stats_aggregate(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        self._seed_sessions(db_path)
        stats = session_summarizer.session_stats()
        assert stats["total_sessions"] == 3
        assert stats["avg_tracks"] > 0
        assert isinstance(stats["top_genres"], list)


# ---------------------------------------------------------------------------
# summarize_pending_sessions — feature-gated path
# ---------------------------------------------------------------------------


class TestSummarizePendingSessions:
    def test_returns_zero_when_background_ai_disabled(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        with patch("backend.session_summarizer.is_background_ai_enabled", return_value=False):
            import asyncio
            result = asyncio.run(session_summarizer.summarize_pending_sessions())
        assert result == 0

    def test_skipped_when_no_llm_client(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        conn = sqlite3.connect(str(db_path))
        conn.execute(
            """INSERT INTO listening_sessions
               (started_at, ended_at, zone_name, track_count,
                total_duration_minutes, genres_json,
                summary_text, mood_arc, standout_tracks_json,
                energy_curve_json, summarized)
               VALUES ('2026-06-01 10:00:00', '2026-06-01 11:00:00',
                       'LR', 5, 60.0, '[]', '', '', '[]', '[]', 0)"""
        )
        conn.commit()
        conn.close()

        with patch("backend.session_summarizer.is_background_ai_enabled", return_value=True), \
             patch("backend.session_summarizer.get_llm_client", return_value=None):
            import asyncio
            result = asyncio.run(session_summarizer.summarize_pending_sessions(limit=1))
        assert result == 0
