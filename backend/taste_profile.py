"""Persistent taste profile that evolves with each user interaction.

Profile structure
-----------------
{
    "genres":   {"Jazz": 0.8, "Electronic": 0.6, ...},   # 0-1 preference scores
    "decades":  {"1990s": 0.7, "2000s": 0.5, ...},
    "artists":  {"Radiohead": 0.9, "Miles Davis": 0.85, ...},
    "moods":    {"melancholic": 0.7, "energetic": 0.4, ...},
    "dislikes": ["christmas", "karaoke", ...],
    "notes":    ["prefers album-oriented listening", "no live versions", ...],
    "stats": {
        "total_playlists": 42,
        "avg_rating": 4.2,
        "favorite_time_of_day": "evening",
        "last_updated": "2026-05-18T22:00:00"
    }
}
"""

import json
import logging
import threading
from datetime import datetime

logger = logging.getLogger(__name__)

_profile_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _get_conn():
    """Open a DB connection (caller must close it)."""
    from backend.db import get_db_connection  # noqa: PLC0415
    return get_db_connection()


def _weighted_merge(current: float, new_value: float, weight: float = 0.3) -> float:
    """Blend a new score into the existing value with recency bias.

    Args:
        current:   Existing score (0-1).
        new_value: Incoming score (0-1).
        weight:    How strongly the new value influences the result (0-1).
                   0.3 means "new evidence contributes 30%".
    """
    merged = current * (1.0 - weight) + new_value * weight
    return round(max(0.0, min(1.0, merged)), 4)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


class TasteProfile:
    """Thread-safe access to the user's musical taste profile stored in SQLite."""

    @staticmethod
    def get() -> dict:
        """Load the current taste profile from SQLite.

        Always returns a valid dict; falls back to an empty profile on error.
        """
        try:
            conn = _get_conn()
            try:
                row = conn.execute(
                    "SELECT profile_json FROM taste_profile WHERE id = 1"
                ).fetchone()
                if row and row[0]:
                    stored = json.loads(row[0])
                    # Merge with _empty_profile so all required keys are always present
                    base = _empty_profile()
                    base.update({k: v for k, v in stored.items() if v})
                    return base
            finally:
                conn.close()
        except Exception as exc:
            logger.warning("Failed to load taste profile: %s", exc)

        return _empty_profile()

    @staticmethod
    def update(updates: dict) -> dict:
        """Merge *updates* into the stored profile and return the new profile.

        Merging strategy
        ----------------
        - genres / decades / artists / moods: weighted average (recency bias 30 %)
        - dislikes:  append + deduplicate (case-insensitive)
        - notes:     append + deduplicate (case-insensitive)
        - stats:     always overwrite individual keys
        """
        with _profile_lock:
            try:
                current = TasteProfile.get()
                merged = _merge_profiles(current, updates)
                merged.setdefault("stats", {})["last_updated"] = datetime.utcnow().isoformat()

                conn = _get_conn()
                try:
                    conn.execute(
                        "UPDATE taste_profile SET profile_json = ?, updated_at = datetime('now') WHERE id = 1",
                        (json.dumps(merged, ensure_ascii=False),),
                    )
                    conn.commit()
                finally:
                    conn.close()

                return merged
            except Exception as exc:
                logger.warning("Failed to update taste profile: %s", exc)
                return TasteProfile.get()

    @staticmethod
    def add_event(event_type: str, data: dict) -> None:
        """Log a taste event to the taste_events table.

        Args:
            event_type: One of 'playlist_created', 'playlist_rated', 'feedback',
                        'skip', 'repeat', 'favorite'.
            data:       Arbitrary payload dict (will be JSON-serialised).
        """
        try:
            conn = _get_conn()
            try:
                conn.execute(
                    "INSERT INTO taste_events (event_type, data_json) VALUES (?, ?)",
                    (event_type, json.dumps(data, ensure_ascii=False)),
                )
                conn.commit()
            finally:
                conn.close()
        except Exception as exc:
            logger.warning("Failed to log taste event: %s", exc)

    @staticmethod
    def get_recent_events(limit: int = 20) -> list[dict]:
        """Return the *limit* most recent taste events, newest first."""
        try:
            conn = _get_conn()
            try:
                rows = conn.execute(
                    "SELECT id, timestamp, event_type, data_json "
                    "FROM taste_events ORDER BY id DESC LIMIT ?",
                    (limit,),
                ).fetchall()
                return [
                    {
                        "id": r[0],
                        "timestamp": r[1],
                        "event_type": r[2],
                        "data": json.loads(r[3] or "{}"),
                    }
                    for r in rows
                ]
            finally:
                conn.close()
        except Exception as exc:
            logger.warning("Failed to fetch taste events: %s", exc)
            return []

    @staticmethod
    def compute_profile_from_history() -> dict:
        """Recompute the taste profile from listening history and past events.

        This is a heavier operation meant to be called periodically (e.g. daily),
        not on every request.  Returns the new profile dict (also persists it).
        """
        try:
            conn = _get_conn()
            try:
                # ── Genre scores from listening history ──────────────────────
                genre_rows = conn.execute(
                    """
                    SELECT genre, COUNT(*) as plays,
                           SUM(CASE WHEN skipped = 0 THEN 1 ELSE 0 END) as full_plays
                    FROM listening_history
                    WHERE genre IS NOT NULL AND genre != ''
                    GROUP BY genre
                    ORDER BY plays DESC
                    LIMIT 30
                    """,
                ).fetchall()

                genre_scores: dict[str, float] = {}
                if genre_rows:
                    max_plays = max(r[1] for r in genre_rows) or 1
                    for row in genre_rows:
                        genre, plays, full_plays = row[0], row[1], row[2]
                        completion_rate = full_plays / max(plays, 1)
                        normalized = (plays / max_plays) * 0.6 + completion_rate * 0.4
                        genre_scores[genre] = round(min(1.0, normalized), 4)

                # ── Artist scores from listening history ─────────────────────
                artist_rows = conn.execute(
                    """
                    SELECT artist, COUNT(*) as plays,
                           SUM(CASE WHEN skipped = 0 THEN 1 ELSE 0 END) as full_plays
                    FROM listening_history
                    WHERE artist IS NOT NULL AND artist != ''
                    GROUP BY artist
                    ORDER BY plays DESC
                    LIMIT 50
                    """,
                ).fetchall()

                artist_scores: dict[str, float] = {}
                if artist_rows:
                    max_plays = max(r[1] for r in artist_rows) or 1
                    for row in artist_rows:
                        artist, plays, full_plays = row[0], row[1], row[2]
                        completion_rate = full_plays / max(plays, 1)
                        normalized = (plays / max_plays) * 0.6 + completion_rate * 0.4
                        artist_scores[artist] = round(min(1.0, normalized), 4)

                # ── Rating stats from taste_events ───────────────────────────
                rating_rows = conn.execute(
                    """
                    SELECT data_json FROM taste_events
                    WHERE event_type = 'playlist_rated'
                    ORDER BY id DESC
                    LIMIT 100
                    """,
                ).fetchall()

                ratings = []
                for r in rating_rows:
                    try:
                        d = json.loads(r[0] or "{}")
                        if "rating" in d:
                            ratings.append(int(d["rating"]))
                    except Exception:
                        pass

                avg_rating = round(sum(ratings) / len(ratings), 2) if ratings else 0.0
                total_playlists = conn.execute(
                    "SELECT COUNT(*) FROM taste_events WHERE event_type = 'playlist_created'"
                ).fetchone()[0]

            finally:
                conn.close()

            # ── Merge computed scores with existing profile ───────────────────
            existing = TasteProfile.get()
            updates: dict = {}
            if genre_scores:
                updates["genres"] = genre_scores
            if artist_scores:
                updates["artists"] = artist_scores
            updates["stats"] = {
                "total_playlists": total_playlists,
                "avg_rating": avg_rating,
            }

            new_profile = TasteProfile.update(updates)
            logger.info(
                "Profile recomputed from history: %d genres, %d artists",
                len(genre_scores),
                len(artist_scores),
            )
            return new_profile

        except Exception as exc:
            logger.warning("Failed to compute profile from history: %s", exc)
            return TasteProfile.get()


