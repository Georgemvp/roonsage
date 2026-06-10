"""Tests for the DJ-set builder.

Uses an in-memory SQLite database wired through backend.db so the generator's
real `get_connection` returns our fixture data.
"""

import pytest

from backend.audio_features import dj_generator


@pytest.fixture
def synthetic_db(tmp_path, monkeypatch):
    """Patch backend.db.DB_PATH to a temp file and seed it with synthetic data."""
    import sqlite3

    import backend.db.connection as _db_connection
    from backend import db as db_module

    db_path = tmp_path / "test.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    # Reset cached schema flag so init_schema runs on the temp DB.
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Seed 30 synthetic tracks: BPM from 100 to 130, varied keys & energy.
    artists = [f"Artist{i:02d}" for i in range(30)]
    rows_tracks = []
    rows_features = []
    for i, artist in enumerate(artists):
        item_key = str(i + 1)
        bpm = 100 + i  # 100..129
        # cycle through 8A, 9A, 8B, 9B, 10A so most are mutually compatible.
        camelot_choices = ["8A", "9A", "8B", "9B", "10A"]
        camelot = camelot_choices[i % len(camelot_choices)]
        energy = 0.3 + (i / 30.0) * 0.6  # gentle ramp 0.3 → 0.9
        rows_tracks.append((item_key, f"Title {i}", artist, f"Album {i}", 200000, 2020, "[]", 0))
        rows_features.append((item_key, f"/music/{item_key}.flac", bpm, camelot, energy))

    conn.executemany(
        "INSERT INTO tracks (item_key, title, artist, album, duration_ms, year, genres, is_live)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        rows_tracks,
    )
    conn.executemany(
        "INSERT INTO track_audio_features (item_key, file_path, bpm, camelot, energy)"
        " VALUES (?, ?, ?, ?, ?)",
        rows_features,
    )
    conn.commit()
    conn.close()

    yield db_path


def test_curve_values_shapes():
    assert dj_generator._curve_values("flat", 5) == [pytest.approx(0.55, abs=1e-6)] * 5
    ramp = dj_generator._curve_values("ramp_up", 5)
    assert ramp[0] < ramp[-1]
    ramp_down = dj_generator._curve_values("ramp_down", 5)
    assert ramp_down[0] > ramp_down[-1]
    peak = dj_generator._curve_values("peak", 5)
    assert peak[2] >= peak[0] and peak[2] >= peak[-1]


def test_bpm_targets_linear_interpolation():
    targets = dj_generator._bpm_targets(100, 130, 4)
    assert targets[0] == 100
    assert targets[-1] == 130
    # Strictly increasing.
    for a, b in zip(targets, targets[1:], strict=False):
        assert a < b


def test_build_dj_set_respects_bpm_curve(synthetic_db):
    result = dj_generator.build_dj_set(
        track_count=10,
        start_bpm=105,
        end_bpm=125,
        energy_curve="ramp_up",
        exclude_live=True,
        rng_seed=42,
    )
    assert len(result["tracks"]) > 0
    assert result["returned"] == len(result["tracks"])
    bpms = [t["bpm"] for t in result["tracks"]]
    # The set should generally trend upward (allowing some noise from random
    # tie-breaking). Sanity: median of last 3 > median of first 3.
    head_med = sorted(bpms[:3])[1]
    tail_med = sorted(bpms[-3:])[1]
    assert tail_med >= head_med - 4  # tolerance for greedy + jitter
    # All BPMs should be within the broad ±8 window around 105..125.
    assert min(bpms) >= 105 - 8
    assert max(bpms) <= 125 + 8


def test_build_dj_set_no_duplicates(synthetic_db):
    result = dj_generator.build_dj_set(track_count=15, rng_seed=1)
    seen = [t["item_key"] for t in result["tracks"]]
    assert len(seen) == len(set(seen))


def test_build_dj_set_returns_empty_when_pool_empty(synthetic_db):
    # Use a BPM range outside our 100..129 pool, including allow_half_step ranges.
    # allow_half_step=True also matches ~half and ~double of [start,end].
    # 500-600 → half = 250-306, double = 1000-1206, none overlap 100-129.
    result = dj_generator.build_dj_set(
        track_count=10,
        start_bpm=500,
        end_bpm=600,
    )
    assert result["tracks"] == []
    assert result["total_matching"] == 0


def test_build_dj_set_artist_diversity(synthetic_db):
    # Insert another row sharing artist Artist00 to test the diversity penalty.
    from backend.db import get_connection
    with get_connection() as c:
        c.execute(
            "INSERT INTO tracks (item_key, title, artist, album, duration_ms,"
            " year, genres, is_live) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("99", "Title 99", "Artist00", "Album 99", 200000, 2020, "[]", 0),
        )
        c.execute(
            "INSERT INTO track_audio_features (item_key, file_path, bpm, camelot, energy)"
            " VALUES (?, ?, ?, ?, ?)",
            ("99", "/music/99.flac", 102, "8A", 0.5),
        )

    result = dj_generator.build_dj_set(track_count=15, rng_seed=42)
    artists = [t["artist"] for t in result["tracks"]]
    # No artist should appear in two consecutive slots (recent_artists penalty).
    for a, b in zip(artists, artists[1:], strict=False):
        assert a != b
