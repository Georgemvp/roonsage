"""Mood tagging via K-Means over CLAP embeddings + CLAP-text mood centroids.

Combines two existing subsystems:

1. :mod:`backend.audio_features.clap_search` provides the CLAP audio embeddings
   already persisted in ``clap_embeddings``. CLAP's text encoder is reused to
   embed natural-language mood prompts ("calm peaceful ambient music"), so the
   audio + text vectors live in the same cosine space.
2. K-Means partitions the audio embeddings into ``MOOD_CLUSTER_COUNT`` clusters
   (default 12, matching the mood vocabulary). For every cluster we compute the
   cosine similarity of its centroid against every mood text embedding and
   assign the top-2 closest moods to the cluster — that mapping is then applied
   to every track in the cluster.

The output is persisted in ``track_mood_tags`` (one row per analyzed track) and
the run metadata in the single-row ``mood_runs`` table — same shape as
``clap_runs`` / ``cluster_runs``.

Heavy compute (K-Means + text encode) is CPU-bound; routes call
``run_mood_tagging`` via ``asyncio.to_thread``.
"""

from __future__ import annotations

import logging
import sqlite3
from collections import Counter
from datetime import UTC, datetime
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Mood vocabulary
# ---------------------------------------------------------------------------

# Default mood labels. Order is significant only when these are written into a
# stable, persisted form — we don't, so reorderings are safe.
DEFAULT_MOODS: tuple[str, ...] = (
    "calm",
    "energetic",
    "happy",
    "melancholic",
    "aggressive",
    "dreamy",
    "groovy",
    "dark",
    "romantic",
    "epic",
    "playful",
    "mysterious",
)

# Each label is expanded into a longer text prompt so the CLAP text encoder has
# more signal than a single adjective. Cosine similarity on richer prompts is
# noticeably more stable across runs.
MOOD_PROMPTS: dict[str, str] = {
    "calm": "calm peaceful relaxing ambient soothing music",
    "energetic": "energetic upbeat high energy fast driving music",
    "happy": "happy cheerful uplifting joyful bright music",
    "melancholic": "melancholic sad nostalgic bittersweet introspective music",
    "aggressive": "aggressive intense heavy angry powerful music",
    "dreamy": "dreamy ethereal atmospheric floating hazy music",
    "groovy": "groovy funky rhythmic danceable swinging music",
    "dark": "dark moody brooding ominous shadowy music",
    "romantic": "romantic tender loving warm intimate music",
    "epic": "epic cinematic grand sweeping triumphant music",
    "playful": "playful quirky whimsical fun light-hearted music",
    "mysterious": "mysterious enigmatic suspenseful curious music",
}

MIN_TRACKS_FOR_MOOD_TAGGING = 24


# ---------------------------------------------------------------------------
# Run state helpers
# ---------------------------------------------------------------------------


def _set_run_state(
    conn: sqlite3.Connection,
    status: str,
    *,
    started_at: str | None = None,
    finished_at: str | None = None,
    n_tracks: int | None = None,
    n_clusters: int | None = None,
    error_message: str | None = None,
) -> None:
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
    sets.append("error_message = ?")
    args.append(error_message)
    conn.execute(f"UPDATE mood_runs SET {', '.join(sets)} WHERE id = 1", args)
    conn.commit()


def get_status(conn: sqlite3.Connection) -> dict[str, Any]:
    row = conn.execute("SELECT * FROM mood_runs WHERE id = 1").fetchone()
    return dict(row) if row else {"status": "idle"}


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


def _embed_mood_prompts(moods: list[str]):
    """Run the mood label prompts through CLAP's text encoder."""
    import numpy as np  # noqa: PLC0415

    from backend.audio_features import clap_search  # noqa: PLC0415

    vecs = [
        np.asarray(clap_search._embed_text(MOOD_PROMPTS.get(m, m)), dtype=np.float32)
        for m in moods
    ]
    return np.stack(vecs)


def _l2_normalize(matrix):
    import numpy as np  # noqa: PLC0415

    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    return matrix / (norms + 1e-12)


