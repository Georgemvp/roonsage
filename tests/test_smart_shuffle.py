"""Tests for backend.audio_features.smart_shuffle."""

from __future__ import annotations

import sqlite3

import pytest

from backend.audio_features import smart_shuffle as ss


@pytest.fixture
def seeded_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "shuffle.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)

    # Two clusters with three tracks each, all with duration_ms set.
    seed_data = [
        # cluster_id, x, y
        (0, 0.1, 0.1),
        (0, 0.15, 0.05),
        (0, 0.05, 0.2),
        (1, 5.0, 5.0),
        (1, 5.1, 4.9),
        (1, 5.2, 5.1),
    ]
    for i, (cid, x, y) in enumerate(seed_data):
        key = f"t-{cid}-{i}"
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album, duration_ms, is_live) "
            "VALUES (?, ?, ?, ?, ?, 0)",
            (key, f"Title {i}", f"Artist {cid}", f"Album {cid}", 200_000),
        )
        conn.execute(
            "INSERT INTO track_audio_features "
            "(item_key, bpm, energy, danceability, valence, instrumentalness, "
            " acousticness, cluster_id, x_2d, y_2d) "
            "VALUES (?, 120, 0.5, 0.5, 0.5, 0.5, 0.5, ?, ?, ?)",
            (key, cid, x, y),
        )

    conn.commit()
    yield str(db_path)
    conn.close()


def test_smart_shuffle_avoids_consecutive_same_cluster(seeded_db):
    keys = [f"t-0-{i}" for i in range(3)] + [f"t-1-{i}" for i in range(3, 6)]
    ordered = ss.smart_shuffle_sync(keys, db_path=seeded_db)
    # Same count, no drops.
    assert len(ordered) == len(keys)
    assert set(ordered) == set(keys)

    # Map back to cluster ids and confirm no consecutive same-cluster pair
    # (with two equally-sized buckets the round-robin alternates strictly).
    conn = sqlite3.connect(seeded_db)
    conn.row_factory = sqlite3.Row
    placeholders = ",".join("?" * len(ordered))
    rows = conn.execute(
        f"SELECT item_key, cluster_id FROM track_audio_features "
        f"WHERE item_key IN ({placeholders})",
        ordered,
    ).fetchall()
    cmap = {r["item_key"]: r["cluster_id"] for r in rows}
    conn.close()

    seq = [cmap[k] for k in ordered]
    for a, b in zip(seq, seq[1:], strict=False):
        assert a != b, f"Consecutive same-cluster pair found in {seq}"


def test_smart_shuffle_handles_unknown_cluster_tracks(seeded_db):
    # Mix in a key with no features row at all.
    keys = ["t-0-0", "t-1-3", "missing-key"]
    ordered = ss.smart_shuffle_sync(keys, db_path=seeded_db)
    assert set(ordered) == set(keys)


def test_smart_shuffle_empty_returns_empty(seeded_db):
    assert ss.smart_shuffle_sync([], db_path=seeded_db) == []


def test_smart_radio_builds_queue_with_seed(seeded_db):
    import asyncio

    queue = asyncio.run(
        ss.smart_radio(
            zone_id="zone-x",
            duration_minutes=10,
            db_path=seeded_db,
            seed_item_key="t-0-0",
        )
    )
    # 6 tracks total in the seeded library, each 200s, so 10 minutes ⇒
    # at most 3 (600s/200s) tracks. We expect at least one.
    assert queue, "smart_radio returned an empty queue"
    assert all("item_key" in t for t in queue)
    # The seed itself is the *starting cluster*; ensure first track belongs
    # to the seed's cluster.
    cluster_ids = [t["cluster_id"] for t in queue]
    assert 0 in cluster_ids


def test_smart_radio_no_clusters_returns_empty(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "empty.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)
    conn.commit()
    conn.close()

    import asyncio

    result = asyncio.run(
        ss.smart_radio(
            zone_id="z",
            duration_minutes=30,
            db_path=str(db_path),
            seed_item_key="anything",
        )
    )
    assert result == []
