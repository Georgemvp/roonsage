"""Cross-modal similarity: lyrics + CLAP audio embeddings combined.

For "tracks that sound similar AND have similar themes" we average two cosine
similarities — one over the GTE lyrics embedding, one over the CLAP audio
embedding — and rank by the blended score.

Also exposes ``get_thematic_taste`` which compares the user's average lyric
embedding (top-played tracks with lyrics) against every mood centroid from
``mood_lyrics.MOOD_QUERIES`` so the taste profile gains a thematic axis.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from backend.lyrics import mood_lyrics

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

LYRICS_WEIGHT = 0.5
CLAP_WEIGHT = 0.5

# Minimum number of top-played tracks with lyrics required before we trust
# the thematic-taste signal. Below this we return an empty dict.
MIN_THEMATIC_TRACKS = 3


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _load_lyrics_map(conn: sqlite3.Connection) -> dict[str, Any]:
    rows = conn.execute(
        "SELECT item_key, embedding FROM lyrics_embeddings"
    ).fetchall()
    import numpy as np  # noqa: PLC0415

    return {
        r["item_key"]: np.frombuffer(r["embedding"], dtype=np.float32)
        for r in rows
    }


def _load_clap_map(conn: sqlite3.Connection) -> dict[str, Any]:
    rows = conn.execute(
        "SELECT item_key, embedding FROM clap_embeddings"
    ).fetchall()
    import numpy as np  # noqa: PLC0415

    return {
        r["item_key"]: np.frombuffer(r["embedding"], dtype=np.float32)
        for r in rows
    }


def _norm(vec):
    import numpy as np  # noqa: PLC0415

    n = float(np.linalg.norm(vec))
    if n == 0.0:
        return vec
    return vec / n


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def cross_modal_similarity(
    track_id: str,
    conn: sqlite3.Connection,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """Find tracks similar in BOTH lyrics and audio to ``track_id``.

    Requires that the given track has both a CLAP and lyrics embedding stored.
    Returns the top ``limit`` other tracks ranked by
    ``0.5 * lyrics_cosine + 0.5 * clap_cosine``.
    """
    import numpy as np  # noqa: PLC0415

    lyrics_map = _load_lyrics_map(conn)
    clap_map = _load_clap_map(conn)

    lyr_seed = lyrics_map.get(track_id)
    clap_seed = clap_map.get(track_id)
    if lyr_seed is None or clap_seed is None:
        return []

    lyr_seed = _norm(lyr_seed)
    clap_seed = _norm(clap_seed)

    # Restrict to tracks that have BOTH embeddings so the blended score is meaningful.
    common = set(lyrics_map.keys()) & set(clap_map.keys())
    common.discard(track_id)
    if not common:
        return []

    keys = sorted(common)
    lyr_matrix = np.stack([lyrics_map[k] for k in keys]).astype(np.float32)
    clap_matrix = np.stack([clap_map[k] for k in keys]).astype(np.float32)

    lyr_norms = np.linalg.norm(lyr_matrix, axis=1, keepdims=True)
    clap_norms = np.linalg.norm(clap_matrix, axis=1, keepdims=True)

    lyr_scores = (lyr_matrix / (lyr_norms + 1e-12)) @ lyr_seed
    clap_scores = (clap_matrix / (clap_norms + 1e-12)) @ clap_seed
    blended = LYRICS_WEIGHT * lyr_scores + CLAP_WEIGHT * clap_scores

    top_idx = np.argsort(-blended)[: limit * 3]
    top_keys = [keys[int(i)] for i in top_idx]
    placeholders = ",".join("?" for _ in top_keys)
    meta_rows = conn.execute(
        f"""SELECT item_key, title, artist, album, year
            FROM tracks WHERE item_key IN ({placeholders})""",
        top_keys,
    ).fetchall()
    by_key = {r["item_key"]: dict(r) for r in meta_rows}

    out: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for i in top_idx:
        if len(out) >= limit:
            break
        k = keys[int(i)]
        meta = by_key.get(k, {"item_key": k})
        dedup = (
            (meta.get("artist") or "").lower().strip(),
            (meta.get("title") or "").lower().strip(),
        )
        if dedup in seen:
            continue
        seen.add(dedup)
        meta["lyrics_similarity"] = round(float(lyr_scores[int(i)]), 4)
        meta["clap_similarity"] = round(float(clap_scores[int(i)]), 4)
        meta["combined_similarity"] = round(float(blended[int(i)]), 4)
        out.append(meta)
    return out


def get_thematic_taste(conn: sqlite3.Connection, top_n: int = 30) -> dict[str, Any]:
    """Rank mood centroids by their similarity to the user's average lyric embedding.

    Pulls the ``top_n`` most-played tracks that have a lyrics embedding, averages
    their embeddings, and computes cosine similarity against every mood centroid.

    Returns:
        Dict with:
          - ``moods``: ordered list of {"mood": str, "score": float (0-1)}.
          - ``n_source_tracks``: how many top tracks contributed.
          - ``message``: optional explanation when ``moods`` is empty.
    """
    import numpy as np  # noqa: PLC0415

    rows = conn.execute(
        """
        SELECT le.embedding, COUNT(lh.id) AS play_count
        FROM lyrics_embeddings le
        JOIN tracks t ON t.item_key = le.item_key
        JOIN listening_history lh
            ON LOWER(lh.track_title) = LOWER(t.title)
           AND LOWER(lh.artist) = LOWER(t.artist)
        GROUP BY le.item_key
        ORDER BY play_count DESC
        LIMIT ?
        """,
        (top_n,),
    ).fetchall()

    if len(rows) < MIN_THEMATIC_TRACKS:
        return {
            "moods": [],
            "n_source_tracks": len(rows),
            "message": (
                f"Not enough top-played tracks with lyrics — "
                f"need {MIN_THEMATIC_TRACKS}, have {len(rows)}."
            ),
        }

    matrix = np.stack(
        [np.frombuffer(r["embedding"], dtype=np.float32) for r in rows]
    ).astype(np.float32)
    user_centroid = _norm(matrix.mean(axis=0))

    moods: list[dict[str, Any]] = []
    for mood in mood_lyrics.available_moods():
        try:
            mood_vec = mood_lyrics.mood_centroid(mood)
        except Exception:
            continue
        score = float(np.dot(user_centroid, mood_vec))
        # Cosine for normalised vectors is already in [-1, 1]; clamp to [0, 1]
        # so the consumer can interpret it as a preference strength.
        moods.append({"mood": mood, "score": round(max(0.0, min(1.0, score)), 4)})

    moods.sort(key=lambda x: x["score"], reverse=True)
    return {
        "moods": moods,
        "n_source_tracks": len(rows),
        "message": None,
    }
