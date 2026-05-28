"""Song-path finding: smoothest bridge between two tracks.

Strategies (``method`` param):
* ``"features"`` / ``"greedy"`` — beam-search walk in normalised audio-feature
  space, biased toward the target. Fast, O(steps × n × beam_width).
* ``"graph"`` — Dijkstra over a sklearn k-NN feature graph. Tends to find
  globally smoother paths.
* ``"clap"`` — Dijkstra over a k-NN graph of CLAP audio embeddings (cosine).
  Captures timbre / instrumentation beyond the 6-feature vector.
* ``"hybrid"`` — Dijkstra over a k-NN graph whose edges combine CLAP cosine
  distance and normalised feature distance (0.6 · clap + 0.4 · features).

Performance vs v13.0:
- Feature / CLAP / hybrid tables are cached in memory between requests;
  call ``invalidate_song_path_cache()`` after a library sync to rebuild.
- k-NN graphs use sklearn ``NearestNeighbors`` (O(n log n)) instead of
  the previous O(n²) pure-Python loops.
- Full pairwise distance matrices are replaced by neighbour-only lookups,
  slashing memory usage for large libraries.

Algorithm improvements:
- Greedy walk → beam search (width 3) for more robust paths without local minima.
- Path simplification uses iterative smallest-detour removal instead of
  evenly-spaced waypoints, preserving transition smoothness.
- Mood centroids are normalised into the library's min-max feature space
  (fixes unit mismatch: BPM was compared in raw vs. normalised units).
- Camelot-wheel compatibility penalty added to edge weights.
- Genre-continuity penalty added to edge weights.
- Hybrid and CLAP-only methods now accept a ``mood`` parameter (hybrid
  applies feature-space mood bias; CLAP-only logs a warning and skips it).

Response additions:
- Each track dict contains ``transition_dist`` (float | None) — normalised
  Euclidean distance to the next track, used by the UI quality indicator.
"""

from __future__ import annotations

import heapq
import json
import logging
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np

from backend.audio_features.camelot import compatible as camelot_compatible
from backend.audio_features.clustering import FEATURE_COLUMNS

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

CLAP_WEIGHT = 0.6
FEATURE_WEIGHT = 0.4

# Denominator for normalising feature-space transition distances to ~[0, 1].
_FEAT_SCALE = float(len(FEATURE_COLUMNS)) ** 0.5

# ---------------------------------------------------------------------------
# In-memory cache (invalidated on library sync)
# ---------------------------------------------------------------------------

_CACHE_VERSION: int = 0
_CACHE: dict[int, dict[str, Any]] = {}


def invalidate_song_path_cache() -> None:
    """Bump cache version and discard all cached tables / graphs.

    Call this after ``library_cache.sync_library()`` completes so the next
    Song-Path request rebuilds from the updated database.
    """
    global _CACHE_VERSION
    _CACHE_VERSION += 1
    _CACHE.clear()
    logger.debug("Song-path cache invalidated (version %d)", _CACHE_VERSION)


def _cache_get(key: str) -> Any | None:
    return _CACHE.get(_CACHE_VERSION, {}).get(key)


def _cache_set(key: str, value: Any) -> None:
    _CACHE.setdefault(_CACHE_VERSION, {})[key] = value


# ---------------------------------------------------------------------------
# Mood centroids
# ---------------------------------------------------------------------------

_MOOD_CENTROIDS_RAW: dict[str, list[float]] | None = None


def _load_mood_centroid_raw(mood: str) -> list[float] | None:
    """Return raw (un-normalised) feature vector for a named mood."""
    global _MOOD_CENTROIDS_RAW
    if _MOOD_CENTROIDS_RAW is None:
        path = Path(__file__).parent.parent.parent / "data" / "mood_centroids.json"
        try:
            raw: dict[str, dict[str, float]] = json.loads(path.read_text())
            _MOOD_CENTROIDS_RAW = {
                m: [float(v.get(c, 0.5)) for c in FEATURE_COLUMNS]
                for m, v in raw.items()
            }
        except Exception:
            logger.warning("Could not load mood_centroids.json")
            _MOOD_CENTROIDS_RAW = {}
    return _MOOD_CENTROIDS_RAW.get(mood)


