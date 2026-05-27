"""Song-path finding (v13.0): smoothest bridge between two tracks.

Strategies, parameterised by ``method``:

* ``"features"`` (default, alias ``"greedy"``) — greedy nearest-neighbor walk
  in the normalised audio-feature space, biased toward the target. Cheap, no
  graph construction.
* ``"graph"`` — Dijkstra over a k-NN graph built from feature distances; tends
  to find a smoother route but pays O(n·k) up front.
* ``"clap"`` — Dijkstra over a k-NN graph built from cosine distances between
  CLAP audio embeddings. Captures richer sonic similarity (timbre, instrumentation)
  than the 6-feature vector but ignores BPM/key structure.
* ``"hybrid"`` — Dijkstra over a k-NN graph whose edges combine CLAP cosine
  distance and feature distance (``0.6·clap + 0.4·features``). Aims for
  natural-sounding transitions that also keep BPM/key smooth.

All strategies return an ordered list of dicts compatible with the REST
response model (item_key, title, artist, album, plus audio-feature metadata).
"""

from __future__ import annotations

import heapq
import json
import logging
from pathlib import Path
from typing import TYPE_CHECKING, Any

from backend.audio_features.clustering import FEATURE_COLUMNS

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

CLAP_WEIGHT = 0.6
FEATURE_WEIGHT = 0.4

_MOOD_CENTROIDS: dict[str, list[float]] | None = None


def _load_mood_centroid(mood: str) -> list[float] | None:
    """Return the normalised feature vector for a named mood, or None."""
    global _MOOD_CENTROIDS
    if _MOOD_CENTROIDS is None:
        path = Path(__file__).parent.parent.parent / "data" / "mood_centroids.json"
        try:
            raw: dict[str, dict[str, float]] = json.loads(path.read_text())
            _MOOD_CENTROIDS = {
                m: [float(v.get(c, 0.5)) for c in FEATURE_COLUMNS]
                for m, v in raw.items()
            }
        except Exception:
            logger.warning("Could not load mood_centroids.json")
            _MOOD_CENTROIDS = {}
    return _MOOD_CENTROIDS.get(mood)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _load_feature_table(
    conn: sqlite3.Connection,
) -> tuple[list[str], list[list[float]], dict[str, int], list[dict[str, Any]]]:
    """Pull (keys, normalized matrix, key→idx, metadata) for every analyzed track."""
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
        return [], [], {}, []

    raw = [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows]
    # MinMax normalize column-wise so distances aren't dominated by BPM range.
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
    return keys, norm, key_to_idx, metadata


def _euclid_sq(a: list[float], b: list[float]) -> float:
    return sum((x - y) * (x - y) for x, y in zip(a, b, strict=False))


def _validate_endpoints(
    key_to_idx: dict[str, int], from_id: str, to_id: str
) -> tuple[int, int]:
    if from_id not in key_to_idx:
        raise KeyError(f"from_track_id not analyzed: {from_id}")
    if to_id not in key_to_idx:
        raise KeyError(f"to_track_id not analyzed: {to_id}")
    return key_to_idx[from_id], key_to_idx[to_id]


# ---------------------------------------------------------------------------
# Greedy walk
# ---------------------------------------------------------------------------


def find_song_path(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    mood: str | None = None,
) -> list[dict[str, Any]]:
    """Greedy nearest-neighbor walk biased toward the target track.

    At each step the algorithm picks the unvisited candidate that minimizes
    distance to ``current_position + alpha * (target - current_position)``;
    ``alpha`` grows from 0.3 → 1.0 as we approach the target so the early
    steps explore freely, while the last few snap toward the destination.

    When ``mood`` is given, a small additional bias (weight 0.15) pulls each
    step toward the mood centroid, shaping the character of the bridge.
    """
    keys, matrix, key_to_idx, metadata = _load_feature_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    n_dim = len(FEATURE_COLUMNS)
    target = matrix[dst_idx]
    mood_vec = _load_mood_centroid(mood) if mood else None
    visited: set[int] = {src_idx}
    path: list[int] = [src_idx]
    current = matrix[src_idx]

    for step in range(max_steps):
        alpha = 0.3 + 0.65 * (step / max(1, max_steps - 1))
        bias = [current[d] + alpha * (target[d] - current[d]) for d in range(n_dim)]
        if mood_vec is not None:
            bias = [bias[d] + 0.15 * (mood_vec[d] - bias[d]) for d in range(n_dim)]

        best_idx = -1
        best_d = float("inf")
        for i, vec in enumerate(matrix):
            if i in visited:
                continue
            d = _euclid_sq(vec, bias)
            if d < best_d:
                best_d = d
                best_idx = i

        if best_idx == -1:
            break
        path.append(best_idx)
        visited.add(best_idx)
        current = matrix[best_idx]

        if best_idx == dst_idx:
            break

    if path[-1] != dst_idx:
        path.append(dst_idx)

    return [metadata[i] for i in path]


