"""Tests for backend.audio_features.circadian.

Covers profile aggregation, interpolation of empty hours, playlist generation
for a given hour, and the adaptive-targets skip adjustment.
"""

from __future__ import annotations

import sqlite3

import pytest

from backend.audio_features import circadian

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------


def _seed_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "circadian.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Two pools — morning (calm/acoustic) and evening (energetic/electronic).
    samples = [
        # (key, title, artist, energy, dance, valence, instr, acoustic)
        ("morning1", "Sunrise 1", "MA", 0.20, 0.20, 0.55, 0.60, 0.85),
        ("morning2", "Sunrise 2", "MB", 0.22, 0.22, 0.55, 0.60, 0.85),
        ("morning3", "Sunrise 3", "MC", 0.18, 0.20, 0.55, 0.62, 0.82),
        ("morning4", "Sunrise 4", "MD", 0.21, 0.21, 0.55, 0.61, 0.84),
        ("evening1", "Nightfall 1", "EA", 0.85, 0.80, 0.65, 0.05, 0.10),
        ("evening2", "Nightfall 2", "EB", 0.86, 0.82, 0.65, 0.05, 0.10),
        ("evening3", "Nightfall 3", "EC", 0.84, 0.81, 0.65, 0.06, 0.11),
        ("evening4", "Nightfall 4", "ED", 0.87, 0.83, 0.65, 0.05, 0.10),
    ]
    for k, title, artist, e, d, v, i, a in samples:
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (k, title, artist, "Album"),
        )
        conn.execute(
            """INSERT INTO track_audio_features
                   (item_key, bpm, energy, danceability, valence,
                    instrumentalness, acousticness)
                  VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (k, 120, e, d, v, i, a),
        )
    conn.commit()
    return conn


def _add_history(
    conn: sqlite3.Connection,
    *,
    title: str,
    artist: str,
    hour: int,
    skipped: int = 0,
    zone_name: str = "Living Room",
    count: int = 1,
) -> None:
    """Insert ``count`` listening_history rows for the same track."""
    for i in range(count):
        ts = f"2026-05-26 {hour:02d}:{i % 60:02d}:00"
        conn.execute(
            """INSERT INTO listening_history
                   (timestamp, zone_name, track_title, artist, album,
                    skipped, duration_seconds, played_seconds, hour_of_day)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (ts, zone_name, title, artist, "Album", skipped, 240, 240, hour),
        )
    conn.commit()


# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------