def _normalize_mood_centroid(
    mood: str, mins: list[float], maxs: list[float]
) -> list[float] | None:
    """Translate a raw mood centroid into the library's min-max feature space.

    Previously, the raw BPM value (e.g. 75) was compared directly against
    normalised vectors where BPM lives in [0, 1] — a unit mismatch that made
    the mood bias unreliable. This function fixes that.
    """
    raw = _load_mood_centroid_raw(mood)
    if raw is None:
        return None
    return [
        (v - mins[i]) / (maxs[i] - mins[i]) if maxs[i] > mins[i] else 0.5
        for i, v in enumerate(raw)
    ]


# ---------------------------------------------------------------------------
# Feature table (cached)
# ---------------------------------------------------------------------------


def _load_feature_table(
    conn: sqlite3.Connection,
) -> tuple[
    list[str],
    np.ndarray,
    dict[str, int],
    list[dict[str, Any]],
    list[float],
    list[float],
]:
    """Return (keys, norm_matrix, key→idx, metadata, raw_mins, raw_maxs).

    Results are cached in memory until ``invalidate_song_path_cache()`` is called.
    ``norm_matrix`` is a float32 numpy array of shape (n, len(FEATURE_COLUMNS))
    with columns min-max normalised to [0, 1] within the current library.
    ``raw_mins`` / ``raw_maxs`` are in the original (un-normalised) units and
    are needed to map mood centroids into the same space.
    """
    cached = _cache_get("feature")
    if cached is not None:
        return cached

    where = " AND ".join(f"af.{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    rows = conn.execute(
        f"""
        SELECT t.item_key, t.title, t.artist, t.album, t.year, t.genres,
               {", ".join("af." + c for c in FEATURE_COLUMNS)},
               af.camelot, af.key_root, af.key_mode
        FROM track_audio_features af
        JOIN tracks t ON t.item_key = af.item_key
        WHERE {where}
        """
    ).fetchall()

    if not rows:
        empty = (
            [],
            np.zeros((0, len(FEATURE_COLUMNS)), dtype=np.float32),
            {},
            [],
            [0.0] * len(FEATURE_COLUMNS),
            [1.0] * len(FEATURE_COLUMNS),
        )
        _cache_set("feature", empty)
        return empty

    raw = np.array(
        [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows], dtype=np.float32
    )
    raw_mins = raw.min(axis=0)
    raw_maxs = raw.max(axis=0)
    ranges = np.where(raw_maxs > raw_mins, raw_maxs - raw_mins, 1.0)
    norm = (raw - raw_mins) / ranges

    keys = [r["item_key"] for r in rows]
    metadata = [
        {
            "item_key": r["item_key"],
            "title": r["title"],
            "artist": r["artist"],
            "album": r["album"],
            "year": r["year"],
            "genres": r["genres"],
            "bpm": r["bpm"],
            "energy": r["energy"],
            "danceability": r["danceability"],
            "valence": r["valence"],
            "instrumentalness": r["instrumentalness"],
            "acousticness": r["acousticness"],
            "camelot": r["camelot"],
            "key_root": r["key_root"],
            "key_mode": r["key_mode"],
        }
        for r in rows
    ]
    key_to_idx = {k: i for i, k in enumerate(keys)}
    result = (keys, norm, key_to_idx, metadata, raw_mins.tolist(), raw_maxs.tolist())
    _cache_set("feature", result)
    return result


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _validate_endpoints(
    key_to_idx: dict[str, int], from_id: str, to_id: str
) -> tuple[int, int]:
    if from_id not in key_to_idx:
        raise KeyError(f"from_track_id not analyzed: {from_id}")
    if to_id not in key_to_idx:
        raise KeyError(f"to_track_id not analyzed: {to_id}")
    return key_to_idx[from_id], key_to_idx[to_id]


def _parse_genres(genres_str: str | None) -> frozenset[str]:
    if not genres_str:
        return frozenset()
    return frozenset(x.strip().lower() for x in str(genres_str).split(",") if x.strip())


def _add_transition_scores(
    path_idxs: list[int],
    matrix: np.ndarray,
    metadata: list[dict[str, Any]],
    scale: float = _FEAT_SCALE,
) -> list[dict[str, Any]]:
    """Attach ``transition_dist`` to each track dict (None for the last track)."""
    result = []
    for i, idx in enumerate(path_idxs):
        m = dict(metadata[idx])
        if i < len(path_idxs) - 1:
            diff = matrix[idx] - matrix[path_idxs[i + 1]]
            m["transition_dist"] = round(
                float(np.sqrt(np.dot(diff, diff))) / scale, 3
            )
        else:
            m["transition_dist"] = None
        result.append(m)
    return result


