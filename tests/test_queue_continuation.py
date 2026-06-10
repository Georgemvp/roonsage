"""Tests for backend.queue_continuation — Camelot helpers, context gathering,
candidate pool, cooldown, zone-allow logic, and dedup token."""

from __future__ import annotations

import asyncio
import sqlite3
from datetime import UTC, datetime, timedelta
from unittest.mock import patch

import backend.db.connection as _db_connection
from backend import db as db_module
from backend import queue_continuation

# ---------------------------------------------------------------------------
# DB setup helpers
# ---------------------------------------------------------------------------


def _setup_db(tmp_path, monkeypatch):
    db_path = tmp_path / "test.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)
    conn.close()
    return db_path


def _insert_listens(db_path, listens: list[dict]) -> None:
    conn = sqlite3.connect(str(db_path))
    for i, listen in enumerate(listens):
        ts = (datetime.now() - timedelta(minutes=len(listens) - i)).strftime("%Y-%m-%d %H:%M:%S")
        conn.execute(
            """INSERT INTO listening_history
               (timestamp, zone_name, track_title, artist, album, genre,
                played_seconds, duration_seconds, skipped)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)""",
            (
                listen.get("timestamp", ts),
                listen.get("zone_name", "Living Room"),
                listen.get("track_title", f"Track {i}"),
                listen.get("artist", "Artist"),
                listen.get("album", ""),
                listen.get("genre", ""),
                listen.get("played_seconds", 240),
                listen.get("duration_seconds", 240),
            ),
        )
    conn.commit()
    conn.close()


