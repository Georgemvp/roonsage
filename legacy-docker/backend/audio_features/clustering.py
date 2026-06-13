"""Sonic clustering (v13.0): group analyzed tracks by audio-feature similarity.

Pipeline:
  1. Pull every row from ``track_audio_features`` that has the full Spotify-
     style feature set populated.
  2. MinMax-normalize the feature columns to 0..1.
  3. Reduce to 2D via UMAP (n_components=2).
  4. Cluster the 2D embedding with HDBSCAN (label = -1 means noise / outlier).
  5. Persist cluster_id, x_2d, y_2d back onto track_audio_features and update
     the ``cluster_runs`` single-row metadata table.

UMAP + HDBSCAN are CPU-bound — call ``run_clustering`` from
``asyncio.to_thread`` (or a background task) so the event loop stays free.
"""

from __future__ import annotations

import json
import logging
import sqlite3
from collections import Counter
from datetime import UTC, datetime
from typing import Any

logger = logging.getLogger(__name__)

# Columns used to build the feature matrix. Order is fixed because we persist
# the cluster_id alongside the 2D coords — changing this list invalidates
# the comparability of previously-computed clusters.
FEATURE_COLUMNS: tuple[str, ...] = (
    "bpm",
    "energy",
    "danceability",
    "valence",
    "instrumentalness",
    "acousticness",
)

MIN_TRACKS_FOR_CLUSTERING = 30  # HDBSCAN needs > min_cluster_size rows
DEFAULT_PARAMS: dict[str, Any] = {
    "umap_n_neighbors": 15,
    "umap_min_dist": 0.1,
    "umap_metric": "euclidean",
    "hdbscan_min_cluster_size": 10,
    "hdbscan_min_samples": 5,
    "feature_columns": list(FEATURE_COLUMNS),
}


# ---------------------------------------------------------------------------
# Lifecycle helpers
# ---------------------------------------------------------------------------


def _set_run_state(
    conn: sqlite3.Connection,
    status: str,
    *,
    started_at: str | None = None,
    finished_at: str | None = None,
    n_tracks: int | None = None,
    n_clusters: int | None = None,
    n_noise: int | None = None,
    params: dict | None = None,
    error_message: str | None = None,
) -> None:
    """Update the single-row ``cluster_runs`` metadata table."""
    sets: list[str] = ["status = ?"]
    args: list[Any] = [status]

    if started_at is not None:
        sets.append("started_at = ?")
        args.append(started_at)
    if finished_at is not None:
        sets.append("finished_at = ?")
        args.append(finished_at)
    if n_tracks is not None:
        sets.append("n_tracks = ?")
        args.append(n_tracks)
    if n_clusters is not None:
        sets.append("n_clusters = ?")
        args.append(n_clusters)
    if n_noise is not None:
        sets.append("n_noise = ?")
        args.append(n_noise)
    if params is not None:
        sets.append("params_json = ?")
        args.append(json.dumps(params))
    sets.append("error_message = ?")
    args.append(error_message)

    conn.execute(f"UPDATE cluster_runs SET {', '.join(sets)} WHERE id = 1", args)
    conn.commit()


def get_status(conn: sqlite3.Connection) -> dict[str, Any]:
    """Return the latest cluster_runs row as a dict."""
    row = conn.execute("SELECT * FROM cluster_runs WHERE id = 1").fetchone()
    if row is None:
        return {"status": "idle"}
    out = dict(row)
    try:
        out["params"] = json.loads(out.pop("params_json") or "{}")
    except (TypeError, ValueError):
        out["params"] = {}
    return out


# ---------------------------------------------------------------------------
# Core clustering
# ---------------------------------------------------------------------------


def _load_feature_matrix(conn: sqlite3.Connection) -> tuple[list[str], list[list[float]]]:
    """Load item_keys and feature vectors for every fully-analyzed track."""
    cols = ", ".join(FEATURE_COLUMNS)
    where = " AND ".join(f"{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    rows = conn.execute(
        f"SELECT item_key, {cols} FROM track_audio_features WHERE {where}"
    ).fetchall()

    keys: list[str] = []
    matrix: list[list[float]] = []
    for r in rows:
        keys.append(r["item_key"])
        matrix.append([float(r[c]) for c in FEATURE_COLUMNS])
    return keys, matrix