# ---------------------------------------------------------------------------
# k-NN graph construction (sklearn, O(n log n))
# ---------------------------------------------------------------------------


def _build_knn_graph_fast(
    matrix: np.ndarray,
    k: int,
    metadata: list[dict[str, Any]] | None = None,
    camelot_penalty: float = 0.15,
    genre_penalty: float = 0.20,
    metric: str = "euclidean",
) -> list[list[tuple[int, float]]]:
    """Sparse symmetric k-NN adjacency list using sklearn ``NearestNeighbors``.

    Optional Camelot-wheel incompatibility and genre-mismatch penalties are
    multiplied into edge weights so Dijkstra naturally avoids jarring transitions.
    """
    from sklearn.neighbors import NearestNeighbors  # noqa: PLC0415

    n = len(matrix)
    actual_k = min(k + 1, n)  # +1: sklearn includes the point itself at index 0
    nn = NearestNeighbors(
        n_neighbors=actual_k,
        algorithm="auto" if metric == "euclidean" else "brute",
        metric=metric,
    )
    nn.fit(matrix)
    dists_arr, idxs_arr = nn.kneighbors(matrix)

    camelot_map: list[str | None] = (
        [m.get("camelot") for m in metadata] if metadata else []
    )
    genre_map: list[frozenset[str]] = (
        [_parse_genres(m.get("genres")) for m in metadata] if metadata else []
    )

    adj: list[list[tuple[int, float]]] = [[] for _ in range(n)]
    for i in range(n):
        ci = camelot_map[i] if camelot_map else None
        compat = camelot_compatible(ci) if ci else set()
        gi = genre_map[i] if genre_map else frozenset()

        for dist, j in zip(dists_arr[i][1:], idxs_arr[i][1:], strict=False):
            j = int(j)
            w = float(dist)

            if camelot_map and ci and camelot_map[j] and camelot_map[j] not in compat:
                w *= 1.0 + camelot_penalty

            if genre_map and gi and genre_map[j] and not (gi & genre_map[j]):
                w *= 1.0 + genre_penalty

            adj[i].append((j, w))
            adj[j].append((i, w))  # symmetric; Dijkstra handles duplicate edges fine

    return adj


# ---------------------------------------------------------------------------
# Dijkstra
# ---------------------------------------------------------------------------


def _dijkstra(
    adj: list[list[tuple[int, float]]], src: int, dst: int
) -> list[int]:
    n = len(adj)
    dist = [float("inf")] * n
    prev: list[int] = [-1] * n
    dist[src] = 0.0
    pq: list[tuple[float, int]] = [(0.0, src)]
    while pq:
        d, u = heapq.heappop(pq)
        if u == dst:
            break
        if d > dist[u]:
            continue
        for v, w in adj[u]:
            nd = d + w
            if nd < dist[v]:
                dist[v] = nd
                prev[v] = u
                heapq.heappush(pq, (nd, v))
    if dist[dst] == float("inf"):
        return []
    path = [dst]
    while path[-1] != src:
        nxt = prev[path[-1]]
        if nxt == -1:
            return []
        path.append(nxt)
    return list(reversed(path))


# ---------------------------------------------------------------------------
# Path simplification
# ---------------------------------------------------------------------------


def _simplify_path_smooth(
    path_idxs: list[int],
    matrix: np.ndarray,
    target_len: int,
) -> list[int]:
    """Iteratively remove the interior node with the smallest transition detour.

    At each step, the node whose removal minimises
    ``dist(prev→node) + dist(node→next) − dist(prev→next)`` is dropped.
    This keeps the biggest sonic leaps out and preserves overall smoothness,
    unlike evenly-spaced waypoint sampling which can land on large gaps.

    Source (index 0) and destination (last index) are always preserved.
    """
    path = list(path_idxs)
    while len(path) > target_len:
        best_i = -1
        best_detour = float("inf")
        for i in range(1, len(path) - 1):
            prev, curr, nxt = path[i - 1], path[i], path[i + 1]
            before = float(np.linalg.norm(matrix[prev] - matrix[curr]))
            after = float(np.linalg.norm(matrix[curr] - matrix[nxt]))
            skip = float(np.linalg.norm(matrix[prev] - matrix[nxt]))
            detour = before + after - skip
            if detour < best_detour:
                best_detour = detour
                best_i = i
        if best_i == -1:
            break
        path.pop(best_i)
    return path


