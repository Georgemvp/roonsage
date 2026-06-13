"""Tests for backend.audio_features.cluster_tagger."""

from __future__ import annotations

import json
import sqlite3

import pytest

import backend.db.connection as _db_connection
from backend.audio_features import cluster_tagger


@pytest.fixture
def seeded_db(tmp_path, monkeypatch):
    """In-memory-ish DB with two clusters + Last.fm tags + Roon genres."""
    from backend import db as db_module

    db_path = tmp_path / "tagger.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Cluster 0: three tracks, all tagged "jazz" / "cool" / "smoky" via Last.fm
    for i in range(3):
        k = f"c0-{i}"
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (k, f"T{i}", "Miles Davis", "Kind of Blue"),
        )
        conn.execute(
            "INSERT INTO track_audio_features "
            "(item_key, bpm, energy, danceability, valence, instrumentalness, "
            " acousticness, cluster_id, x_2d, y_2d) "
            "VALUES (?, 80, 0.3, 0.3, 0.4, 0.9, 0.9, 0, 0.1, 0.1)",
            (k,),
        )
        conn.execute(
            "INSERT INTO track_metadata_ext (item_key, lastfm_tags) VALUES (?, ?)",
            (k, json.dumps(["jazz", "cool", "smoky"])),
        )

    # Cluster 1: three tracks, no Last.fm tags but a clear Roon genre fallback.
    for i in range(3):
        k = f"c1-{i}"
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (k, f"T{i}", "Burial", "Untrue"),
        )
        conn.execute(
            "INSERT INTO track_audio_features "
            "(item_key, bpm, energy, danceability, valence, instrumentalness, "
            " acousticness, cluster_id, x_2d, y_2d) "
            "VALUES (?, 130, 0.6, 0.6, 0.3, 0.4, 0.1, 1, 5.0, 5.0)",
            (k,),
        )
        conn.execute(
            "INSERT INTO track_genres (track_key, genre) VALUES (?, ?)",
            (k, "Electronic"),
        )

    # Noise cluster — must be ignored.
    conn.execute(
        "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
        ("noise-0", "Outlier", "Unknown", "?"),
    )
    conn.execute(
        "INSERT INTO track_audio_features "
        "(item_key, bpm, energy, danceability, valence, instrumentalness, "
        " acousticness, cluster_id, x_2d, y_2d) "
        "VALUES (?, 200, 0.9, 0.9, 0.5, 0.5, 0.5, -1, 99, 99)",
        ("noise-0",),
    )

    conn.commit()
    yield str(db_path)
    conn.close()


@pytest.mark.asyncio
async def test_auto_tag_uses_lastfm_when_available(seeded_db):
    result = await cluster_tagger.auto_tag_clusters(db_path=seeded_db)
    assert result["n_clusters"] == 2

    c0 = result["clusters"][0]
    assert c0["source"] == "lastfm"
    assert c0["labels"][0] == "jazz"
    assert set(c0["labels"]) == {"jazz", "cool", "smoky"}


@pytest.mark.asyncio
async def test_auto_tag_falls_back_to_roon_genres(seeded_db):
    result = await cluster_tagger.auto_tag_clusters(db_path=seeded_db)
    c1 = result["clusters"][1]
    assert c1["source"] == "roon_genres"
    assert c1["labels"] == ["electronic"]


@pytest.mark.asyncio
async def test_auto_tag_ignores_noise_cluster(seeded_db):
    result = await cluster_tagger.auto_tag_clusters(db_path=seeded_db)
    assert -1 not in result["clusters"]


@pytest.mark.asyncio
async def test_get_cluster_label_round_trip(seeded_db):
    await cluster_tagger.auto_tag_clusters(db_path=seeded_db)
    label = await cluster_tagger.get_cluster_label(0, db_path=seeded_db)
    assert label["cluster_id"] == 0
    assert label["label_primary"] == "jazz"
    assert label["labels"] == ["jazz", "cool", "smoky"]


@pytest.mark.asyncio
async def test_auto_tag_is_idempotent(seeded_db):
    """Two runs must leave exactly one row per cluster."""
    await cluster_tagger.auto_tag_clusters(db_path=seeded_db)
    await cluster_tagger.auto_tag_clusters(db_path=seeded_db)
    conn = sqlite3.connect(seeded_db)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute("SELECT cluster_id FROM cluster_labels").fetchall()
        ids = sorted(r["cluster_id"] for r in rows)
        assert ids == [0, 1]
    finally:
        conn.close()


def test_parse_tag_field_handles_json_and_csv():
    assert cluster_tagger._parse_tag_field('["a","b"]') == ["a", "b"]
    assert cluster_tagger._parse_tag_field("a, b , c") == ["a", "b", "c"]
    assert cluster_tagger._parse_tag_field(None) == []
    assert cluster_tagger._parse_tag_field("") == []
