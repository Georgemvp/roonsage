"""Tests for the audio-feature filter parameters added to get_tracks_by_filters.

Verifies that audio-feature filters trigger the INNER JOIN on
track_audio_features and that tracks without analysis are silently excluded.
"""

import sqlite3

import pytest

from backend import db as db_module
from backend.tracks import get_tracks_by_filters


@pytest.fixture
def seeded_db(tmp_path, monkeypatch):
    """Seed a temp DB with five tracks, three of them analysed."""
    db_path = tmp_path / "filter_test.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    conn.executemany(
        "INSERT INTO tracks (item_key, title, artist, album, duration_ms, year,"
        " genres, is_live) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
            ("1", "Slow Burner",  "A", "A1", 200000, 2020, "[]", 0),
            ("2", "Mid Tempo",    "B", "B1", 200000, 2021, "[]", 0),
            ("3", "Banger",       "C", "C1", 200000, 2022, "[]", 0),
            ("4", "Live thing",   "D", "D1", 200000, 2023, "[]", 1),
            ("5", "Not Analysed", "E", "E1", 200000, 2024, "[]", 0),
        ],
    )
    conn.executemany(
        "INSERT INTO track_audio_features (item_key, file_path, bpm, camelot, energy,"
        " danceability, valence, instrumentalness) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
            ("1", "/m/1.flac", 90,  "5A", 0.30, 0.30, 0.40, 0.20),
            ("2", "/m/2.flac", 120, "8A", 0.55, 0.60, 0.55, 0.40),
            ("3", "/m/3.flac", 145, "9B", 0.85, 0.80, 0.70, 0.10),
            ("4", "/m/4.flac", 110, "7A", 0.50, 0.50, 0.50, 0.10),
        ],
    )
    conn.commit()
    conn.close()
    yield db_path


def test_bpm_min_filter(seeded_db):
    tracks = get_tracks_by_filters(bpm_min=120)
    keys = {t["item_key"] for t in tracks}
    # 4 has bpm=110 → excluded by bpm_min. Track 5 has no analysis → excluded.
    assert keys == {"2", "3"}


def test_bpm_range(seeded_db):
    tracks = get_tracks_by_filters(bpm_min=100, bpm_max=130)
    keys = {t["item_key"] for t in tracks}
    # exclude_live default True excludes track 4.
    assert keys == {"2"}


def test_camelot_keys(seeded_db):
    tracks = get_tracks_by_filters(camelot_keys=["8A", "9B"])
    assert {t["item_key"] for t in tracks} == {"2", "3"}


def test_energy_range(seeded_db):
    tracks = get_tracks_by_filters(energy_min=0.7)
    assert {t["item_key"] for t in tracks} == {"3"}


def test_combined_filters(seeded_db):
    tracks = get_tracks_by_filters(bpm_min=100, energy_min=0.5, exclude_live=False)
    # 2 (120, 0.55), 3 (145, 0.85), 4 (110, 0.50) all match. 1 fails bpm/energy.
    assert {t["item_key"] for t in tracks} == {"2", "3", "4"}


def test_no_audio_filters_returns_unanalysed_too(seeded_db):
    """Without any audio filter the legacy fast path is used (no JOIN)."""
    tracks = get_tracks_by_filters()
    assert {t["item_key"] for t in tracks} == {"1", "2", "3", "5"}  # excludes live (4)


def test_instrumentalness_filter(seeded_db):
    tracks = get_tracks_by_filters(instrumentalness_min=0.3)
    assert {t["item_key"] for t in tracks} == {"2"}
