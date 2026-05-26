import pytest

pytest.importorskip("numpy")
pytest.importorskip("sklearn")

import sqlite3

from backend.audio_features.sonic_fingerprint import (
    get_fingerprint_recommendations,
    get_sonic_fingerprint,
)
from backend.db import init_schema


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    init_schema(c)

    for i in range(20):
        c.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?,?,?,?)",
            (f"k{i}", f"Track {i}", f"Artist {i % 5}", f"Album {i % 3}"),
        )
        c.execute(
            """INSERT INTO track_audio_features
               (item_key, bpm, energy, danceability, valence, instrumentalness, acousticness)
               VALUES (?,?,?,?,?,?,?)""",
            (f"k{i}", 80 + i * 5, i / 20, i / 20, i / 20, i / 20, i / 20),
        )

    for i in range(10):
        for _ in range(i + 1):
            c.execute(
                "INSERT INTO listening_history (track_title, artist)"
                " VALUES (?,?)",
                (f"Track {i}", f"Artist {i % 5}"),
            )
    c.commit()
    return c


def test_fingerprint_returns_profile(conn):
    result = get_sonic_fingerprint(conn)
    assert "fingerprint" in result
    assert len(result["fingerprint"]) == 6
    assert result["n_source_tracks"] > 0


def test_fingerprint_values_in_unit_range(conn):
    result = get_sonic_fingerprint(conn)
    for v in result["fingerprint"]:
        assert 0.0 <= v <= 1.0


def test_recommendations_returns_results(conn):
    result = get_fingerprint_recommendations(conn, limit=5)
    assert "results" in result
    assert len(result["results"]) > 0
    assert result["n_pool"] > 0


def test_recommendations_have_required_fields(conn):
    result = get_fingerprint_recommendations(conn, limit=5)
    for r in result["results"]:
        assert "item_key" in r
        assert "similarity" in r
        assert 0.0 <= r["similarity"] <= 1.0


def test_insufficient_history_returns_error():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    init_schema(c)
    result = get_sonic_fingerprint(c)
    assert "error" in result
