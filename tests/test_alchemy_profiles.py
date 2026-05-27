"""Tests for backend.audio_features.alchemy_profiles.

Covers save / list / get / delete CRUD, generate_from_profile, and the
Surprise Me heuristic (with and without skips, and with no audio-feature
matches).
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta

import pytest

from backend.audio_features import alchemy_profiles

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _seed_db(tmp_path, monkeypatch):
    """Initialise the project schema against a temp DB and seed two clusters
    of tracks: "calm" (low energy) and "hype" (high energy)."""
    from backend import db as db_module

    db_path = tmp_path / "alchemy_profiles.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    samples = [
        # (key, title, artist, bpm, energy, dance, valence, instr, acoustic)
        ("calm1", "Sleepy 1", "A", 80, 0.10, 0.10, 0.30, 0.80, 0.80),
        ("calm2", "Sleepy 2", "B", 82, 0.12, 0.10, 0.30, 0.80, 0.80),
        ("calm3", "Sleepy 3", "C", 78, 0.11, 0.12, 0.30, 0.80, 0.80),
        ("calm4", "Sleepy 4", "D", 84, 0.13, 0.11, 0.30, 0.80, 0.80),
        ("hype1", "Banger 1", "E", 140, 0.90, 0.90, 0.70, 0.05, 0.05),
        ("hype2", "Banger 2", "F", 142, 0.92, 0.91, 0.70, 0.05, 0.05),
        ("hype3", "Banger 3", "G", 138, 0.91, 0.92, 0.70, 0.05, 0.05),
        ("hype4", "Banger 4", "H", 144, 0.93, 0.90, 0.70, 0.05, 0.05),
    ]
    for k, title, artist, bpm, e, d, v, i, a in samples:
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (k, title, artist, "Album"),
        )
        conn.execute(
            """INSERT INTO track_audio_features
               (item_key, bpm, energy, danceability, valence, instrumentalness, acousticness)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (k, bpm, e, d, v, i, a),
        )
    conn.commit()
    return conn