# ---------------------------------------------------------------------------
# Greedy beam-search walk (features method)
# ---------------------------------------------------------------------------


def find_song_path(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    mood: str | None = None,
    beam_width: int = 3,
) -> list[dict[str, Any]]:
    """Beam-search nearest-neighbor walk biased toward the target track.

    At each step the algorithm keeps the top ``beam_width`` candidate beams
    (ranked by distance-to-target from the current tip) and expands each beam
    by adding the best ``beam_width`` unvisited next-hops. This avoids the
    local-minima trap of pure greedy search while remaining lightweight.

    Mood centroids are now normalised into library feature space (BPM fix).
    """
    keys, matrix, key_to_idx, metadata, mins, maxs = _load_feature_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    target = matrix[dst_idx]
    mood_vec = (
        np.array(_normalize_mood_centroid(mood, mins, maxs), dtype=np.float32)
        if mood else None
    )

    # Beam state: (dist_to_target, path_indices, visited_set)
    beams: list[tuple[float, list[int], set[int]]] = [
        (float(np.linalg.norm(matrix[src_idx] - target)), [src_idx], {src_idx})
    ]

    for step in range(max_steps):
        alpha = 0.3 + 0.65 * (step / max(1, max_steps - 1))
        next_beams: list[tuple[float, list[int], set[int]]] = []

        for _score, path, visited in beams:
            if path[-1] == dst_idx:
                next_beams.append((_score, path, visited))
                continue

            current = matrix[path[-1]]
            bias = current + alpha * (target - current)
            if mood_vec is not None:
                bias = bias + 0.15 * (mood_vec - bias)

            # Vectorised distance from every track to the bias point
            diffs = matrix - bias
            dists_sq = (diffs * diffs).sum(axis=1)
            # Block already-visited nodes
            for vis in visited:
                dists_sq[vis] = float("inf")

            top_count = min(beam_width, int((dists_sq < float("inf")).sum()))
            if top_count == 0:
                next_beams.append((_score, path + [dst_idx], visited | {dst_idx}))
                continue

            top_idxs = np.argpartition(dists_sq, top_count - 1)[:top_count]
            for cand in top_idxs:
                cand = int(cand)
                new_path = path + [cand]
                new_visited = visited | {cand}
                score = float(np.linalg.norm(matrix[cand] - target))
                next_beams.append((score, new_path, new_visited))

        if not next_beams:
            break
        next_beams.sort(key=lambda b: b[0])
        beams = next_beams[:beam_width]

        if beams[0][1][-1] == dst_idx:
            break

    best_path = beams[0][1]
    if best_path[-1] != dst_idx:
        best_path.append(dst_idx)

    return _add_transition_scores(best_path, matrix, metadata)


# ---------------------------------------------------------------------------
# Graph method (Dijkstra over feature k-NN)
# ---------------------------------------------------------------------------


def find_song_path_graph(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    *,
    k: int = 10,
    mood: str | None = None,
    camelot_penalty: float = 0.15,
    genre_penalty: float = 0.20,
) -> list[dict[str, Any]]:
    """Dijkstra over a sklearn k-NN feature graph.

    Camelot-wheel and genre-continuity penalties are baked into edge weights.
    Mood re-weighting nudges Dijkstra toward mood-compatible segments.
    Over-long paths are compressed via smooth simplification.
    """
    keys, matrix, key_to_idx, metadata, mins, maxs = _load_feature_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    mood_vec = (
        np.array(_normalize_mood_centroid(mood, mins, maxs), dtype=np.float32)
        if mood else None
    )

    cache_key = f"adj_feat_k{k}_cp{camelot_penalty:.2f}_gp{genre_penalty:.2f}"
    adj = _cache_get(cache_key)
    if adj is None:
        adj = _build_knn_graph_fast(
            matrix,
            k=min(k, max(1, len(matrix) - 1)),
            metadata=metadata,
            camelot_penalty=camelot_penalty,
            genre_penalty=genre_penalty,
        )
        _cache_set(cache_key, adj)

    if mood_vec is not None:
        adj_mood: list[list[tuple[int, float]]] = []
        for i, neighbors in enumerate(adj):
            node_mood_dist = float(np.linalg.norm(matrix[i] - mood_vec))
            adj_mood.append(
                [(j, w * (1.0 + 0.2 * node_mood_dist)) for j, w in neighbors]
            )
        adj = adj_mood

    path = _dijkstra(adj, src_idx, dst_idx)
    if not path:
        return find_song_path(conn, from_track_id, to_track_id, max_steps, mood=mood)

    target_len = max_steps + 1
    if len(path) > target_len:
        path = _simplify_path_smooth(path, matrix, target_len)

    return _add_transition_scores(path, matrix, metadata)