# ---------------------------------------------------------------------------
# Graph (Dijkstra)
# ---------------------------------------------------------------------------


def _build_knn_graph(matrix: list[list[float]], k: int) -> list[list[tuple[int, float]]]:
    """Sparse symmetric k-NN graph with euclidean edge weights."""
    n = len(matrix)
    adj: list[list[tuple[int, float]]] = [[] for _ in range(n)]
    # O(n^2) — fine for libraries up to ~10k tracks. If this becomes a
    # bottleneck swap in sklearn.neighbors.NearestNeighbors here.
    for i in range(n):
        dists: list[tuple[float, int]] = []
        for j in range(n):
            if i == j:
                continue
            dists.append((_euclid_sq(matrix[i], matrix[j]), j))
        dists.sort()
        for d, j in dists[:k]:
            w = d ** 0.5
            adj[i].append((j, w))
            adj[j].append((i, w))  # symmetric — duplicates harmless for Dijkstra
    return adj


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


def find_song_path_graph(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    *,
    k: int = 10,
    mood: str | None = None,
) -> list[dict[str, Any]]:
    """Build a k-NN graph and walk Dijkstra's shortest path.

    If the shortest path has more than ``max_steps + 1`` nodes the result is
    simplified by taking ``max_steps`` evenly-spaced waypoints (including
    the source and destination).

    When ``mood`` is given, edge weights get a small mood-proximity bonus that
    nudges Dijkstra toward mood-compatible segments.
    """
    keys, matrix, key_to_idx, metadata = _load_feature_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)
    mood_vec = _load_mood_centroid(mood) if mood else None

    adj = _build_knn_graph(matrix, k=min(k, max(1, len(matrix) - 1)))

    if mood_vec is not None:
        # Re-weight edges: nodes far from the mood centroid cost more.
        adj_mood: list[list[tuple[int, float]]] = []
        for i, neighbors in enumerate(adj):
            node_mood_dist = _euclid_sq(matrix[i], mood_vec) ** 0.5
            adj_mood.append([(j, w * (1.0 + 0.2 * node_mood_dist)) for j, w in neighbors])
        adj = adj_mood

    path = _dijkstra(adj, src_idx, dst_idx)
    if not path:
        return find_song_path(conn, from_track_id, to_track_id, max_steps, mood=mood)

    target_len = max_steps + 1
    if len(path) > target_len:
        idxs = [
            round(i * (len(path) - 1) / (target_len - 1)) for i in range(target_len)
        ]
        seen: set[int] = set()
        path = [path[i] for i in idxs if not (path[i] in seen or seen.add(path[i]))]
    return [metadata[i] for i in path]


# ---------------------------------------------------------------------------
# CLAP-based variants (v13.2)
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
) -> tuple[list[str], Any, dict[str, int], list[dict[str, Any]]]:
    """Pull (keys, L2-normalised CLAP matrix, key→idx, metadata) for embedded tracks.

    Audio-feature columns are left-joined and may be ``None`` for tracks where
    only the CLAP embedding has been computed.
    """
    import numpy as np  # noqa: PLC0415

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
        return [], np.zeros((0, 0), dtype=np.float32), {}, []

    matrix = np.stack(
        [np.frombuffer(r["embedding"], dtype=np.float32) for r in rows]
    )
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    matrix = matrix / (norms + 1e-12)

    keys = [r["item_key"] for r in rows]
    metadata = [_row_to_metadata(r) for r in rows]
    key_to_idx = {k: i for i, k in enumerate(keys)}
    return keys, matrix, key_to_idx, metadata


def _load_hybrid_table(
    conn: sqlite3.Connection,
) -> tuple[
    list[str], Any, list[list[float]], dict[str, int], list[dict[str, Any]]
]:
    """Pull tracks that have BOTH CLAP embeddings and full audio features.

    Returns ``(keys, clap_matrix_normalised, feature_matrix_normalised,
    key_to_idx, metadata)``. Feature columns are MinMax-normalised the same way
    as ``_load_feature_table`` so feature distances live in [0, ~sqrt(n_dim)].
    """
    import numpy as np  # noqa: PLC0415

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
        return [], np.zeros((0, 0), dtype=np.float32), [], {}, []

    clap_matrix = np.stack(
        [np.frombuffer(r["embedding"], dtype=np.float32) for r in rows]
    )
    clap_norms = np.linalg.norm(clap_matrix, axis=1, keepdims=True)
    clap_matrix = clap_matrix / (clap_norms + 1e-12)

    raw_features = [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows]
    mins = [min(col) for col in zip(*raw_features, strict=False)]
    maxs = [max(col) for col in zip(*raw_features, strict=False)]
    feature_matrix: list[list[float]] = [
        [
            (v - mins[i]) / (maxs[i] - mins[i]) if maxs[i] > mins[i] else 0.0
            for i, v in enumerate(vec)
        ]
        for vec in raw_features
    ]

    keys = [r["item_key"] for r in rows]
    metadata = [_row_to_metadata(r) for r in rows]
    key_to_idx = {k: i for i, k in enumerate(keys)}
    return keys, clap_matrix, feature_matrix, key_to_idx, metadata