def _insert_track_features(db_path, entries: list[dict]) -> None:
    conn = sqlite3.connect(str(db_path))
    for e in entries:
        conn.execute(
            "INSERT OR IGNORE INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (e["item_key"], e["title"], e["artist"], e.get("album", "")),
        )
        conn.execute(
            """INSERT OR IGNORE INTO track_audio_features
               (item_key, bpm, energy, valence, danceability, camelot, acousticness)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                e["item_key"],
                e.get("bpm", 120),
                e.get("energy", 0.5),
                e.get("valence", 0.5),
                e.get("danceability", 0.5),
                e.get("camelot"),
                e.get("acousticness", 0.3),
            ),
        )
    conn.commit()
    conn.close()


# ---------------------------------------------------------------------------
# _compatible_camelot
# ---------------------------------------------------------------------------


class TestCompatibleCamelot:
    def test_valid_key_includes_self(self):
        result = queue_continuation._compatible_camelot(["8A"])
        assert "8A" in result

    def test_valid_key_includes_parallel_minor(self):
        result = queue_continuation._compatible_camelot(["8A"])
        assert "8B" in result

    def test_valid_key_includes_adjacent_steps(self):
        result = queue_continuation._compatible_camelot(["8A"])
        # +1 step clockwise
        assert "9A" in result
        # -1 step counter-clockwise: (8-2) % 12 + 1 = 7
        assert "7A" in result

    def test_boundary_wraps_correctly(self):
        # 12A + 1 → 1A; 12A - 1 → 11A
        result = queue_continuation._compatible_camelot(["12A"])
        assert "1A" in result
        assert "11A" in result

    def test_key_1a_wraps_backwards(self):
        # 1A - 1 → 12A  (because (1 - 2) % 12 + 1 = 12)
        result = queue_continuation._compatible_camelot(["1A"])
        assert "12A" in result

    def test_empty_input_returns_empty(self):
        assert queue_continuation._compatible_camelot([]) == []

    def test_invalid_key_skipped(self):
        result = queue_continuation._compatible_camelot(["notakey", "", "X"])
        assert result == []

    def test_multiple_keys_merged(self):
        result = queue_continuation._compatible_camelot(["8A", "9A"])
        # Both keys' neighbourhoods merged — no duplicates
        assert len(result) == len(set(result))
        assert "8A" in result
        assert "9A" in result


# ---------------------------------------------------------------------------
# _gather_recent_context
# ---------------------------------------------------------------------------


class TestGatherRecentContext:
    def test_no_listens_returns_empty(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        ctx = queue_continuation._gather_recent_context("Living Room")
        assert ctx["listens"] == []
        assert ctx["features"] == {}

    def test_listens_without_features_have_empty_features(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_listens(db_path, [
            {"track_title": f"Song {i}", "artist": "Band", "zone_name": "LR"}
            for i in range(4)
        ])
        ctx = queue_continuation._gather_recent_context("LR")
        assert len(ctx["listens"]) == 4
        # No audio features in DB → n_with_features = 0
        assert ctx["features"].get("n_with_features", 0) == 0

    def test_listens_with_features_aggregated(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_listens(db_path, [
            {"track_title": "Song A", "artist": "Artist X", "zone_name": "LR"},
            {"track_title": "Song B", "artist": "Artist Y", "zone_name": "LR"},
        ])
        _insert_track_features(db_path, [
            {"item_key": "k1", "title": "Song A", "artist": "Artist X",
             "bpm": 120, "energy": 0.8, "camelot": "8A"},
            {"item_key": "k2", "title": "Song B", "artist": "Artist Y",
             "bpm": 100, "energy": 0.6, "camelot": "7A"},
        ])
        ctx = queue_continuation._gather_recent_context("LR")
        assert ctx["features"]["n_with_features"] == 2
        assert ctx["features"]["bpm"] == 110.0
        assert abs(ctx["features"]["energy"] - 0.7) < 0.01

    def test_global_context_when_zone_none(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_listens(db_path, [
            {"track_title": f"T{i}", "artist": "A", "zone_name": "Zone1"}
            for i in range(4)
        ])
        ctx = queue_continuation._gather_recent_context(None)
        assert len(ctx["listens"]) > 0

    def test_camelot_keys_extracted(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_listens(db_path, [
            {"track_title": "Song A", "artist": "Artist X", "zone_name": "Z"},
            {"track_title": "Song A", "artist": "Artist X", "zone_name": "Z"},
        ])
        _insert_track_features(db_path, [
            {"item_key": "k1", "title": "Song A", "artist": "Artist X", "camelot": "5B"},
        ])
        ctx = queue_continuation._gather_recent_context("Z")
        assert "5B" in ctx["camelot_keys"]


# ---------------------------------------------------------------------------
# _candidate_pool
# ---------------------------------------------------------------------------


class TestCandidatePool:
    def test_empty_when_no_bpm_or_keys(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        ctx: dict = {"features": {}, "camelot_keys": []}
        assert queue_continuation._candidate_pool(ctx) == []

    def test_filters_by_bpm_window(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_track_features(db_path, [
            {"item_key": "in_range", "title": "A", "artist": "X", "bpm": 120},
            {"item_key": "out_range", "title": "B", "artist": "Y", "bpm": 200},
        ])
        ctx = {"features": {"bpm": 120}, "camelot_keys": []}
        result = queue_continuation._candidate_pool(ctx, bpm_window=10)
        assert "in_range" in result
        assert "out_range" not in result

    def test_filters_by_camelot(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        _insert_track_features(db_path, [
            {"item_key": "match", "title": "A", "artist": "X", "camelot": "8A"},
            {"item_key": "no_match", "title": "B", "artist": "Y", "camelot": "3B"},
        ])
        ctx = {"features": {}, "camelot_keys": ["8A"]}
        compat = queue_continuation._compatible_camelot(["8A"])
        result = queue_continuation._candidate_pool(ctx)
        if "match" in result:
            assert "8A" in compat


# ---------------------------------------------------------------------------
# trigger_continuation — cooldown + disabled
# ---------------------------------------------------------------------------


class TestTriggerContinuation:
    def test_disabled_returns_skipped(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        with patch(
            "backend.queue_continuation.get_queue_continuation_config",
            return_value={"enabled": False, "cooldown_seconds": 1800,
                          "track_count": 12, "bpm_window": 10, "zones": []},
        ):
            result = asyncio.run(queue_continuation.trigger_continuation("zone1", "Zone One"))
        assert result["status"] == "skipped"
        assert "disabled" in result["reason"].lower()

    def test_cooldown_active_returns_skipped(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        # Record a very recent run
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        conn.execute(
            """INSERT INTO queue_continuation_log
               (zone_id, zone_name, last_fired_at, last_track_count, last_status)
               VALUES (?, ?, ?, ?, ?)""",
            ("zone1", "Zone One", datetime.now(UTC).isoformat(), 10, "queued"),
        )
        conn.commit()
        conn.close()

        with patch(
            "backend.queue_continuation.get_queue_continuation_config",
            return_value={"enabled": True, "cooldown_seconds": 1800,
                          "track_count": 12, "bpm_window": 10, "zones": []},
        ):
            result = asyncio.run(queue_continuation.trigger_continuation("zone1", "Zone One"))
        assert result["status"] == "skipped"
        assert "cooldown" in result["reason"]

    def test_no_context_returns_no_context(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        with patch(
            "backend.queue_continuation.get_queue_continuation_config",
            return_value={"enabled": True, "cooldown_seconds": 0,
                          "track_count": 12, "bpm_window": 10, "zones": []},
        ):
            result = asyncio.run(
                queue_continuation.trigger_continuation("zone1", "Zone One", skip_cooldown=True)
            )
        assert result["status"] == "no_context"


# ---------------------------------------------------------------------------
# is_zone_allowed
# ---------------------------------------------------------------------------


class TestIsZoneAllowed:
    def test_empty_zones_allows_all(self):
        with patch(
            "backend.queue_continuation.get_queue_continuation_config",
            return_value={"enabled": True, "zones": []},
        ):
            assert queue_continuation.is_zone_allowed("Any Zone") is True
            assert queue_continuation.is_zone_allowed(None) is True

    def test_configured_zones_filter(self):
        with patch(
            "backend.queue_continuation.get_queue_continuation_config",
            return_value={"enabled": True, "zones": ["Living Room", "Kitchen"]},
        ):
            assert queue_continuation.is_zone_allowed("Living Room") is True
            assert queue_continuation.is_zone_allowed("Bedroom") is False

    def test_partial_zone_name_match(self):
        with patch(
            "backend.queue_continuation.get_queue_continuation_config",
            return_value={"enabled": True, "zones": ["Living Room"]},
        ):
            assert queue_continuation.is_zone_allowed("living room") is True


# ---------------------------------------------------------------------------
# maybe_fire_continuation — dedup token
# ---------------------------------------------------------------------------


class TestMaybeFireContinuation:
    def setup_method(self):
        # Clear per-test to avoid cross-test contamination
        queue_continuation._FIRED_FOR_QUEUE_TOKEN.clear()

    def test_does_not_fire_when_remaining_gt_1(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        fired = []

        async def _mock_trigger(*args, **kwargs):
            fired.append(True)
            return {"status": "queued"}

        with patch("backend.queue_continuation.trigger_continuation", _mock_trigger), \
             patch("backend.queue_continuation.is_zone_allowed", return_value=True):
            asyncio.run(queue_continuation.maybe_fire_continuation("z1", "Z", 2, None))

        assert fired == []

    def test_dedup_same_token_fires_once(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        fired = []
        now_playing = {"three_line": {"line1": "Song", "line2": "Artist"}}

        async def _mock_trigger(*args, **kwargs):
            fired.append(True)
            return {"status": "queued"}

        with patch("backend.queue_continuation.trigger_continuation", _mock_trigger), \
             patch("backend.queue_continuation.is_zone_allowed", return_value=True):
            asyncio.run(
                queue_continuation.maybe_fire_continuation("z1", "Z", 0, now_playing)
            )
            asyncio.run(
                queue_continuation.maybe_fire_continuation("z1", "Z", 0, now_playing)
            )

        assert len(fired) == 1

    def test_reset_clears_token(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        fired = []
        now_playing = {"three_line": {"line1": "Song", "line2": "Artist"}}

        async def _mock_trigger(*args, **kwargs):
            fired.append(True)
            return {"status": "queued"}

        with patch("backend.queue_continuation.trigger_continuation", _mock_trigger), \
             patch("backend.queue_continuation.is_zone_allowed", return_value=True):
            asyncio.run(
                queue_continuation.maybe_fire_continuation("z1", "Z", 0, now_playing)
            )
            queue_continuation.reset_for_zone("z1")
            asyncio.run(
                queue_continuation.maybe_fire_continuation("z1", "Z", 0, now_playing)
            )

        assert len(fired) == 2


# ---------------------------------------------------------------------------
# force_expire_cooldown / get_last_fired_iso
# ---------------------------------------------------------------------------


class TestCooldownHelpers:
    def test_force_expire_makes_last_fired_old(self, tmp_path, monkeypatch):
        db_path = _setup_db(tmp_path, monkeypatch)
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        conn.execute(
            """INSERT INTO queue_continuation_log
               (zone_id, zone_name, last_fired_at, last_track_count, last_status)
               VALUES ('z1', 'Z', ?, 5, 'queued')""",
            (datetime.now(UTC).isoformat(),),
        )
        conn.commit()
        conn.close()

        queue_continuation.force_expire_cooldown("z1")
        last = queue_continuation._last_fired("z1")
        assert last is not None
        assert (datetime.now(UTC) - last).total_seconds() > 3600 * 20

    def test_get_last_fired_iso_returns_none_for_unknown(self, tmp_path, monkeypatch):
        _setup_db(tmp_path, monkeypatch)
        assert queue_continuation.get_last_fired_iso("unknown_zone") is None
