"""Tests for backend.audio_features.clustering.

The UMAP+HDBSCAN pipeline is exercised end-to-end against an in-memory SQLite
DB seeded with synthetic, deliberately-clustered audio feature data. We
verify cluster_id / x_2d / y_2d are persisted, status transitions to
``complete``, and the summary aggregator returns one row per cluster.
"""

from __future__ import annotations

import random
import sqlite3

import pytest

# Skip the whole file if the heavy ML deps aren't installed in this environment.
pytest.importorskip("sklearn")
pytest.importorskip("umap")
pytest.importorskip("hdbscan")

import backend.db.connection as _db_connection  # noqa: E402
from backend.audio_features import clustering  # noqa: E402


@pytest.fixture
def seeded_db(tmp_path, monkeypatch):
    """Synthetic library with three obvious sonic clusters."""
    from backend import db as db_module

    db_path = tmp_path / "cluster.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    rng = random.Random(42)

    # Three feature centroids that are far apart in 6D — UMAP+HDBSCAN should
    # cleanly separate them. 40 tracks per cluster.
    centroids = [
        (80.0, 0.2, 0.2, 0.2, 0.9, 0.9),    # chill / instrumental
        (120.0, 0.7, 0.7, 0.7, 0.1, 0.2),   # upbeat / danceable
        (160.0, 0.9, 0.5, 0.9, 0.05, 0.05), # high-energy electronic
    ]
    for ci, (bpm, energy, dance, valence, instr, acoustic) in enumerate(centroids):
        for j in range(40):
            ikey = f"c{ci}-t{j:03d}"
            conn.execute(
                "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
                (ikey, f"Track {j}", f"Artist {ci}", f"Album {ci}"),
            )
            conn.execute(
                "INSERT INTO track_genres (track_key, genre) VALUES (?, ?)",
                (ikey, f"Genre{ci}"),
            )
            conn.execute(
                """INSERT INTO track_audio_features
                   (item_key, bpm, energy, danceability, valence,
                    instrumentalness, acousticness)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    ikey,
                    bpm + rng.gauss(0, 2),
                    max(0.0, min(1.0, energy + rng.gauss(0, 0.03))),
                    max(0.0, min(1.0, dance + rng.gauss(0, 0.03))),
                    max(0.0, min(1.0, valence + rng.gauss(0, 0.03))),
                    max(0.0, min(1.0, instr + rng.gauss(0, 0.03))),
                    max(0.0, min(1.0, acoustic + rng.gauss(0, 0.03))),
                ),
            )
    conn.commit()
    yield conn
    conn.close()


def test_run_clustering_persists_coords_and_labels(seeded_db):
    result = clustering.run_clustering(conn=seeded_db)

    assert result["status"] == "complete"
    assert result["n_tracks"] == 120
    # Three well-separated clusters in synthetic data.
    assert result["n_clusters"] >= 2

    row = seeded_db.execute(
        "SELECT COUNT(*) AS n FROM track_audio_features "
        "WHERE x_2d IS NOT NULL AND y_2d IS NOT NULL AND cluster_id IS NOT NULL"
    ).fetchone()
    assert row["n"] == 120


def test_status_reflects_completed_run(seeded_db):
    clustering.run_clustering(conn=seeded_db)
    status = clustering.get_status(seeded_db)
    assert status["status"] == "complete"
    assert status["n_tracks"] == 120
    assert status["finished_at"] is not None


def test_get_cluster_summary_one_row_per_cluster(seeded_db):
    clustering.run_clustering(conn=seeded_db)
    summaries = clustering.get_cluster_summary(seeded_db)
    # At least one cluster summary returned; counts add up to 120.
    assert len(summaries) >= 2
    assert sum(s["track_count"] for s in summaries) == 120
    # Each non-noise cluster has a dominant_genre (we seeded each cluster with
    # exactly one genre, so the dominant lookup must hit).
    for s in summaries:
        if not s["is_noise"]:
            assert s["dominant_genre"] is not None


def test_run_clustering_fails_with_too_few_tracks(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "tiny.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Only 5 tracks → below MIN_TRACKS_FOR_CLUSTERING.
    for i in range(5):
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (str(i), "t", "a", "alb"),
        )
        conn.execute(
            "INSERT INTO track_audio_features "
            "(item_key, bpm, energy, danceability, valence, instrumentalness, acousticness)"
            " VALUES (?, ?, ?, ?, ?, ?, ?)",
            (str(i), 120.0, 0.5, 0.5, 0.5, 0.5, 0.5),
        )
    conn.commit()

    result = clustering.run_clustering(conn=conn)
    assert result["status"] == "failed"
    assert result["n_tracks"] == 5
    conn.close()
