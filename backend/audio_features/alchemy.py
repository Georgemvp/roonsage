"""Song Alchemy (v13.0): ADD/SUBTRACT vector arithmetic over audio features.

Given a set of positive tracks (ADD) and negative tracks (SUBTRACT), compute
a target sonic profile via ``mean(add) - 0.5 * mean(subtract)`` and rank the
rest of the library by cosine similarity to that profile.
"""

from __future__ import annotations

import logging
import math
from typing import TYPE_CHECKING, Any

from backend.audio_features.clustering import FEATURE_COLUMNS

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

SUBTRACT_WEIGHT = 0.5  # dampens "less of this" so it doesn't overshoot.


def _load_feature_matrix(conn: sqlite3.Connection):
    where = " AND ".join(f"af.{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    rows = conn.execute(
        f"""
        SELECT t.item_key, t.title, t.artist, t.album, t.year, t.genres,
               {", ".join("af." + c for c in FEATURE_COLUMNS)}
        FROM track_audio_features af
        JOIN tracks t ON t.item_key = af.item_key
        WHERE {where}
        """
    ).fetchall()

    raw = [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows]
    if not raw:
        return [], [], []

    mins = [min(col) for col in zip(*raw, strict=False)]
    maxs = [max(col) for col in zip(*raw, strict=False)]
    norm: list[list[float]] = []
    for vec in raw:
        norm.append(
            [
                (v - mins[i]) / (maxs[i] - mins[i]) if maxs[i] > mins[i] else 0.0
                for i, v in enumerate(vec)
            ]
        )

    keys = [r["item_key"] for r in rows]
    metadata = [
        {
            "item_key": r["item_key"],
            "title": r["title"],
            "artist": r["artist"],
            "album": r["album"],
            "year": r["year"],
            "genres": r["genres"],
            **{c: r[c] for c in FEATURE_COLUMNS},
        }
        for r in rows
    ]
    return keys, norm, metadata


def _mean_vector(vectors: list[list[float]]) -> list[float]:
    if not vectors:
        return [0.0] * len(FEATURE_COLUMNS)
    n = len(vectors)
    return [sum(v[d] for v in vectors) / n for d in range(len(FEATURE_COLUMNS))]


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=False))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (na * nb)


def compute_alchemy(
    conn: sqlite3.Connection,
    add_track_ids: list[str],
    subtract_track_ids: list[str],
    limit: int = 25,
) -> dict[str, Any]:
    """Compute the target profile and return the top-N closest tracks."""
    if not add_track_ids:
        raise ValueError("At least one ADD track is required")

    keys, matrix, metadata = _load_feature_matrix(conn)
    if not keys:
        return {"target": None, "results": [], "n_pool": 0}

    key_to_idx = {k: i for i, k in enumerate(keys)}
    excluded = set(add_track_ids) | set(subtract_track_ids)

    missing = [k for k in (add_track_ids + subtract_track_ids) if k not in key_to_idx]
    if missing:
        raise KeyError(f"Tracks not analyzed: {missing}")

    add_vecs = [matrix[key_to_idx[k]] for k in add_track_ids]
    sub_vecs = [matrix[key_to_idx[k]] for k in subtract_track_ids]

    add_mean = _mean_vector(add_vecs)
    sub_mean = _mean_vector(sub_vecs) if sub_vecs else [0.0] * len(FEATURE_COLUMNS)

    target = [
        add_mean[d] - SUBTRACT_WEIGHT * sub_mean[d] for d in range(len(FEATURE_COLUMNS))
    ]

    scored: list[tuple[float, int]] = []
    for i, vec in enumerate(matrix):
        if keys[i] in excluded:
            continue
        scored.append((_cosine_similarity(target, vec), i))
    scored.sort(reverse=True)

    results = []
    for score, i in scored[:limit]:
        item = dict(metadata[i])
        item["similarity"] = round(float(score), 4)
        results.append(item)

    # Also return the average of the result set so the frontend can render
    # the radar comparison (target vs. realized).
    if results:
        result_vecs = [matrix[key_to_idx[r["item_key"]]] for r in results]
        result_mean = _mean_vector(result_vecs)
    else:
        result_mean = [0.0] * len(FEATURE_COLUMNS)

    return {
        "target": dict(zip(FEATURE_COLUMNS, target, strict=False)),
        "result_mean": dict(zip(FEATURE_COLUMNS, result_mean, strict=False)),
        "feature_columns": list(FEATURE_COLUMNS),
        "results": results,
        "n_pool": len(matrix) - len(excluded),
    }
