"""Lyrics search: encode the query, rank stored embeddings."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from backend.lyrics import embedder

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

SNIPPET_LENGTH = 240  # chars on either side of the most relevant line


def _snippet(lyrics: str | None, query: str) -> str | None:
    if not lyrics:
        return None
    lines = [ln.strip() for ln in lyrics.splitlines() if ln.strip()]
    if not lines:
        return None
    q = query.lower()
    # Crude: pick the line with the most query-word overlap; fall back to
    # the first non-empty line.
    q_words = {w for w in q.split() if len(w) > 2}
    best = (0, lines[0])
    for ln in lines:
        score = sum(1 for w in q_words if w in ln.lower())
        if score > best[0]:
            best = (score, ln)
    snippet = best[1]
    if len(snippet) > SNIPPET_LENGTH:
        snippet = snippet[: SNIPPET_LENGTH - 1] + "…"
    return snippet


def search_lyrics(
    conn: sqlite3.Connection,
    query: str,
    limit: int = 25,
) -> list[dict[str, Any]]:
    """Encode ``query`` and return tracks ranked by cosine similarity."""
    import numpy as np  # noqa: PLC0415

    keys, matrix = embedder.load_all_embeddings(conn)
    if not keys:
        return []

    q_vec = embedder.embed_text(query)
    q_norm = q_vec / (np.linalg.norm(q_vec) + 1e-12)
    mat_norm = matrix / (np.linalg.norm(matrix, axis=1, keepdims=True) + 1e-12)
    scores = mat_norm @ q_norm

    top_idx = np.argsort(-scores)[:limit]
    top_keys = [keys[int(i)] for i in top_idx]
    placeholders = ",".join("?" for _ in top_keys)
    meta_rows = conn.execute(
        f"""SELECT t.item_key, t.title, t.artist, t.album, t.year,
                   ld.lyrics
            FROM tracks t
            LEFT JOIN lyrics_data ld ON ld.item_key = t.item_key
            WHERE t.item_key IN ({placeholders})""",
        top_keys,
    ).fetchall()
    by_key = {r["item_key"]: dict(r) for r in meta_rows}

    out: list[dict[str, Any]] = []
    for i in top_idx:
        k = keys[int(i)]
        meta = by_key.get(k, {"item_key": k})
        meta["similarity"] = float(scores[int(i)])
        meta["snippet"] = _snippet(meta.get("lyrics"), query)
        meta.pop("lyrics", None)  # don't ship full lyrics in the list payload
        out.append(meta)
    return out


def get_track_lyrics(conn: sqlite3.Connection, item_key: str) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT item_key, lyrics, language, extracted_at FROM lyrics_data WHERE item_key = ?",
        (item_key,),
    ).fetchone()
    return dict(row) if row else None