def run_clustering(
    db_path: str | None = None,
    *,
    conn: sqlite3.Connection | None = None,
    params: dict | None = None,
) -> dict[str, Any]:
    """Run UMAP + HDBSCAN over all fully-analyzed tracks and persist results.

    Either ``db_path`` or an open ``conn`` must be supplied. Returns a summary
    dict suitable for the REST status endpoint.
    """
    if conn is None:
        if db_path is None:
            from backend.db import get_db_connection
            conn = get_db_connection()
        else:
            conn = sqlite3.connect(db_path, timeout=30.0)
            conn.row_factory = sqlite3.Row
        owns_conn = True
    else:
        owns_conn = False

    effective_params = {**DEFAULT_PARAMS, **(params or {})}
    started_at = datetime.now(UTC).isoformat()

    try:
        _set_run_state(
            conn,
            "running",
            started_at=started_at,
            finished_at=None,
            n_tracks=0,
            n_clusters=0,
            n_noise=0,
            params=effective_params,
            error_message=None,
        )

        keys, matrix = _load_feature_matrix(conn)
        n_tracks = len(keys)
        if n_tracks < MIN_TRACKS_FOR_CLUSTERING:
            msg = (
                f"Need at least {MIN_TRACKS_FOR_CLUSTERING} fully-analyzed tracks "
                f"to cluster; have {n_tracks}."
            )
            _set_run_state(
                conn,
                "failed",
                finished_at=datetime.now(UTC).isoformat(),
                n_tracks=n_tracks,
                error_message=msg,
            )
            return {"status": "failed", "n_tracks": n_tracks, "error": msg}

        # Heavy imports kept local — these dependencies are optional at install
        # time, and lazy-loading keeps process startup fast.
        import numpy as np  # noqa: PLC0415
        from sklearn.preprocessing import MinMaxScaler  # noqa: PLC0415

        try:
            import umap  # noqa: PLC0415
        except ImportError as exc:  # pragma: no cover - import guard
            raise RuntimeError(
                "umap-learn is required for clustering. "
                "pip install umap-learn"
            ) from exc

        try:
            import hdbscan  # noqa: PLC0415
        except ImportError as exc:  # pragma: no cover - import guard
            raise RuntimeError(
                "hdbscan is required for clustering. pip install hdbscan"
            ) from exc

        X = np.asarray(matrix, dtype=np.float64)
        X_norm = MinMaxScaler().fit_transform(X)

        # n_neighbors must be < n_samples; cap it defensively for small libs.
        n_neighbors = min(effective_params["umap_n_neighbors"], max(2, n_tracks - 1))
        reducer = umap.UMAP(
            n_components=2,
            n_neighbors=n_neighbors,
            min_dist=effective_params["umap_min_dist"],
            metric=effective_params["umap_metric"],
            random_state=42,
        )
        coords = reducer.fit_transform(X_norm)

        clusterer = hdbscan.HDBSCAN(
            min_cluster_size=effective_params["hdbscan_min_cluster_size"],
            min_samples=effective_params["hdbscan_min_samples"],
        )
        labels = clusterer.fit_predict(coords)

        # Persist: bulk update via executemany.
        updates = [
            (
                int(label),
                float(coords[i][0]),
                float(coords[i][1]),
                keys[i],
            )
            for i, label in enumerate(labels)
        ]
        conn.executemany(
            "UPDATE track_audio_features "
            "SET cluster_id = ?, x_2d = ?, y_2d = ? WHERE item_key = ?",
            updates,
        )
        conn.commit()

        # Summary stats. -1 is the HDBSCAN "noise" / unclustered label.
        label_counts = Counter(int(lbl) for lbl in labels)
        n_noise = label_counts.get(-1, 0)
        n_clusters = sum(1 for lbl in label_counts if lbl != -1)

        finished_at = datetime.now(UTC).isoformat()
        _set_run_state(
            conn,
            "complete",
            finished_at=finished_at,
            n_tracks=n_tracks,
            n_clusters=n_clusters,
            n_noise=n_noise,
        )

        logger.info(
            "Clustering complete: %d tracks → %d clusters (+%d noise) in UMAP 2D",
            n_tracks,
            n_clusters,
            n_noise,
        )
        return {
            "status": "complete",
            "n_tracks": n_tracks,
            "n_clusters": n_clusters,
            "n_noise": n_noise,
            "started_at": started_at,
            "finished_at": finished_at,
        }
    except Exception as exc:  # broad — we want any error visible in status row
        logger.exception("Clustering failed")
        _set_run_state(
            conn,
            "failed",
            finished_at=datetime.now(UTC).isoformat(),
            error_message=str(exc),
        )
        raise
    finally:
        if owns_conn:
            conn.close()


