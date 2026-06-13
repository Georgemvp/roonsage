"""Smart shuffle + smart radio (v13.3).

Smart shuffle interleaves tracks from different sonic clusters so the queue
never lingers on a single sonic territory. Within each cluster slice the
tracks are ordered by *descending* distance from the cluster centroid — the
"edge" tracks lead, which keeps a cluster-run from sounding samey.

Smart radio extrapolates the same idea: given a zone's currently-playing
track we keep alternating ~2-3 tracks from its cluster, then 1 track from a
neighbouring cluster (nearest centroid), repeating until the requested
duration is filled. It only uses the local feature cache — no Roon calls.
"""

from __future__ import annotations

import logging
import math
import sqlite3
from typing import Any

from backend.audio_features.clustering import FEATURE_COLUMNS

logger = logging.getLogger(__name__)

# Mean RoonSage library track duration when ``duration_ms`` is missing.
_DEFAULT_TRACK_DURATION_S = 240
# How many tracks per cluster before we switch to a neighbour cluster.
_CLUSTER_RUN_LEN = 3
# How many neighbour tracks we drop in between cluster runs.
_NEIGHBOUR_RUN_LEN = 1


# ---------------------------------------------------------------------------
# Shared SQL helpers
# ---------------------------------------------------------------------------


def _fetch_features_for_keys(
    conn: sqlite3.Connection, item_keys: list[str]
) -> dict[str, dict[str, Any]]:
    """Return ``{item_key: {cluster_id, x_2d, y_2d, features...}}``."""
    if not item_keys:
        return {}
    placeholders = ",".join("?" * len(item_keys))
    cols = ", ".join(FEATURE_COLUMNS)
    rows = conn.execute(
        f"""
        SELECT item_key, cluster_id, x_2d, y_2d, {cols}
        FROM track_audio_features
        WHERE item_key IN ({placeholders})
        """,
        item_keys,
    ).fetchall()
    return {r["item_key"]: dict(r) for r in rows}


def _cluster_centroids(conn: sqlite3.Connection) -> dict[int, tuple[float, float]]:
    """``{cluster_id: (centroid_x, centroid_y)}`` for every clustered track set."""
    rows = conn.execute(
        """
        SELECT cluster_id,
               AVG(x_2d) AS cx, AVG(y_2d) AS cy,
               COUNT(*) AS n
        FROM track_audio_features
        WHERE cluster_id IS NOT NULL
          AND x_2d IS NOT NULL AND y_2d IS NOT NULL
        GROUP BY cluster_id
        """
    ).fetchall()
    return {
        int(r["cluster_id"]): (float(r["cx"]), float(r["cy"]))
        for r in rows
        if r["cx"] is not None and r["cy"] is not None
    }


def _distance_to(point: tuple[float, float], centroid: tuple[float, float]) -> float:
    return math.hypot(point[0] - centroid[0], point[1] - centroid[1])


def _nearest_neighbour_clusters(
    centroids: dict[int, tuple[float, float]],
    cluster_id: int,
) -> list[int]:
    """Other clusters sorted by 2D distance to ``cluster_id``'s centroid."""
    if cluster_id not in centroids:
        return [c for c in centroids if c != cluster_id]
    base = centroids[cluster_id]
    ranked = sorted(
        (c for c in centroids if c != cluster_id and c != -1),
        key=lambda c: _distance_to(centroids[c], base),
    )
    return ranked


# ---------------------------------------------------------------------------
# Smart shuffle
# ---------------------------------------------------------------------------


async def smart_shuffle(
    item_keys: list[str], db_path: str | None = None
) -> list[str]:
    """Async wrapper — runs the sync shuffle off the event loop."""
    import asyncio  # noqa: PLC0415
    return await asyncio.to_thread(smart_shuffle_sync, item_keys, db_path)