# ---------------------------------------------------------------------------
# CLAP table (cached)
# ---------------------------------------------------------------------------


def _row_to_metadata(row: Any) -> dict[str, Any]:
    return {
        "item_key": row["item_key"],
        "title": row["title"],
        "artist": row["artist"],
        "album": row["album"],
        "year": row["year"],
        "genres": row["genres"],
        "bpm": row["bpm"],
        "energy": row["energy"],
        "danceability": row["danceability"],
        "valence": row["valence"],
        "instrumentalness": row["instrumentalness"],
        "acousticness": row["acousticness"],
        "camelot": row["camelot"],
        "key_root": row["key_root"],
        "key_mode": row["key_mode"],
    }


def _load_clap_table(
    conn: sqlite3.Connection,
) -> tuple[list[str], np.ndarray, dict[str, int], list[dict[str, Any]]]:
    cached = _cache_get("clap")
    if cached is not None:
        return cached

    rows = conn.execute(
        """
        SELECT t.item_key, t.title, t.artist, t.album, t.year, t.genres,
               ce.embedding,
               af.bpm, af.energy, af.danceability, af.valence,
               af.instrumentalness, af.acousticness,
               af.camelot, af.key_root, af.key_mode
        FROM clap_embeddings ce
        JOIN tracks t ON t.item_key = ce.item_key
        LEFT JOIN track_audio_features af ON af.item_key = ce.item_key
        """
    ).fetchall()

    if not rows:
        result = ([], np.zeros((0, 0), dtype=np.float32), {}, [])
        _cache_set("clap", result)
        return result

    matrix = np.stack(
        [np.frombuffer(r["embedding"], dtype=np.float32) for r in rows]
    )
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    matrix = matrix / (norms + 1e-12)

    keys = [r["item_key"] for r in rows]
    metadata = [_row_to_metadata(r) for r in rows]
    key_to_idx = {k: i for i, k in enumerate(keys)}
    result = (keys, matrix, key_to_idx, metadata)
    _cache_set("clap", result)
    return result


# ---------------------------------------------------------------------------
# Hybrid table (cached)
# ---------------------------------------------------------------------------


def _load_hybrid_table(
    conn: sqlite3.Connection,
) -> tuple[
    list[str],
    np.ndarray,
    np.ndarray,
    dict[str, int],
    list[dict[str, Any]],
    list[float],
    list[float],
]:
    cached = _cache_get("hybrid")
    if cached is not None:
        return cached

    where_features = " AND ".join(f"af.{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    rows = conn.execute(
        f"""
        SELECT t.item_key, t.title, t.artist, t.album, t.year, t.genres,
               ce.embedding,
               {", ".join("af." + c for c in FEATURE_COLUMNS)},
               af.camelot, af.key_root, af.key_mode
        FROM clap_embeddings ce
        JOIN tracks t ON t.item_key = ce.item_key
        JOIN track_audio_features af ON af.item_key = ce.item_key
        WHERE {where_features}
        """
    ).fetchall()

    if not rows:
        empty: tuple = (
            [],
            np.zeros((0, 0), dtype=np.float32),
            np.zeros((0, len(FEATURE_COLUMNS)), dtype=np.float32),
            {},
            [],
            [0.0] * len(FEATURE_COLUMNS),
            [1.0] * len(FEATURE_COLUMNS),
        )
        _cache_set("hybrid", empty)
        return empty

    clap_matrix = np.stack(
        [np.frombuffer(r["embedding"], dtype=np.float32) for r in rows]
    )
    clap_norms = np.linalg.norm(clap_matrix, axis=1, keepdims=True)
    clap_matrix = clap_matrix / (clap_norms + 1e-12)

    raw_feat = np.array(
        [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows], dtype=np.float32
    )
    feat_mins = raw_feat.min(axis=0)
    feat_maxs = raw_feat.max(axis=0)
    ranges = np.where(feat_maxs > feat_mins, feat_maxs - feat_mins, 1.0)
    feat_matrix = (raw_feat - feat_mins) / ranges

    keys = [r["item_key"] for r in rows]
    metadata = [_row_to_metadata(r) for r in rows]
    key_to_idx = {k: i for i, k in enumerate(keys)}
    result = (
        keys,
        clap_matrix,
        feat_matrix,
        key_to_idx,
        metadata,
        feat_mins.tolist(),
        feat_maxs.tolist(),
    )
    _cache_set("hybrid", result)
    return result