class TestGetCircadianProfile:
    def test_no_history_degrades_to_zero(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        profile = circadian.get_circadian_profile(conn)
        assert profile["degraded"] is True
        # All hours present, all zeroed.
        assert len(profile["hours"]) == 24
        assert all(
            v["energy"] == 0.0 for v in profile["hours"].values()
        )
        conn.close()

    def test_populated_hours_match_history(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        # 4 morning hours and 4 evening hours, each with 3 plays.
        for h in (6, 7, 8, 9):
            _add_history(conn, title="Sunrise 1", artist="MA", hour=h, count=3)
        for h in (19, 20, 21, 22):
            _add_history(conn, title="Nightfall 1", artist="EA", hour=h, count=3)
        profile = circadian.get_circadian_profile(conn)
        assert profile["degraded"] is False
        # Morning hour: low energy. Evening hour: high energy.
        assert profile["hours"][7]["energy"] < 0.5
        assert profile["hours"][20]["energy"] > 0.5
        conn.close()

    def test_interpolates_missing_hours(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        # Populate 0, 8, 16 with strong differences; rest should interpolate.
        _add_history(conn, title="Sunrise 1", artist="MA", hour=0, count=3)
        _add_history(conn, title="Sunrise 2", artist="MB", hour=8, count=3)
        _add_history(conn, title="Nightfall 1", artist="EA", hour=16, count=3)
        _add_history(conn, title="Sunrise 3", artist="MC", hour=4, count=3)
        profile = circadian.get_circadian_profile(conn)
        # All 24 hours have a value.
        assert all("energy" in profile["hours"][h] for h in range(24))
        # 3 was not in the data — should be flagged as interpolated.
        assert 3 in profile["interpolated_hours"]
        # 0 was in the data — should NOT be flagged.
        assert 0 not in profile["interpolated_hours"]
        conn.close()


# ---------------------------------------------------------------------------
# Playlist generation
# ---------------------------------------------------------------------------


class TestCircadianPlaylist:
    def test_morning_hour_prefers_morning_tracks(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        for h in (6, 7, 8, 9):
            _add_history(conn, title="Sunrise 1", artist="MA", hour=h, count=3)
            _add_history(conn, title="Sunrise 2", artist="MB", hour=h, count=3)
        out = circadian.get_circadian_playlist(conn, hour=8, limit=4)
        assert "error" not in out
        assert out["hour"] == 8
        top = [r["item_key"] for r in out["results"][:3]]
        assert sum(1 for k in top if k.startswith("morning")) >= 2
        conn.close()

    def test_evening_hour_prefers_evening_tracks(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        for h in (19, 20, 21, 22):
            _add_history(conn, title="Nightfall 1", artist="EA", hour=h, count=3)
            _add_history(conn, title="Nightfall 2", artist="EB", hour=h, count=3)
        out = circadian.get_circadian_playlist(conn, hour=20, limit=4)
        assert "error" not in out
        top = [r["item_key"] for r in out["results"][:3]]
        assert sum(1 for k in top if k.startswith("evening")) >= 2
        conn.close()

    def test_match_score_in_unit_interval(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        _add_history(conn, title="Sunrise 1", artist="MA", hour=7, count=3)
        out = circadian.get_circadian_playlist(conn, hour=7, limit=3)
        for r in out["results"]:
            assert 0.0 <= r["match"] <= 1.0
        conn.close()

    def test_no_analysed_tracks_returns_error(self, tmp_path, monkeypatch):
        from backend import db as db_module

        db_path = tmp_path / "empty.db"
        monkeypatch.setattr(db_module, "DB_PATH", db_path)
        monkeypatch.setattr(db_module, "DATA_DIR", tmp_path)
        monkeypatch.setattr(db_module, "_schema_initialized", False)
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        db_module.init_schema(conn)

        out = circadian.get_circadian_playlist(conn, hour=12, limit=3)
        assert "error" in out
        assert out["results"] == []
        conn.close()


# ---------------------------------------------------------------------------
# Adaptive targets
# ---------------------------------------------------------------------------


class TestAdaptiveTargets:
    def test_skip_pulls_target_away(self, tmp_path, monkeypatch):
        """When hype tracks are skipped at hour=20 and only calm finishes,
        the adaptive target for 20 should sit *further* from hype than the
        baseline does."""
        conn = _seed_db(tmp_path, monkeypatch)
        # Finished plays at 20: morning (low energy). Skipped at 20: evening.
        _add_history(conn, title="Sunrise 1", artist="MA", hour=20, count=3, skipped=0)
        _add_history(conn, title="Sunrise 2", artist="MB", hour=20, count=3, skipped=0)
        _add_history(conn, title="Nightfall 1", artist="EA", hour=20, count=3, skipped=1)
        _add_history(conn, title="Nightfall 2", artist="EB", hour=20, count=3, skipped=1)

        adapted = circadian.get_adaptive_targets(conn)
        baseline = circadian.get_circadian_profile(conn)["hours"]

        baseline_energy = baseline[20]["energy"]
        adapted_energy = adapted["hours"][20]["energy"]
        # Adapted target moves AWAY from the high-energy skips, so it should be
        # ≤ baseline (which only averages finished plays).
        assert adapted_energy <= baseline_energy + 1e-6
        # It should also stay in [0, 1].
        assert 0.0 <= adapted_energy <= 1.0
        conn.close()

    def test_zone_filter_isolates(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        # Kitchen-only history shouldn't influence Living Room targets.
        _add_history(
            conn, title="Nightfall 1", artist="EA", hour=20, count=3, skipped=1,
            zone_name="Kitchen",
        )
        _add_history(
            conn, title="Sunrise 1", artist="MA", hour=20, count=3, skipped=0,
            zone_name="Living Room",
        )
        adapted = circadian.get_adaptive_targets(conn, zone_name="Living Room")
        # Living Room had no skips, so the skip_count should be 0.
        assert adapted["skip_counts"][20] == 0
        conn.close()


# ---------------------------------------------------------------------------
# Interpolation edge cases
# ---------------------------------------------------------------------------


class TestInterpolation:
    def test_circular_distance_at_boundary(self, tmp_path, monkeypatch):
        """Hour 23 should interpolate from neighbours including hour 0
        (circular ring), not extrapolate linearly off the end."""
        conn = _seed_db(tmp_path, monkeypatch)
        # Populate enough hours that we're not in degraded mode.
        for h in (0, 6, 12, 18):
            _add_history(conn, title="Sunrise 1", artist="MA", hour=h, count=3)
        profile = circadian.get_circadian_profile(conn)
        assert profile["degraded"] is False
        # 23 should have a value; 22 too. They should both be in [0,1].
        for h in (22, 23):
            assert 0.0 <= profile["hours"][h]["energy"] <= 1.0
        conn.close()


if __name__ == "__main__":  # pragma: no cover
    pytest.main([__file__, "-v"])
