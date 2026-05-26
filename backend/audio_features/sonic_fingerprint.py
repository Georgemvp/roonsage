"""Sonic Fingerprint (v13.1): user's musical DNA from listening history.

Computes the average audio-feature profile of the user's most-played tracks
and ranks the rest of the library by cosine similarity to that profile.
Tracks the user has played little or not at all are boosted in ranking.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from backend.audio_features.clustering import FEATURE_COLUMNS

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

MIN_HISTORY_TRACKS = 3


def get_sonic_fingerprint(
    conn: sqlite3.Connection, top_n: int = 100
) -> dict[str, Any]:
    """Return the average normalised feature vector of the user's top-played tracks."""
    import numpy as np  # noqa: PLC0415
    from sklearn.preprocessing import MinMaxScaler  # noqa: PLC0415

    cols = ", ".join(f"taf.{c}" for c in FEATURE_COLUMNS)
    where = " AND ".join(f"taf.{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    # listening_history has no item_key — join via normalised title+artist
    rows = conn.execute(
        f"""
        SELECT taf.item_key, {cols}, COUNT(lh.id) AS play_count
        FROM track_audio_features taf
        JOIN tracks t ON taf.item_key = t.item_key
        JOIN listening_history lh
             ON LOWER(lh.track_title) = LOWER(t.title)
             AND LOWER(lh.artist) = LOWER(t.artist)
        WHERE {where}
        GROUP BY taf.item_key
        ORDER BY play_count DESC
        LIMIT ?
        """,
        (top_n,),
    ).fetchall()

    if len(rows) < MIN_HISTORY_TRACKS:
        return {
            "error": (
                f"Not enough listening history with audio features — "
                f"need {MIN_HISTORY_TRACKS}, have {len(rows)}."
            ),
            "n_tracks": len(rows),
        }

    matrix = np.array(
        [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows], dtype=float
    )
    scaler = MinMaxScaler()
    norm = scaler.fit_transform(matrix)
    fingerprint = norm.mean(axis=0)

    return {
        "feature_columns": list(FEATURE_COLUMNS),
        "fingerprint": fingerprint.tolist(),
        "n_source_tracks": len(rows),
    }


def get_fingerprint_recommendations(
    conn: sqlite3.Connection,
    top_n: int = 100,
    limit: int = 25,
) -> dict[str, Any]:
    """Rank library tracks by cosine similarity to the sonic fingerprint.

    Unplayed / rarely-played tracks are boosted so recommendations surface
    undiscovered music, not a recap of what the user already listens to.
    """
    import numpy as np  # noqa: PLC0415
    from sklearn.preprocessing import MinMaxScaler  # noqa: PLC0415

    fp_data = get_sonic_fingerprint(conn, top_n=top_n)
    if "error" in fp_data:
        return {**fp_data, "results": []}

    fingerprint = np.array(fp_data["fingerprint"], dtype=float)

    cols = ", ".join(f"taf.{c}" for c in FEATURE_COLUMNS)
    where = " AND ".join(f"taf.{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    rows = conn.execute(
        f"""
        SELECT taf.item_key, {cols},
               t.title, t.artist, t.album,
               COALESCE(pc.cnt, 0) AS play_count
        FROM track_audio_features taf
        JOIN tracks t ON taf.item_key = t.item_key
        LEFT JOIN (
            SELECT LOWER(track_title) AS norm_title, LOWER(artist) AS norm_artist,
                   COUNT(*) AS cnt
            FROM listening_history
            GROUP BY LOWER(track_title), LOWER(artist)
        ) pc ON LOWER(t.title) = pc.norm_title AND LOWER(t.artist) = pc.norm_artist
        WHERE {where}
        """
    ).fetchall()

    if not rows:
        return {"error": "No analysed tracks found", "results": []}

    matrix = np.array(
        [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows], dtype=float
    )
    scaler = MinMaxScaler()
    norm = scaler.fit_transform(matrix)

    fp_norm = np.linalg.norm(fingerprint)
    row_norms = np.linalg.norm(norm, axis=1)
    similarities = np.zeros(len(rows))
    valid = row_norms > 0
    if fp_norm > 0:
        similarities[valid] = (norm[valid] @ fingerprint) / (row_norms[valid] * fp_norm)

    # Boost tracks the user hasn't played much (discovery factor)
    play_counts = np.array([r["play_count"] for r in rows], dtype=float)
    boost = 1.0 / (1.0 + play_counts * 0.1)
    scores = similarities * boost

    order = np.argsort(-scores)
    results = []
    for idx in order[:limit]:
        r = rows[idx]
        results.append(
            {
                "item_key": r["item_key"],
                "title": r["title"],
                "artist": r["artist"],
                "album": r["album"],
                "similarity": round(float(similarities[idx]), 4),
                "play_count": int(r["play_count"]),
            }
        )

    return {
        "fingerprint": fp_data,
        "results": results,
        "n_pool": len(rows),
    }