def run_mood_tagging(
    db_path: str | None = None,
    *,
    conn: sqlite3.Connection | None = None,
    k: int | None = None,
    moods: list[str] | None = None,
) -> dict[str, Any]:
    """Compute mood tags for every track that has a CLAP embedding.

    Args:
        db_path: Optional path to the SQLite DB; ignored when ``conn`` is given.
        conn:    Open connection (preferred — caller controls lifecycle).
        k:       Number of K-Means clusters. Defaults to ``MOOD_CLUSTER_COUNT``
                 env var or the length of the mood vocabulary.
        moods:   Optional override of the mood vocabulary (e.g. for tests).

    Returns:
        Summary dict (also persisted onto ``mood_runs``).
    """
    if conn is None:
        if db_path is None:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
        else:
            conn = sqlite3.connect(db_path, timeout=30.0)
            conn.row_factory = sqlite3.Row
        owns_conn = True
    else:
        owns_conn = False

    from backend.audio_features import clap_search  # noqa: PLC0415
    from backend.config import get_mood_cluster_count  # noqa: PLC0415

    mood_labels = list(moods) if moods else list(DEFAULT_MOODS)
    if k is None:
        k = get_mood_cluster_count() or len(mood_labels)
    k = max(2, k)

    started_at = datetime.now(UTC).isoformat()

    try:
        _set_run_state(
            conn,
            "running",
            started_at=started_at,
            finished_at=None,
            n_tracks=0,
            n_clusters=0,
            error_message=None,
        )

        keys, matrix = clap_search.load_all_embeddings(conn)
        n_tracks = len(keys)
        if n_tracks < MIN_TRACKS_FOR_MOOD_TAGGING:
            msg = (
                f"Need at least {MIN_TRACKS_FOR_MOOD_TAGGING} CLAP embeddings; "
                f"have {n_tracks}. Run /api/clap/analyze first."
            )
            _set_run_state(
                conn,
                "failed",
                finished_at=datetime.now(UTC).isoformat(),
                n_tracks=n_tracks,
                error_message=msg,
            )
            return {"status": "failed", "n_tracks": n_tracks, "error": msg}

        import numpy as np  # noqa: PLC0415
        from sklearn.cluster import KMeans  # noqa: PLC0415

        # K-Means works on raw embeddings (Euclidean). Cap k at n_tracks so
        # small libraries don't blow up the algorithm.
        effective_k = min(k, max(2, n_tracks))

        X = matrix.astype(np.float32, copy=False)
        kmeans = KMeans(n_clusters=effective_k, n_init=10, random_state=42)
        labels = kmeans.fit_predict(X)
        centroids = kmeans.cluster_centers_  # (effective_k, EMBED_DIM)

        # Mood-text embeddings are computed once per run.
        mood_matrix = _embed_mood_prompts(mood_labels)
        mood_norm = _l2_normalize(mood_matrix)
        centroid_norm = _l2_normalize(centroids)

        # cosine(centroid_i, mood_j) for every (cluster, mood) pair.
        cluster_to_mood_sims = centroid_norm @ mood_norm.T  # (k, n_moods)

        cluster_moods: dict[int, dict[str, Any]] = {}
        for cid in range(effective_k):
            sims = cluster_to_mood_sims[cid]
            order = np.argsort(-sims)
            primary_idx = int(order[0])
            secondary_idx = int(order[1]) if len(order) > 1 else primary_idx
            cluster_moods[cid] = {
                "mood_primary": mood_labels[primary_idx],
                "mood_secondary": mood_labels[secondary_idx],
                "primary_idx": primary_idx,
                "centroid_sim": float(sims[primary_idx]),
            }

        # Per-track confidence: cosine(track_embedding, primary_mood_embedding).
        track_norm = _l2_normalize(X)
        track_to_mood_sims = track_norm @ mood_norm.T  # (n_tracks, n_moods)

        # Persist (one row per track) — wipe previous results first so deleted
        # CLAP embeddings don't leave stale mood tags around.
        conn.execute("DELETE FROM track_mood_tags")
        now = datetime.now(UTC).isoformat()
        rows = []
        for i, key in enumerate(keys):
            cid = int(labels[i])
            cm = cluster_moods[cid]
            confidence = float(track_to_mood_sims[i, cm["primary_idx"]])
            rows.append(
                (
                    key,
                    cm["mood_primary"],
                    cm["mood_secondary"],
                    confidence,
                    cid,
                    now,
                )
            )
        conn.executemany(
            """INSERT INTO track_mood_tags
               (track_id, mood_primary, mood_secondary, confidence, cluster_id, updated_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            rows,
        )
        conn.commit()

        n_unique = len({cm["mood_primary"] for cm in cluster_moods.values()})
        finished_at = datetime.now(UTC).isoformat()
        _set_run_state(
            conn,
            "complete",
            finished_at=finished_at,
            n_tracks=n_tracks,
            n_clusters=effective_k,
        )

        # Aggregate counts for the response payload.
        mood_counts = Counter(r[1] for r in rows)
        logger.info(
            "Mood tagging complete: %d tracks → %d clusters → %d distinct primary moods",
            n_tracks,
            effective_k,
            n_unique,
        )
        return {
            "status": "complete",
            "n_tracks": n_tracks,
            "n_clusters": effective_k,
            "n_unique_moods": n_unique,
            "mood_counts": dict(mood_counts),
            "started_at": started_at,
            "finished_at": finished_at,
        }
    except Exception as exc:
        logger.exception("Mood tagging failed")
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


async def generate_mood_tags(
    db_path: str | None = None,
    *,
    k: int | None = None,
) -> dict[str, Any]:
    """Async wrapper around :func:`run_mood_tagging` for the route layer."""
    import asyncio  # noqa: PLC0415

    return await asyncio.to_thread(run_mood_tagging, db_path, k=k)


# ---------------------------------------------------------------------------
# Read helpers
# ---------------------------------------------------------------------------


def get_mood_tag_counts(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    """Return ``[{"mood": "calm", "track_count": 132}, ...]`` for the UI/MCP."""
    rows = conn.execute(
        """SELECT mood_primary AS mood, COUNT(*) AS track_count
           FROM track_mood_tags
           GROUP BY mood_primary
           ORDER BY track_count DESC"""
    ).fetchall()
    return [dict(r) for r in rows]


def get_tracks_for_mood(
    conn: sqlite3.Connection,
    mood: str,
    *,
    limit: int = 200,
    include_secondary: bool = True,
) -> list[dict[str, Any]]:
    """Tracks tagged with ``mood`` (primary, plus secondary when requested)."""
    where = "mood_primary = ?"
    args: list[Any] = [mood]
    if include_secondary:
        where = "(mood_primary = ? OR mood_secondary = ?)"
        args = [mood, mood]

    rows = conn.execute(
        f"""SELECT t.item_key, t.title, t.artist, t.album, t.year, t.genres,
                   mt.mood_primary, mt.mood_secondary, mt.confidence
            FROM track_mood_tags mt
            JOIN tracks t ON t.item_key = mt.track_id
            WHERE {where}
            ORDER BY mt.confidence DESC
            LIMIT ?""",
        [*args, limit],
    ).fetchall()
    return [dict(r) for r in rows]


def get_mood_for_track(
    conn: sqlite3.Connection,
    track_id: str,
) -> dict[str, Any] | None:
    row = conn.execute(
        """SELECT track_id, mood_primary, mood_secondary, confidence,
                  cluster_id, updated_at
           FROM track_mood_tags WHERE track_id = ?""",
        (track_id,),
    ).fetchone()
    return dict(row) if row else None


def get_mood_tags_for_keys(
    conn: sqlite3.Connection,
    item_keys: list[str],
) -> dict[str, list[str]]:
    """Bulk fetch ``item_key → [mood_primary, mood_secondary]`` (deduped)."""
    if not item_keys:
        return {}
    placeholders = ",".join("?" for _ in item_keys)
    rows = conn.execute(
        f"""SELECT track_id, mood_primary, mood_secondary
            FROM track_mood_tags WHERE track_id IN ({placeholders})""",
        item_keys,
    ).fetchall()
    out: dict[str, list[str]] = {}
    for r in rows:
        moods = [r["mood_primary"]]
        if r["mood_secondary"] and r["mood_secondary"] != r["mood_primary"]:
            moods.append(r["mood_secondary"])
        out[r["track_id"]] = moods
    return out