# ---------------------------------------------------------------------------
# CLAP path
# ---------------------------------------------------------------------------


def _simplify_path_cosine(
    path_idxs: list[int], matrix: np.ndarray, target_len: int
) -> list[int]:
    """Smooth simplification using cosine distances (for CLAP paths)."""
    path = list(path_idxs)
    while len(path) > target_len:
        best_i = -1
        best_detour = float("inf")
        for i in range(1, len(path) - 1):
            prev, curr, nxt = path[i - 1], path[i], path[i + 1]
            before = float(1.0 - np.dot(matrix[prev], matrix[curr]))
            after = float(1.0 - np.dot(matrix[curr], matrix[nxt]))
            skip = float(1.0 - np.dot(matrix[prev], matrix[nxt]))
            detour = max(0.0, before + after - skip)
            if detour < best_detour:
                best_detour = detour
                best_i = i
        if best_i == -1:
            break
        path.pop(best_i)
    return path


def find_song_path_clap(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    *,
    k: int = 10,
    mood: str | None = None,
) -> list[dict[str, Any]]:
    """Dijkstra path over a k-NN graph built from CLAP audio embeddings.

    ``mood`` is accepted for API consistency but is not applied — CLAP
    embeddings do not share a feature space with the mood centroids.
    """
    if mood:
        logger.info(
            "Song-path CLAP mode: mood=%r ignored (no feature vectors in CLAP space)",
            mood,
        )

    keys, matrix, key_to_idx, metadata = _load_clap_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    cache_key = f"adj_clap_k{k}"
    adj = _cache_get(cache_key)
    if adj is None:
        adj = _build_knn_graph_fast(
            matrix,
            k=min(k, max(1, len(matrix) - 1)),
            metadata=metadata,
            camelot_penalty=0.0,
            genre_penalty=0.0,
            metric="cosine",
        )
        _cache_set(cache_key, adj)

    path = _dijkstra(adj, src_idx, dst_idx)
    if not path:
        return []

    target_len = max_steps + 1
    if len(path) > target_len:
        path = _simplify_path_cosine(path, matrix, target_len)

    # Attach CLAP cosine transition distances
    result = []
    for i, idx in enumerate(path):
        m = dict(metadata[idx])
        if i < len(path) - 1:
            cos_dist = max(0.0, float(1.0 - np.dot(matrix[idx], matrix[path[i + 1]])))
            m["transition_dist"] = round(cos_dist, 3)
        else:
            m["transition_dist"] = None
        result.append(m)
    return result


# ---------------------------------------------------------------------------
# Hybrid path
# ---------------------------------------------------------------------------