# ---------------------------------------------------------------------------
# Read helpers (used by REST + frontend Music Map)
# ---------------------------------------------------------------------------


def get_cluster_data(
    conn: sqlite3.Connection,
    *,
    limit: int | None = None,
    cluster_id: int | None = None,
) -> list[dict[str, Any]]:
    """Return every clustered track with its 2D coords + light metadata."""
    sql = """
        SELECT
            t.item_key, t.title, t.artist, t.album, t.year, t.genres,
            af.cluster_id, af.x_2d, af.y_2d,
            af.bpm, af.energy, af.valence, af.danceability
        FROM track_audio_features af
        JOIN tracks t ON t.item_key = af.item_key
        WHERE af.x_2d IS NOT NULL AND af.y_2d IS NOT NULL
    """
    args: list[Any] = []
    if cluster_id is not None:
        sql += " AND af.cluster_id = ?"
        args.append(cluster_id)
    sql += " ORDER BY af.cluster_id, t.artist, t.title"
    if limit:
        sql += " LIMIT ?"
        args.append(limit)
    rows = conn.execute(sql, args).fetchall()
    return [dict(r) for r in rows]


def get_cluster_summary(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    """Per-cluster aggregate stats: counts, average features, dominant genre."""
    cluster_rows = conn.execute("""
        SELECT
            af.cluster_id,
            COUNT(*) AS track_count,
            AVG(af.bpm) AS avg_bpm,
            AVG(af.energy) AS avg_energy,
            AVG(af.valence) AS avg_valence,
            AVG(af.danceability) AS avg_danceability,
            AVG(af.x_2d) AS centroid_x,
            AVG(af.y_2d) AS centroid_y
        FROM track_audio_features af
        WHERE af.cluster_id IS NOT NULL
        GROUP BY af.cluster_id
        ORDER BY track_count DESC
    """).fetchall()

    summaries: list[dict[str, Any]] = []
    for cr in cluster_rows:
        cid = cr["cluster_id"]
        # Dominant genre via the track_genres junction.
        genre_row = conn.execute(
            """
            SELECT tg.genre, COUNT(*) AS n
            FROM track_genres tg
            JOIN track_audio_features af ON af.item_key = tg.track_key
            WHERE af.cluster_id = ?
            GROUP BY tg.genre
            ORDER BY n DESC
            LIMIT 1
            """,
            (cid,),
        ).fetchone()
        summaries.append(
            {
                "cluster_id": cid,
                "track_count": cr["track_count"],
                "avg_bpm": cr["avg_bpm"],
                "avg_energy": cr["avg_energy"],
                "avg_valence": cr["avg_valence"],
                "avg_danceability": cr["avg_danceability"],
                "centroid_x": cr["centroid_x"],
                "centroid_y": cr["centroid_y"],
                "dominant_genre": genre_row["genre"] if genre_row else None,
                "is_noise": cid == -1,
            }
        )
    return summaries


def get_cluster_tracks(
    conn: sqlite3.Connection,
    cluster_id: int,
    *,
    limit: int = 200,
) -> list[dict[str, Any]]:
    """Tracks belonging to a single cluster (handy for the cluster-detail view)."""
    return get_cluster_data(conn, limit=limit, cluster_id=cluster_id)