def _build_knn_graph_distances(
    distance_matrix: list[list[float]], k: int
) -> list[list[tuple[int, float]]]:
    """Build a sparse symmetric k-NN adjacency list from a precomputed distance matrix."""
    n = len(distance_matrix)
    adj: list[list[tuple[int, float]]] = [[] for _ in range(n)]
    for i in range(n):
        dists = [(distance_matrix[i][j], j) for j in range(n) if j != i]
        dists.sort()
        for d, j in dists[:k]:
            adj[i].append((j, d))
            adj[j].append((i, d))
    return adj


def _cosine_distance_matrix(matrix: Any) -> list[list[float]]:
    """Pairwise cosine distance for an L2-normalised matrix (1 − cosine sim)."""
    import numpy as np  # noqa: PLC0415

    sim = matrix @ matrix.T
    # Clamp for numerical safety, then convert to distance in [0, 2].
    sim = np.clip(sim, -1.0, 1.0)
    return (1.0 - sim).tolist()


def _feature_distance_matrix(feature_matrix: list[list[float]]) -> list[list[float]]:
    """Pairwise Euclidean distance scaled to roughly [0, 1] by sqrt(n_dim)."""
    n = len(feature_matrix)
    n_dim = max(1, len(feature_matrix[0]) if feature_matrix else 1)
    scale = n_dim ** 0.5
    dist: list[list[float]] = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            d = _euclid_sq(feature_matrix[i], feature_matrix[j]) ** 0.5 / scale
            dist[i][j] = d
            dist[j][i] = d
    return dist


def find_song_path_clap(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    *,
    k: int = 10,
) -> list[dict[str, Any]]:
    """Dijkstra path over a k-NN graph built from CLAP audio embeddings.

    Cosine distance between L2-normalised embeddings is the edge weight.
    Returns ``[]`` if CLAP embeddings haven't been computed; raises
    ``KeyError`` if either endpoint is missing its embedding.
    """
    keys, matrix, key_to_idx, metadata = _load_clap_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    dist_matrix = _cosine_distance_matrix(matrix)
    adj = _build_knn_graph_distances(dist_matrix, k=min(k, max(1, len(matrix) - 1)))

    path = _dijkstra(adj, src_idx, dst_idx)
    if not path:
        return []

    target_len = max_steps + 1
    if len(path) > target_len:
        idxs = [
            round(i * (len(path) - 1) / (target_len - 1)) for i in range(target_len)
        ]
        seen: set[int] = set()
        path = [path[i] for i in idxs if not (path[i] in seen or seen.add(path[i]))]
    return [metadata[i] for i in path]


def find_song_path_hybrid(
    conn: sqlite3.Connection,
    from_track_id: str,
    to_track_id: str,
    max_steps: int = 10,
    *,
    k: int = 10,
    clap_weight: float = CLAP_WEIGHT,
    feature_weight: float = FEATURE_WEIGHT,
) -> list[dict[str, Any]]:
    """Dijkstra over a k-NN graph weighted by ``clap_weight·clap_cos + feature_weight·feature_dist``.

    Only tracks with BOTH a CLAP embedding and a complete audio-feature row are
    considered. The combined distance balances richer sonic similarity (CLAP)
    with structural smoothness (BPM, key, energy).
    """
    keys, clap_matrix, feature_matrix, key_to_idx, metadata = _load_hybrid_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    clap_dist = _cosine_distance_matrix(clap_matrix)
    feat_dist = _feature_distance_matrix(feature_matrix)
    n = len(keys)
    combined: list[list[float]] = [
        [clap_weight * clap_dist[i][j] + feature_weight * feat_dist[i][j] for j in range(n)]
        for i in range(n)
    ]
    adj = _build_knn_graph_distances(combined, k=min(k, max(1, n - 1)))

    path = _dijkstra(adj, src_idx, dst_idx)
    if not path:
        return []

    target_len = max_steps + 1
    if len(path) > target_len:
        idxs = [
            round(i * (len(path) - 1) / (target_len - 1)) for i in range(target_len)
        ]
        seen: set[int] = set()
        path = [path[i] for i in idxs if not (path[i] in seen or seen.add(path[i]))]
    return [metadata[i] for i in path]