def smart_shuffle_sync(
    item_keys: list[str], db_path: str | None = None
) -> list[str]:
    """Reorder ``item_keys`` so consecutive tracks come from different clusters.

    Tracks without cluster data fall into a single "unknown" bucket so they
    still get interleaved — never silently dropped.

    Within each cluster bucket the tracks are ordered by *descending* distance
    from their cluster centroid (most-distinct first), then we round-robin
    across all buckets to produce the output.
    """
    if not item_keys:
        return []

    if db_path is None:
        from backend.db import get_db_connection  # noqa: PLC0415
        conn = get_db_connection()
        owns = True
    else:
        conn = sqlite3.connect(db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row
        owns = True

    try:
        feats = _fetch_features_for_keys(conn, item_keys)
        centroids = _cluster_centroids(conn)

        buckets: dict[int | str, list[tuple[float, str]]] = {}
        for key in item_keys:
            row = feats.get(key)
            if row is None or row.get("cluster_id") is None:
                buckets.setdefault("__unknown__", []).append((0.0, key))
                continue
            cid = int(row["cluster_id"])
            # Use the 2D coords (UMAP) when available — they're the same space
            # the centroids live in. Fall back to 0 so the key still slots in.
            if row.get("x_2d") is not None and row.get("y_2d") is not None:
                centroid = centroids.get(cid, (0.0, 0.0))
                dist = _distance_to(
                    (float(row["x_2d"]), float(row["y_2d"])), centroid
                )
            else:
                dist = 0.0
            buckets.setdefault(cid, []).append((dist, key))

        # Edge tracks first within a bucket.
        for cid in buckets:
            buckets[cid].sort(key=lambda pair: -pair[0])

        # Largest buckets cycle first so the queue head feels balanced.
        bucket_order = sorted(buckets.keys(), key=lambda c: -len(buckets[c]))
        per_bucket_idx = {c: 0 for c in bucket_order}

        out: list[str] = []
        total = sum(len(v) for v in buckets.values())
        last_cid: int | str | None = None
        while len(out) < total:
            advanced_this_pass = False
            for cid in bucket_order:
                idx = per_bucket_idx[cid]
                if idx >= len(buckets[cid]):
                    continue
                # If this bucket would extend a same-cluster run, try the
                # other buckets first; come back to it only if nothing else
                # has tracks left.
                if cid == last_cid:
                    has_alt = any(
                        c != cid and per_bucket_idx[c] < len(buckets[c])
                        for c in bucket_order
                    )
                    if has_alt:
                        continue
                _, key = buckets[cid][idx]
                out.append(key)
                per_bucket_idx[cid] = idx + 1
                last_cid = cid
                advanced_this_pass = True
            if not advanced_this_pass:
                break
        return out
    finally:
        if owns:
            conn.close()


# ---------------------------------------------------------------------------
# Smart radio
# ---------------------------------------------------------------------------


def _current_zone_track_item_key(conn: sqlite3.Connection, zone_id: str) -> str | None:
    """Use the live Roon zones map to identify the currently-playing track.

    We can't read item_keys straight off ``now_playing`` (Roon doesn't expose
    them there), so we match by title+artist against the SQLite cache. This
    matches the same approach used by ``sonic_fingerprint``.
    """
    try:
        from backend.roon_client import get_roon_client  # noqa: PLC0415
    except Exception:
        return None

    client = get_roon_client()
    if client is None or not client.is_connected():
        return None
    try:
        zones = getattr(client._api, "zones", None) or {}  # type: ignore[attr-defined]
    except Exception:
        return None
    zone = zones.get(zone_id)
    if not zone:
        return None
    np_ = zone.get("now_playing") or {}
    three = np_.get("three_line") or {}
    title = three.get("line1") or np_.get("one_line", {}).get("line1")
    artist = three.get("line2") or ""
    if not title:
        return None
    row = conn.execute(
        """
        SELECT t.item_key
        FROM tracks t
        JOIN track_audio_features af ON af.item_key = t.item_key
        WHERE LOWER(t.title) = LOWER(?)
          AND LOWER(t.artist) LIKE ?
          AND af.cluster_id IS NOT NULL
        LIMIT 1
        """,
        (title, f"%{(artist or '').lower()}%"),
    ).fetchone()
    return row["item_key"] if row else None


def _cluster_pool(
    conn: sqlite3.Connection, cluster_id: int, exclude: set[str]
) -> list[tuple[str, float, int]]:
    """Return ``[(item_key, duration_s, dist_from_centroid)]`` for one cluster."""
    rows = conn.execute(
        """
        SELECT t.item_key, COALESCE(t.duration_ms, 0) AS dms,
               af.x_2d, af.y_2d
        FROM track_audio_features af
        JOIN tracks t ON t.item_key = af.item_key
        WHERE af.cluster_id = ?
          AND (t.is_live IS NULL OR t.is_live = 0)
        """,
        (cluster_id,),
    ).fetchall()
    if not rows:
        return []
    # Cluster centroid in the SAME 2D space as the rows themselves.
    cx = sum(r["x_2d"] or 0.0 for r in rows) / len(rows)
    cy = sum(r["y_2d"] or 0.0 for r in rows) / len(rows)
    out: list[tuple[str, float, int]] = []
    for r in rows:
        if r["item_key"] in exclude:
            continue
        dur = int(r["dms"] or 0) // 1000 or _DEFAULT_TRACK_DURATION_S
        dist = _distance_to(
            (float(r["x_2d"] or 0.0), float(r["y_2d"] or 0.0)), (cx, cy)
        )
        out.append((r["item_key"], dist, dur))
    # Order edge-first for variety.
    out.sort(key=lambda x: -x[1])
    return [(k, float(d), int(dur)) for (k, d, dur) in out]


async def smart_radio(
    zone_id: str,
    duration_minutes: int,
    db_path: str | None = None,
    *,
    seed_item_key: str | None = None,
) -> list[dict[str, Any]]:
    """Build a cluster-hopping radio queue from the zone's current track.

    The algorithm: ``_CLUSTER_RUN_LEN`` tracks from the current cluster, then
    ``_NEIGHBOUR_RUN_LEN`` track from a neighbour cluster (cycling through
    neighbours by distance to the original centroid), repeating until the
    queue length covers ``duration_minutes``.

    Returns a list of dicts ``{item_key, title, artist, album, cluster_id}``.
    """
    if duration_minutes <= 0:
        return []

    if db_path is None:
        from backend.db import get_db_connection  # noqa: PLC0415
        conn = get_db_connection()
        owns = True
    else:
        conn = sqlite3.connect(db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row
        owns = True

    try:
        # ── Seed: explicit override → live zone → fallback first clustered track
        seed_key = seed_item_key or _current_zone_track_item_key(conn, zone_id)
        if seed_key is None:
            row = conn.execute(
                """
                SELECT item_key
                FROM track_audio_features
                WHERE cluster_id IS NOT NULL AND cluster_id != -1
                ORDER BY RANDOM() LIMIT 1
                """
            ).fetchone()
            if row is None:
                logger.warning("smart_radio: no clustered tracks available")
                return []
            seed_key = row["item_key"]

        seed_row = conn.execute(
            "SELECT cluster_id FROM track_audio_features WHERE item_key = ?",
            (seed_key,),
        ).fetchone()
        if seed_row is None or seed_row["cluster_id"] is None or seed_row["cluster_id"] == -1:
            logger.info("smart_radio: seed track %s has no cluster — falling back", seed_key)
            return []
        primary_cid = int(seed_row["cluster_id"])

        centroids = _cluster_centroids(conn)
        neighbours = _nearest_neighbour_clusters(centroids, primary_cid)

        target_seconds = duration_minutes * 60
        chosen_keys: set[str] = set()

        primary_pool = _cluster_pool(conn, primary_cid, chosen_keys)
        neighbour_pools: dict[int, list[tuple[str, float, int]]] = {
            cid: _cluster_pool(conn, cid, chosen_keys) for cid in neighbours
        }

        queue: list[str] = []
        total_secs = 0
        primary_idx = 0
        neighbour_cycle_idx = 0
        neighbour_pool_idx: dict[int, int] = dict.fromkeys(neighbours, 0)

        while total_secs < target_seconds:
            # Primary run
            primary_taken = 0
            while primary_taken < _CLUSTER_RUN_LEN and primary_idx < len(primary_pool):
                key, _, dur = primary_pool[primary_idx]
                primary_idx += 1
                if key in chosen_keys:
                    continue
                chosen_keys.add(key)
                queue.append(key)
                total_secs += dur
                primary_taken += 1
                if total_secs >= target_seconds:
                    break

            if total_secs >= target_seconds:
                break

            # Neighbour cluster run
            neighbour_taken = 0
            attempts = 0
            while neighbour_taken < _NEIGHBOUR_RUN_LEN and attempts < len(neighbours) + 1:
                if not neighbours:
                    break
                cid = neighbours[neighbour_cycle_idx % len(neighbours)]
                pool = neighbour_pools.get(cid, [])
                idx = neighbour_pool_idx.get(cid, 0)
                neighbour_cycle_idx += 1
                attempts += 1
                if idx >= len(pool):
                    continue
                # Find next not-yet-chosen
                while idx < len(pool) and pool[idx][0] in chosen_keys:
                    idx += 1
                neighbour_pool_idx[cid] = idx
                if idx >= len(pool):
                    continue
                key, _, dur = pool[idx]
                neighbour_pool_idx[cid] = idx + 1
                chosen_keys.add(key)
                queue.append(key)
                total_secs += dur
                neighbour_taken += 1
                if total_secs >= target_seconds:
                    break

            # Safety valve: nothing was added in either pass → stop.
            if not primary_taken and not neighbour_taken:
                break

        # Decorate the result with light metadata.
        if not queue:
            return []
        placeholders = ",".join("?" * len(queue))
        meta_rows = conn.execute(
            f"""
            SELECT t.item_key, t.title, t.artist, t.album,
                   af.cluster_id
            FROM tracks t
            LEFT JOIN track_audio_features af ON af.item_key = t.item_key
            WHERE t.item_key IN ({placeholders})
            """,
            queue,
        ).fetchall()
        meta = {r["item_key"]: dict(r) for r in meta_rows}
        return [
            {
                "item_key": k,
                "title": meta.get(k, {}).get("title"),
                "artist": meta.get(k, {}).get("artist"),
                "album": meta.get(k, {}).get("album"),
                "cluster_id": meta.get(k, {}).get("cluster_id"),
            }
            for k in queue
        ]
    finally:
        if owns:
            conn.close()
