"""Song Alchemy (v13.0): ADD/SUBTRACT vector arithmetic over audio features.

Given a set of positive tracks (ADD) and negative tracks (SUBTRACT), compute
a target sonic profile via ``mean(add) - 0.5 * mean(subtract)`` and rank the
rest of the library by cosine similarity to that profile.
"""

from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING, Any

import numpy as np

from backend.audio_features.clustering import FEATURE_COLUMNS

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

SUBTRACT_WEIGHT = 0.5  # dampens "less of this" so it doesn't overshoot.

# ---------------------------------------------------------------------------
# Module-level matrix cache (5-minute TTL)
# ---------------------------------------------------------------------------

_matrix_cache: dict = {}
_CACHE_TTL = 300.0  # seconds


def invalidate_matrix_cache() -> None:
    """Clear the in-memory matrix cache. Call from sync hooks."""
    global _matrix_cache
    _matrix_cache = {}


def _load_feature_matrix(conn: sqlite3.Connection):
    global _matrix_cache

    now = time.monotonic()
    if _matrix_cache and (now - _matrix_cache.get("ts", 0.0)) < _CACHE_TTL:
        return _matrix_cache["keys"], _matrix_cache["matrix"], _matrix_cache["metadata"]

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

    if not rows:
        return [], np.empty((0, len(FEATURE_COLUMNS)), dtype=np.float32), []

    raw = np.array([[float(r[c]) for c in FEATURE_COLUMNS] for r in rows], dtype=np.float32)

    col_min = np.min(raw, axis=0)
    col_max = np.max(raw, axis=0)
    col_range = col_max - col_min
    # Avoid divide-by-zero for zero-range columns
    col_range_safe = np.where(col_range > 0, col_range, 1.0)
    matrix = (raw - col_min) / col_range_safe
    # Zero out columns where range was 0 (all values were identical)
    matrix[:, col_range == 0] = 0.0

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

    _matrix_cache = {"ts": now, "keys": keys, "matrix": matrix, "metadata": metadata}
    return keys, matrix, metadata


def _mean_vector(vectors) -> np.ndarray:
    """Return mean of vectors. Accepts list-of-lists or np.ndarray."""
    if vectors is None or (hasattr(vectors, "__len__") and len(vectors) == 0):
        return np.zeros(len(FEATURE_COLUMNS), dtype=np.float32)
    arr = np.array(vectors, dtype=np.float32)
    return np.mean(arr, axis=0)


def _cosine_similarity(a, b) -> float:
    a = np.asarray(a, dtype=np.float32)
    b = np.asarray(b, dtype=np.float32)
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na == 0.0 or nb == 0.0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


def compute_alchemy(
    conn: sqlite3.Connection,
    add_track_ids: list[str],
    subtract_track_ids: list[str],
    limit: int = 25,
    subtract_weight: float = SUBTRACT_WEIGHT,
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

    add_vecs = np.array([matrix[key_to_idx[k]] for k in add_track_ids], dtype=np.float32)
    sub_vecs = (
        np.array([matrix[key_to_idx[k]] for k in subtract_track_ids], dtype=np.float32)
        if subtract_track_ids
        else None
    )

    add_mean = _mean_vector(add_vecs)
    sub_mean = _mean_vector(sub_vecs) if sub_vecs is not None else np.zeros(len(FEATURE_COLUMNS), dtype=np.float32)

    target = add_mean - subtract_weight * sub_mean

    # Vectorized cosine similarity: matrix @ target / (norms * target_norm)
    target_norm = np.linalg.norm(target)
    if target_norm == 0.0:
        scores = np.zeros(len(keys), dtype=np.float32)
    else:
        norms = np.linalg.norm(matrix, axis=1)
        denom = norms * target_norm
        # Avoid divide-by-zero for zero-norm rows
        safe_denom = np.where(denom > 0, denom, 1.0)
        scores = (matrix @ target) / safe_denom
        scores = np.where(denom > 0, scores, 0.0)

    # Exclude input tracks
    excluded_indices = {key_to_idx[k] for k in excluded if k in key_to_idx}
    for idx in excluded_indices:
        scores[idx] = -np.inf

    sorted_indices = np.argsort(-scores)

    results = []
    for i in sorted_indices[:limit]:
        i = int(i)
        if scores[i] == -np.inf:
            break
        item = dict(metadata[i])
        item["similarity"] = round(float(scores[i]), 4)
        results.append(item)

    # Also return the average of the result set so the frontend can render
    # the radar comparison (target vs. realized).
    if results:
        result_vecs = np.array([matrix[key_to_idx[r["item_key"]]] for r in results], dtype=np.float32)
        result_mean = _mean_vector(result_vecs)
    else:
        result_mean = np.zeros(len(FEATURE_COLUMNS), dtype=np.float32)

    return {
        "target": dict(zip(FEATURE_COLUMNS, target.tolist(), strict=False)),
        "result_mean": dict(zip(FEATURE_COLUMNS, result_mean.tolist(), strict=False)),
        "feature_columns": list(FEATURE_COLUMNS),
        "results": results,
        "n_pool": len(matrix) - len(excluded),
    }