# ---------------------------------------------------------------------------
# Internal merge logic
# ---------------------------------------------------------------------------


def _empty_profile() -> dict:
    return {
        "genres": {},
        "decades": {},
        "artists": {},
        "moods": {},
        "dislikes": [],
        "notes": [],
        "stats": {},
    }


def _merge_profiles(current: dict, updates: dict) -> dict:
    """Return a new profile dict merging *updates* into *current*."""
    result = {
        "genres":   dict(current.get("genres", {})),
        "decades":  dict(current.get("decades", {})),
        "artists":  dict(current.get("artists", {})),
        "moods":    dict(current.get("moods", {})),
        "dislikes": list(current.get("dislikes", [])),
        "notes":    list(current.get("notes", [])),
        "stats":    dict(current.get("stats", {})),
    }

    # Score maps: weighted merge
    for key in ("genres", "decades", "artists", "moods"):
        incoming: dict = updates.get(key) or {}
        for name, score in incoming.items():
            score = float(score)
            if name in result[key]:
                result[key][name] = _weighted_merge(result[key][name], score)
            else:
                result[key][name] = round(max(0.0, min(1.0, score)), 4)

    # Dislikes: append + case-insensitive dedup
    new_dislikes: list = updates.get("dislikes") or []
    existing_lower = {d.lower() for d in result["dislikes"]}
    for d in new_dislikes:
        if d.lower() not in existing_lower:
            result["dislikes"].append(d)
            existing_lower.add(d.lower())

    # Notes: append + case-insensitive dedup
    new_notes: list = updates.get("notes") or []
    existing_notes_lower = {n.lower() for n in result["notes"]}
    for n in new_notes:
        if n.lower() not in existing_notes_lower:
            result["notes"].append(n)
            existing_notes_lower.add(n.lower())

    # Stats: individual key overwrite
    stat_updates: dict = updates.get("stats") or {}
    result["stats"].update(stat_updates)

    return result
