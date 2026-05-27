"""Mood-based lyric playlists.

Each mood is defined by a small bag of query terms. We embed each term with
the same GTE-multilingual encoder used by ``backend.lyrics.search``, average
the resulting vectors into a single *mood centroid*, then cosine-rank every
track that has a stored lyrics embedding.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from backend.lyrics import embedder

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)


# Curated query terms per mood. Keep these short and concrete so the encoder
# produces a tight centroid; the search itself widens the net.
MOOD_QUERIES: dict[str, list[str]] = {
    "melancholic": ["loss", "rain", "alone", "tears", "goodbye", "fading"],
    "romantic":    ["love", "heart", "together", "kiss", "forever", "darling"],
    "empowering":  ["rise", "fight", "strong", "overcome", "freedom", "stand"],
    "nostalgic":   ["remember", "old days", "childhood", "home", "memory", "time"],
    "dark":        ["shadow", "death", "night", "blood", "fear", "void"],
    "peaceful":    ["calm", "ocean", "sky", "breathe", "silence", "gentle"],
    "rebellious":  ["break", "rules", "fire", "rage", "revolution", "scream"],
    "joyful":      ["dance", "sun", "laugh", "party", "celebrate", "alive"],
}


def available_moods() -> list[str]:
    return list(MOOD_QUERIES.keys())


def mood_centroid(mood: str):
    """Average the embeddings of every query term for ``mood``.

    Returns a normalised numpy float32 vector. Raises ``KeyError`` for an
    unknown mood and ``RuntimeError`` if the embedder is unavailable.
    """
    import numpy as np  # noqa: PLC0415

    if mood not in MOOD_QUERIES:
        raise KeyError(f"Unknown mood: {mood}")
    vectors = [embedder.embed_text(q) for q in MOOD_QUERIES[mood]]
    matrix = np.stack(vectors).astype(np.float32)
    centroid = matrix.mean(axis=0)
    norm = np.linalg.norm(centroid)
    if norm > 0:
        centroid = centroid / norm
    return centroid


def _moods_available_in_db(conn: sqlite3.Connection) -> bool:
    return bool(
        conn.execute("SELECT 1 FROM lyrics_embeddings LIMIT 1").fetchone()
    )


def get_lyrics_mood_playlist(
    mood: str,
    limit: int,
    conn: sqlite3.Connection,
) -> list[dict[str, Any]]:
    """Rank tracks by cosine similarity to a mood centroid.

    Returns the top ``limit`` tracks, deduplicated by (artist, title) so the
    same recording doesn't crowd the list when it appears on multiple albums.
    """
    import numpy as np  # noqa: PLC0415

    if not _moods_available_in_db(conn):
        return []

    centroid = mood_centroid(mood)

    keys, matrix = embedder.load_all_embeddings(conn)
    if not keys:
        return []

    row_norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    normed = matrix / (row_norms + 1e-12)
    scores = normed @ centroid

    # Pull more candidates than asked for to leave headroom for deduplication.
    top_idx = np.argsort(-scores)[: limit * 4]
    placeholders = ",".join("?" for _ in top_idx)
    top_keys = [keys[int(i)] for i in top_idx]
    meta_rows = conn.execute(
        f"""SELECT item_key, title, artist, album, year
            FROM tracks WHERE item_key IN ({placeholders})""",
        top_keys,
    ).fetchall()
    by_key = {r["item_key"]: dict(r) for r in meta_rows}

    out: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for idx in top_idx:
        if len(out) >= limit:
            break
        k = keys[int(idx)]
        meta = by_key.get(k, {"item_key": k})
        dedup = (
            (meta.get("artist") or "").lower().strip(),
            (meta.get("title") or "").lower().strip(),
        )
        if dedup in seen:
            continue
        seen.add(dedup)
        score = float(scores[int(idx)])
        meta["similarity"] = round(score, 4)
        meta["mood"] = mood
        out.append(meta)
    return out


def get_moods_with_counts(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    """Best-effort track-count estimate per mood.

    For each mood, the count is the number of tracks whose lyrics embedding
    has a cosine similarity above a small floor (``0.20``). Cheap relative
    to a full ranking because we score in one matrix multiply.
    """
    import numpy as np  # noqa: PLC0415

    if not _moods_available_in_db(conn):
        return [{"mood": m, "track_count": 0} for m in available_moods()]

    keys, matrix = embedder.load_all_embeddings(conn)
    if not keys:
        return [{"mood": m, "track_count": 0} for m in available_moods()]

    row_norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    normed = matrix / (row_norms + 1e-12)

    out: list[dict[str, Any]] = []
    for mood in available_moods():
        try:
            centroid = mood_centroid(mood)
        except RuntimeError:
            out.append({"mood": mood, "track_count": 0})
            continue
        scores = normed @ centroid
        out.append({
            "mood": mood,
            "track_count": int((scores > 0.20).sum()),
        })
    return out