def _seed_history(conn: sqlite3.Connection, rows: list[dict]) -> None:
    """Insert listening_history rows (title, artist, skipped, hours_ago)."""
    for r in rows:
        ts = (datetime.now(UTC) - timedelta(hours=r.get("hours_ago", 1))).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
        conn.execute(
            """INSERT INTO listening_history
               (timestamp, zone_name, track_title, artist, album, skipped,
                duration_seconds, played_seconds)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                ts,
                r.get("zone_name", "Living Room"),
                r["track_title"],
                r["artist"],
                r.get("album", "Album"),
                int(r.get("skipped", 0)),
                int(r.get("duration_seconds", 240)),
                int(r.get("played_seconds", 240)),
            ),
        )
    conn.commit()


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------


class TestSaveAndList:
    def test_save_requires_name(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        with pytest.raises(ValueError, match="name"):
            alchemy_profiles.save_profile(
                conn, name="", zone_id=None, add_track_ids=["calm1"]
            )
        conn.close()

    def test_save_requires_add_tracks(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        with pytest.raises(ValueError, match="ADD"):
            alchemy_profiles.save_profile(
                conn, name="x", zone_id=None, add_track_ids=[]
            )
        conn.close()

    def test_save_rejects_unanalyzed_tracks(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        with pytest.raises(KeyError):
            alchemy_profiles.save_profile(
                conn, name="x", zone_id=None, add_track_ids=["ghost"]
            )
        conn.close()

    def test_save_and_list(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        out = alchemy_profiles.save_profile(
            conn,
            name="Sunday Morning",
            zone_id="zone_living",
            add_track_ids=["calm1", "calm2"],
            subtract_track_ids=["hype1"],
        )
        assert out["name"] == "Sunday Morning"
        assert out["zone_id"] == "zone_living"
        # Stored features live in min-max-normalised [0, 1] space (the same
        # space the alchemy ranking operates in). What matters is the relative
        # ordering: ADD (calm) sits *low* in the energy column, SUBTRACT (hype)
        # sits at the top.
        assert 0.0 <= out["add_features"]["energy"] < 0.5
        assert out["subtract_features"]["energy"] > 0.5
        assert out["add_features"]["energy"] < out["subtract_features"]["energy"]
        # Source track IDs are persisted on the profile so they can be excluded
        # from the generated results later.
        assert sorted(out["add_track_ids"]) == ["calm1", "calm2"]
        assert out["subtract_track_ids"] == ["hype1"]

        profiles = alchemy_profiles.list_profiles(conn)
        assert len(profiles) == 1
        assert profiles[0]["name"] == "Sunday Morning"
        conn.close()

    def test_save_with_same_name_replaces(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        first = alchemy_profiles.save_profile(
            conn, name="Same", zone_id=None, add_track_ids=["calm1"]
        )
        second = alchemy_profiles.save_profile(
            conn, name="Same", zone_id=None, add_track_ids=["hype1"]
        )
        assert first["id"] == second["id"]
        # New ADD vector should reflect hype1's values.
        assert second["add_features"]["energy"] > 0.5

        profiles = alchemy_profiles.list_profiles(conn)
        assert len(profiles) == 1
        conn.close()


class TestDelete:
    def test_delete_existing(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        p = alchemy_profiles.save_profile(
            conn, name="x", zone_id=None, add_track_ids=["calm1"]
        )
        assert alchemy_profiles.delete_profile(conn, p["id"]) is True
        assert alchemy_profiles.get_profile(conn, p["id"]) is None
        conn.close()

    def test_delete_missing(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        assert alchemy_profiles.delete_profile(conn, 999_999) is False
        conn.close()


# ---------------------------------------------------------------------------
# generate_from_profile
# ---------------------------------------------------------------------------


class TestGenerate:
    def test_generates_calm_when_calm_saved(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        p = alchemy_profiles.save_profile(
            conn,
            name="calm bias",
            zone_id=None,
            add_track_ids=["calm1", "calm2"],
            subtract_track_ids=["hype1"],
        )
        out = alchemy_profiles.generate_from_profile(conn, p["id"], limit=4)
        top_keys = [r["item_key"] for r in out["results"][:3]]
        # Remaining calm tracks should dominate the top.
        assert sum(1 for k in top_keys if k.startswith("calm")) >= 2
        # Source tracks excluded.
        for k in ("calm1", "calm2", "hype1"):
            assert k not in [r["item_key"] for r in out["results"]]
        conn.close()

    def test_missing_profile_raises(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        with pytest.raises(KeyError):
            alchemy_profiles.generate_from_profile(conn, 12345, limit=5)
        conn.close()


# ---------------------------------------------------------------------------
# surprise_me
# ---------------------------------------------------------------------------


class TestSurpriseMe:
    def test_no_history_returns_error(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        out = alchemy_profiles.surprise_me(conn, "Living Room", limit=5)
        assert "error" in out
        conn.close()

    def test_only_skips_returns_error(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        _seed_history(conn, [
            {"track_title": "Sleepy 1", "artist": "A", "skipped": 1},
            {"track_title": "Sleepy 2", "artist": "B", "skipped": 1},
        ])
        out = alchemy_profiles.surprise_me(conn, "Living Room", limit=5)
        assert "error" in out
        conn.close()

    def test_plays_and_skips(self, tmp_path, monkeypatch):
        conn = _seed_db(tmp_path, monkeypatch)
        # Recent plays: 2 calm. Recent skips: 2 hype. The implicit ADD covers
        # 2 of the 4 calm tracks; the remaining 2 calm tracks should rank
        # higher than the remaining 2 hype tracks.
        _seed_history(conn, [
            {"track_title": "Sleepy 1", "artist": "A", "skipped": 0, "hours_ago": 1},
            {"track_title": "Sleepy 2", "artist": "B", "skipped": 0, "hours_ago": 2},
            {"track_title": "Banger 1", "artist": "E", "skipped": 1, "hours_ago": 4},
            {"track_title": "Banger 2", "artist": "F", "skipped": 1, "hours_ago": 5},
        ])
        out = alchemy_profiles.surprise_me(conn, "Living Room", limit=4)
        assert "error" not in out, out
        assert out["n_plays"] == 2
        assert out["n_skips"] == 2
        assert out["subtract_source"] == "recent_skips"
        # Two calm tracks remain in the pool after excluding ADD source;
        # they should both place above the two remaining hype tracks.
        top_keys = [r["item_key"] for r in out["results"][:2]]
        assert all(k.startswith("calm") for k in top_keys), top_keys
        conn.close()

    def test_plays_only_falls_back_to_low_energy(self, tmp_path, monkeypatch):
        """With no skips, lowest-energy plays become SUBTRACT, biasing toward
        the higher-energy plays in the ADD set."""
        conn = _seed_db(tmp_path, monkeypatch)
        _seed_history(conn, [
            {"track_title": "Banger 1", "artist": "E", "skipped": 0, "hours_ago": 1},
            {"track_title": "Banger 2", "artist": "F", "skipped": 0, "hours_ago": 2},
            {"track_title": "Sleepy 1", "artist": "A", "skipped": 0, "hours_ago": 3},
            {"track_title": "Sleepy 2", "artist": "B", "skipped": 0, "hours_ago": 4},
        ])
        out = alchemy_profiles.surprise_me(conn, "Living Room", limit=4)
        assert "error" not in out, out
        assert out["n_skips"] == 0
        assert out["subtract_source"] == "low_energy_plays_fallback"
        # With low-energy as SUBTRACT, the target should pull toward the remaining
        # hype tracks (which weren't in the ADD set).
        top_keys = [r["item_key"] for r in out["results"][:3]]
        assert any(k.startswith("hype") for k in top_keys)
        conn.close()

    def test_zone_filter_isolates(self, tmp_path, monkeypatch):
        """Listening_history rows from another zone should be ignored."""
        conn = _seed_db(tmp_path, monkeypatch)
        _seed_history(conn, [
            {"track_title": "Sleepy 1", "artist": "A", "skipped": 0,
             "zone_name": "Kitchen", "hours_ago": 1},
            {"track_title": "Sleepy 2", "artist": "B", "skipped": 0,
             "zone_name": "Kitchen", "hours_ago": 2},
            {"track_title": "Sleepy 3", "artist": "C", "skipped": 0,
             "zone_name": "Kitchen", "hours_ago": 3},
        ])
        # Asking for "Living Room" must yield no matches.
        out = alchemy_profiles.surprise_me(conn, "Living Room", limit=4)
        assert "error" in out
        conn.close()
