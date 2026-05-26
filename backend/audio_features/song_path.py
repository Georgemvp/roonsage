"""Song-path finding (v13.0): smoothest bridge between two tracks.

Two strategies:

* ``find_song_path`` — greedy nearest-neighbor walk in the normalized
  feature space, biased toward the target. Cheap, no graph construction.
* ``find_song_path_graph`` — Dijkstra over a k-NN graph; tends to find a
  smoother route but pays O(n·k) up front.

Both return an ordered list of dicts compatible with the REST response
model (item_key, title, artist, album, plus audio-feature metadata).
"""

from __future__ import annotations

import heapq
import logging
from typing import TYPE_CHECKING, Any

from backend.audio_features.clustering import FEATURE_COLUMNS

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)


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
) -> list[dict[str, Any]]:
    """Greedy nearest-neighbor walk biased toward the target track.

    At each step the algorithm picks the unvisited candidate that minimizes
    distance to ``current_position + alpha * (target - current_position)``;
    ``alpha`` grows from 0.3 → 1.0 as we approach the target so the early
    steps explore freely, while the last few snap toward the destination.
    """
    keys, matrix, key_to_idx, metadata = _load_feature_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    n_dim = len(FEATURE_COLUMNS)
    target = matrix[dst_idx]
    visited: set[int] = {src_idx}
    path: list[int] = [src_idx]
    current = matrix[src_idx]

    for step in range(max_steps):
        # alpha goes from 0.3 to ~0.95 over the available steps.
        alpha = 0.3 + 0.65 * (step / max(1, max_steps - 1))
        bias = [current[d] + alpha * (target[d] - current[d]) for d in range(n_dim)]

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

    # If we never reached the destination, append it explicitly so callers
    # always get a path that ends at the requested target.
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
) -> list[dict[str, Any]]:
    """Build a k-NN graph and walk Dijkstra's shortest path.

    If the shortest path has more than ``max_steps + 1`` nodes the result is
    simplified by taking ``max_steps`` evenly-spaced waypoints (including
    the source and destination).
    """
    keys, matrix, key_to_idx, metadata = _load_feature_table(conn)
    if not keys:
        return []
    src_idx, dst_idx = _validate_endpoints(key_to_idx, from_track_id, to_track_id)

    adj = _build_knn_graph(matrix, k=min(k, max(1, len(matrix) - 1)))
    path = _dijkstra(adj, src_idx, dst_idx)
    if not path:
        # Graph disconnected — fall back to greedy.
        return find_song_path(conn, from_track_id, to_track_id, max_steps)

    target_len = max_steps + 1
    if len(path) > target_len:
        idxs = [
            round(i * (len(path) - 1) / (target_len - 1)) for i in range(target_len)
        ]
        # Dedupe while preserving order in case the rounding produced repeats.
        seen: set[int] = set()
        path = [path[i] for i in idxs if not (path[i] in seen or seen.add(path[i]))]
    return [metadata[i] for i in path]
