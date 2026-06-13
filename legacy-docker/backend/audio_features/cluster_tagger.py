"""Cluster auto-tagging (v13.3): derive human-readable labels for sonic clusters.

For each cluster produced by ``audio_features.clustering``:
  1. Pull every track that belongs to the cluster.
  2. Collect Last.fm community tags (from ``track_metadata_ext.lastfm_tags``
     — JSON array per track).
  3. Fall back to the Roon ``track_genres`` junction when no Last.fm tags exist.
  4. Pick the top-3 most common tags as primary/secondary/tertiary labels.
  5. Persist into ``cluster_labels``.

The result lets the Music Map render labels like
``"melancholic · atmospheric · late night"`` over each cluster centroid
instead of the opaque ``"Cluster 4"``.
"""

from __future__ import annotations

import json
import logging
import sqlite3
from collections import Counter
from datetime import UTC, datetime
from typing import Any

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Tag collection
# ---------------------------------------------------------------------------


def _parse_tag_field(raw: str | None) -> list[str]:
    """Last.fm tags are stored as a JSON array; tolerate stringified scalars."""
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        return [t.strip() for t in str(raw).split(",") if t.strip()]
    if isinstance(parsed, list):
        return [str(t).strip().lower() for t in parsed if str(t).strip()]
    if isinstance(parsed, str):
        return [parsed.strip().lower()]
    return []


def _collect_lastfm_tags(conn: sqlite3.Connection, cluster_id: int) -> Counter[str]:
    """Tag → count over every cluster member with Last.fm tags."""
    rows = conn.execute(
        """
        SELECT tme.lastfm_tags
        FROM track_audio_features af
        JOIN track_metadata_ext tme ON tme.item_key = af.item_key
        WHERE af.cluster_id = ?
          AND tme.lastfm_tags IS NOT NULL
        """,
        (cluster_id,),
    ).fetchall()
    bag: Counter[str] = Counter()
    for r in rows:
        for tag in _parse_tag_field(r["lastfm_tags"]):
            bag[tag] += 1
    return bag


def _collect_roon_genres(conn: sqlite3.Connection, cluster_id: int) -> Counter[str]:
    """Tag → count via the Roon track_genres junction (fallback path)."""
    rows = conn.execute(
        """
        SELECT tg.genre
        FROM track_genres tg
        JOIN track_audio_features af ON af.item_key = tg.track_key
        WHERE af.cluster_id = ?
          AND tg.genre IS NOT NULL AND tg.genre != ''
        """,
        (cluster_id,),
    ).fetchall()
    bag: Counter[str] = Counter()
    for r in rows:
        bag[str(r["genre"]).strip().lower()] += 1
    return bag


def _list_clusters(conn: sqlite3.Connection) -> list[tuple[int, int]]:
    """Return (cluster_id, track_count) for every non-noise cluster."""
    rows = conn.execute(
        """
        SELECT cluster_id, COUNT(*) AS n
        FROM track_audio_features
        WHERE cluster_id IS NOT NULL AND cluster_id != -1
        GROUP BY cluster_id
        ORDER BY n DESC
        """,
    ).fetchall()
    return [(int(r["cluster_id"]), int(r["n"])) for r in rows]


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------


def _upsert_label(
    conn: sqlite3.Connection,
    cluster_id: int,
    labels: list[str],
    track_count: int,
    source: str,
) -> None:
    p = labels[0] if len(labels) > 0 else None
    s = labels[1] if len(labels) > 1 else None
    t = labels[2] if len(labels) > 2 else None
    now = datetime.now(UTC).isoformat()
    conn.execute(
        """
        INSERT INTO cluster_labels
            (cluster_id, label_primary, label_secondary, label_tertiary,
             track_count, source, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cluster_id) DO UPDATE SET
            label_primary = excluded.label_primary,
            label_secondary = excluded.label_secondary,
            label_tertiary = excluded.label_tertiary,
            track_count = excluded.track_count,
            source = excluded.source,
            updated_at = excluded.updated_at
        """,
        (cluster_id, p, s, t, track_count, source, now),
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def auto_tag_clusters(db_path: str | None = None) -> dict[str, Any]:
    """Compute & persist labels for every cluster in the current run.

    The work is light SQL — no ML imports — so we run it inline on the event
    loop. ``db_path`` is optional; when omitted we open the project DB via
    ``get_db_connection``.
    """
    if db_path is None:
        from backend.db import get_db_connection  # noqa: PLC0415
        conn = get_db_connection()
    else:
        conn = sqlite3.connect(db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row

    summary: dict[int, dict[str, Any]] = {}
    try:
        clusters = _list_clusters(conn)
        if not clusters:
            return {"n_clusters": 0, "clusters": {}}

        for cluster_id, n_tracks in clusters:
            lf = _collect_lastfm_tags(conn, cluster_id)
            if lf:
                top = [t for t, _ in lf.most_common(3)]
                source = "lastfm"
            else:
                rg = _collect_roon_genres(conn, cluster_id)
                top = [t for t, _ in rg.most_common(3)]
                source = "roon_genres" if top else "none"

            _upsert_label(conn, cluster_id, top, n_tracks, source)
            summary[cluster_id] = {
                "labels": top,
                "track_count": n_tracks,
                "source": source,
            }

        conn.commit()
        logger.info(
            "Cluster auto-tag: labelled %d cluster(s)", len(summary)
        )
        return {"n_clusters": len(summary), "clusters": summary}
    finally:
        if db_path is not None:
            conn.close()


async def get_cluster_label(
    cluster_id: int, db_path: str | None = None
) -> dict[str, Any]:
    """Return the persisted labels for a specific cluster, or ``{}`` if none."""
    if db_path is None:
        from backend.db import get_db_connection  # noqa: PLC0415
        conn = get_db_connection()
    else:
        conn = sqlite3.connect(db_path, timeout=30.0)
        conn.row_factory = sqlite3.Row

    try:
        row = conn.execute(
            "SELECT * FROM cluster_labels WHERE cluster_id = ?",
            (cluster_id,),
        ).fetchone()
        if not row:
            return {}
        d = dict(row)
        d["labels"] = [
            v for v in (
                d.get("label_primary"),
                d.get("label_secondary"),
                d.get("label_tertiary"),
            )
            if v
        ]
        return d
    finally:
        if db_path is not None:
            conn.close()


def get_all_labels(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    """Sync helper used by routes/MCP: every cluster_label row as a dict."""
    rows = conn.execute(
        "SELECT * FROM cluster_labels ORDER BY track_count DESC"
    ).fetchall()
    out: list[dict[str, Any]] = []
    for row in rows:
        d = dict(row)
        d["labels"] = [
            v for v in (
                d.get("label_primary"),
                d.get("label_secondary"),
                d.get("label_tertiary"),
            )
            if v
        ]
        out.append(d)
    return out