def find_song_path_hybrid(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    *,
    k: int = 10,
    clap_weight: float = CLAP_WEIGHT,
    feature_weight: float = FEATURE_WEIGHT,
    mood: str | None = None,
    camelot_penalty: float = 0.15,
    genre_penalty: float = 0.20,
) -> list[dict[str, Any]]:
    """Dijkstra over a union k-NN graph weighted by clap_weight·clap_cos + feature_weight·feat_dist.

    Only tracks with both a CLAP embedding and a complete audio-feature row are
    included. Mood bias, Camelot, and genre penalties are applied via feature vectors.
    """
    keys, clap_matrix, feat_matrix, key_to_idx, metadata, feat_mins, feat_maxs = (
        _load_hybrid_table(conn)
    )
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    mood_vec = (
        np.array(_normalize_mood_centroid(mood, feat_mins, feat_maxs), dtype=np.float32)
        if mood else None
    )

    cache_key = (
        f"adj_hybrid_k{k}_cw{clap_weight:.2f}_fw{feature_weight:.2f}"
        f"_cp{camelot_penalty:.2f}_gp{genre_penalty:.2f}"
    )
    adj = _cache_get(cache_key)
    if adj is None:
        adj = _build_hybrid_adj(
            clap_matrix,
            feat_matrix,
            metadata,
            k=min(k, max(1, len(keys) - 1)),
            clap_weight=clap_weight,
            feature_weight=feature_weight,
            camelot_penalty=camelot_penalty,
            genre_penalty=genre_penalty,
        )
        _cache_set(cache_key, adj)

    if mood_vec is not None:
        adj_mood: list[list[tuple[int, float]]] = []
        for i, neighbors in enumerate(adj):
            node_mood_dist = float(np.linalg.norm(feat_matrix[i] - mood_vec))
            adj_mood.append(
                [(j, w * (1.0 + 0.2 * node_mood_dist)) for j, w in neighbors]
            )
        adj = adj_mood

    path = _dijkstra(adj, src_idx, dst_idx)
    if not path:
        return []

    target_len = max_steps + 1
    if len(path) > target_len:
        path = _simplify_path_smooth(path, feat_matrix, target_len)

    return _add_transition_scores(path, feat_matrix, metadata)


def _build_hybrid_adj(
    clap_matrix: np.ndarray,
    feat_matrix: np.ndarray,
    metadata: list[dict[str, Any]],
    k: int,
    clap_weight: float,
    feature_weight: float,
    camelot_penalty: float,
    genre_penalty: float,
) -> list[list[tuple[int, float]]]:
    """Build the hybrid adjacency list.

    We run two separate sklearn k-NN queries (CLAP cosine + feature Euclidean),
    take the union of discovered edges, and combine weights. This avoids an
    O(n²) full pairwise matrix while still finding useful cross-space neighbours.
    """
    from sklearn.neighbors import NearestNeighbors  # noqa: PLC0415

    n = len(feat_matrix)
    actual_k = min(k + 1, n)

    nn_clap = NearestNeighbors(n_neighbors=actual_k, algorithm="brute", metric="cosine")
    nn_clap.fit(clap_matrix)
    clap_dists, clap_idxs = nn_clap.kneighbors(clap_matrix)

    nn_feat = NearestNeighbors(n_neighbors=actual_k, algorithm="auto", metric="euclidean")
    nn_feat.fit(feat_matrix)
    feat_dists, feat_idxs = nn_feat.kneighbors(feat_matrix)

    # Collect per-edge distances from both spaces
    edge_clap: dict[tuple[int, int], float] = {}
    edge_feat: dict[tuple[int, int], float] = {}

    for i in range(n):
        for d, j in zip(clap_dists[i][1:], clap_idxs[i][1:], strict=False):
            j = int(j)
            key = (min(i, j), max(i, j))
            edge_clap.setdefault(key, float(d))
        for d, j in zip(feat_dists[i][1:], feat_idxs[i][1:], strict=False):
            j = int(j)
            key = (min(i, j), max(i, j))
            edge_feat.setdefault(key, float(d) / _FEAT_SCALE)

    camelot_map = [m.get("camelot") for m in metadata]
    genre_map = [_parse_genres(m.get("genres")) for m in metadata]

    adj: list[dict[int, float]] = [{} for _ in range(n)]
    for (i, j) in set(edge_clap.keys()) | set(edge_feat.keys()):
        cd = edge_clap.get((i, j), 1.0)
        fd = edge_feat.get((i, j), 1.0)
        w = clap_weight * cd + feature_weight * fd

        ci, cj = camelot_map[i], camelot_map[j]
        if ci and cj and cj not in camelot_compatible(ci):
            w *= 1.0 + camelot_penalty

        gi, gj = genre_map[i], genre_map[j]
        if gi and gj and not (gi & gj):
            w *= 1.0 + genre_penalty

        # Keep the smallest combined weight for this edge pair
        if j not in adj[i] or adj[i][j] > w:
            adj[i][j] = w
            adj[j][i] = w

    return [list(d.items()) for d in adj]
