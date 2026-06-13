"""Results persistence — generated playlists and album recommendations.

Provides CRUD operations on the ``results`` table in the local SQLite
cache.  All functions open their own connection via get_connection().
"""

import json
import logging
import secrets
from typing import Any

from backend.db import get_connection

logger = logging.getLogger(__name__)


def save_result(
    result_type: str,
    title: str,
    prompt: str,
    snapshot: dict,
    track_count: int,
    artist: str | None = None,
    art_item_key: str | None = None,
    subtitle: str | None = None,
    source_mode: str | None = None,
) -> str:
    """Persist a generated result and return its unique ID.

    Args:
        result_type:  One of ``"prompt_playlist"``, ``"seed_playlist"``, or
                      ``"album_recommendation"``.
        title:        Display title for the result card.
        prompt:       Original user prompt.
        snapshot:     Full serialized response dict (GenerateResponse or
                      RecommendGenerateResponse).
        track_count:  Number of tracks in the result.
        artist:       Primary artist name (for album recommendations).
        art_item_key: Item key used to fetch thumbnail art.
        subtitle:     Pre-computed subtitle shown in the history feed.
        source_mode:  Source mode used for generation (library/hybrid/qobuz).

    Returns:
        16-character hex ID for the saved result.
    """
    with get_connection() as conn:
        # Generate a collision-resistant ID; INSERT OR IGNORE handles the
        # (very unlikely) case of a concurrent insert with the same ID.
        for _ in range(10):
            result_id = secrets.token_hex(8)
            cursor = conn.execute(
                """INSERT OR IGNORE INTO results
                       (id, type, title, prompt, snapshot, track_count,
                        artist, art_item_key, subtitle, source_mode)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    result_id,
                    result_type,
                    title,
                    prompt,
                    json.dumps(snapshot),
                    track_count,
                    artist,
                    art_item_key,
                    subtitle,
                    source_mode,
                ),
            )
            if cursor.rowcount > 0:
                break
        else:
            raise RuntimeError(
                "Failed to generate unique result ID after 10 attempts"
            )

        conn.commit()
        logger.info(
            "Saved result %s (type=%s, tracks=%d)", result_id, result_type, track_count
        )
        return result_id


def get_result(result_id: str) -> dict[str, Any] | None:
    """Fetch a single result by ID with its snapshot parsed from JSON.

    Returns:
        Dict with all columns, or None if the ID is not found.
    """
    with get_connection() as conn:
        row = conn.execute(
            "SELECT id, type, title, prompt, snapshot, track_count, "
            "artist, art_item_key, subtitle, source_mode, created_at, "
            "ai_description, ai_tags "
            "FROM results WHERE id = ?",
            (result_id,),
        ).fetchone()

        if not row:
            return None

        return {
            "id": row["id"],
            "type": row["type"],
            "title": row["title"],
            "prompt": row["prompt"],
            "snapshot": json.loads(row["snapshot"]),
            "track_count": row["track_count"],
            "artist": row["artist"],
            "art_item_key": row["art_item_key"],
            "subtitle": row["subtitle"],
            "source_mode": row["source_mode"],
            "created_at": row["created_at"],
            "ai_description": row["ai_description"],
            "ai_tags": json.loads(row["ai_tags"]) if row["ai_tags"] else None,
        }


def list_results(
    result_type: str | None = None,
    limit: int = 20,
    offset: int = 0,
) -> tuple[list[dict[str, Any]], int]:
    """List results ordered by creation date (newest first), without snapshots.

    Args:
        result_type: Optional type filter; may be comma-separated for multiple
                     types (e.g. ``"prompt_playlist,seed_playlist"``).
        limit:       Maximum number of results to return.
        offset:      Pagination offset.

    Returns:
        Tuple of (list of result dicts without snapshot, total matching count).
    """
    with get_connection() as conn:
        where_clause = ""
        params: list[Any] = []

        if result_type:
            types = [t.strip() for t in result_type.split(",") if t.strip()]
            placeholders = ",".join("?" for _ in types)
            where_clause = f"WHERE type IN ({placeholders})"
            params = list(types)

        total: int = conn.execute(
            f"SELECT COUNT(*) FROM results {where_clause}", params
        ).fetchone()[0]

        rows = conn.execute(
            f"""SELECT id, type, title, prompt, track_count, artist,
                       art_item_key, subtitle, source_mode, created_at,
                       ai_description, ai_tags
                FROM results {where_clause}
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?""",
            params + [limit, offset],
        ).fetchall()

        results = [
            {
                "id": row["id"],
                "type": row["type"],
                "title": row["title"],
                "prompt": row["prompt"],
                "track_count": row["track_count"],
                "artist": row["artist"],
                "art_item_key": row["art_item_key"],
                "subtitle": row["subtitle"],
                "source_mode": row["source_mode"],
                "created_at": row["created_at"],
                "ai_description": row["ai_description"],
                "ai_tags": json.loads(row["ai_tags"]) if row["ai_tags"] else None,
            }
            for row in rows
        ]
        return results, total


def delete_result(result_id: str) -> bool:
    """Delete a result by ID.

    Returns:
        True if a row was deleted, False if the ID was not found.
    """
    with get_connection() as conn:
        cursor = conn.execute("DELETE FROM results WHERE id = ?", (result_id,))
        conn.commit()
        deleted = cursor.rowcount > 0
        if deleted:
            logger.info("Deleted result %s", result_id)
        return deleted
