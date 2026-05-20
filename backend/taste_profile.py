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
    },
    "recently_active": {
        "period": "7d",
        "top_genres": [...],
        "top_artists": [...],
        "total_plays": 87,
        "avg_per_day": 12.4
    },
    "listening_patterns": {
        "evening_genres": [...],
        "morning_genres": [...],
        "weekend_genres": [...],
        "peak_hour": 21,
        "peak_day": "Friday"
    },
    "skip_signals": {
        "genres":  [{"genre": "Country", "skip_rate": 0.78, "plays": 12}],
        "artists": [{"artist": "Ed Sheeran", "skip_rate": 0.82, "plays": 8}]
    },
    "artist_streaks": [
        {"artist": "Nick Cave", "plays_7d": 15, "plays_30d": 22}
    ],
    "top_albums": [
        {"album": "OK Computer", "artist": "Radiohead", "plays": 24}
    ]
}
"""

import json
import logging
import threading
from collections import defaultdict
from datetime import datetime

logger = logging.getLogger(__name__)

_profile_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Module-level constants
# ---------------------------------------------------------------------------

# Maps genre keywords (checked as substring of lowercased genre name) to mood categories.
GENRE_MOOD_MAP: dict[str, str] = {
    "ambient": "contemplative",
    "classical": "contemplative",
    "new age": "contemplative",
    "electronic": "energetic",
    "dance": "energetic",
    "house": "energetic",
    "techno": "energetic",
    "jazz": "smooth",
    "soul": "smooth",
    "r&b": "smooth",
    "blues": "smooth",
    "alternative": "melancholic",
    "indie": "melancholic",
    "singer-songwriter": "melancholic",
    "rock": "intense",
    "metal": "intense",
    "punk": "intense",
    "hardcore": "intense",
    "pop": "upbeat",
    "funk": "upbeat",
    "disco": "upbeat",
}

# ISO weekday (Python: 0=Mon, 6=Sun) to name string.
_DAY_NAMES: dict[int, str] = {
    0: "Monday",
    1: "Tuesday",
    2: "Wednesday",
    3: "Thursday",
    4: "Friday",
    5: "Saturday",
    6: "Sunday",
}

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


def _age_weight(age_days: float) -> float:
    """Return a recency multiplier for a play that occurred *age_days* days ago."""
    if age_days <= 7:
        return 3.0
    if age_days <= 30:
        return 1.5
    if age_days <= 90:
        return 1.0
    return 0.5


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
        - recently_active / listening_patterns / skip_signals /
          artist_streaks / top_albums / lb_* : always overwrite entirely
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
                # ── 1 & 2: Time-weighted genre aggregation (with genre splitting) ──
                #
                # Fetch raw rows so we can split comma-separated genre strings in
                # Python before aggregating.  age_days is computed by SQLite so we
                # avoid datetime parsing overhead in Python.
                raw_genre_rows = conn.execute(
                    """
                    SELECT genre,
                           CAST(julianday('now') - julianday(timestamp) AS REAL) AS age_days,
                           skipped
                    FROM listening_history
                    WHERE genre IS NOT NULL AND genre != ''
                    LIMIT 15000
                    """,
                ).fetchall()

                # weighted_plays and weighted_full_plays per individual genre
                genre_weighted: dict[str, float] = defaultdict(float)
                genre_full_weighted: dict[str, float] = defaultdict(float)

                for genre_str, age_days_val, skipped in raw_genre_rows:
                    w = _age_weight(float(age_days_val or 9999))
                    for g in genre_str.split(", "):
                        g = g.strip()
                        if not g:
                            continue
                        genre_weighted[g] += w
                        if not skipped:
                            genre_full_weighted[g] += w

                genre_scores: dict[str, float] = {}
                if genre_weighted:
                    max_w = max(genre_weighted.values()) or 1.0
                    # Top 30 genres by weighted plays
                    top_genre_items = sorted(
                        genre_weighted.items(), key=lambda x: x[1], reverse=True
                    )[:30]
                    for g, w_plays in top_genre_items:
                        completion_rate = genre_full_weighted[g] / max(genre_weighted[g], 1)
                        normalized = (w_plays / max_w) * 0.6 + completion_rate * 0.4
                        genre_scores[g] = round(min(1.0, normalized), 4)

                # ── 1: Time-weighted artist scores ────────────────────────────
                _weight_case = """
                    CASE
                        WHEN julianday('now') - julianday(timestamp) <= 7  THEN 3.0
                        WHEN julianday('now') - julianday(timestamp) <= 30 THEN 1.5
                        WHEN julianday('now') - julianday(timestamp) <= 90 THEN 1.0
                        ELSE 0.5
                    END
                """
                artist_rows = conn.execute(
                    f"""
                    SELECT artist,
                           SUM({_weight_case}) AS weighted_plays,
                           SUM(CASE WHEN skipped = 0 THEN {_weight_case} ELSE 0 END) AS weighted_full_plays
                    FROM listening_history
                    WHERE artist IS NOT NULL AND artist != ''
                    GROUP BY artist
                    ORDER BY weighted_plays DESC
                    LIMIT 50
                    """,
                ).fetchall()

                artist_scores: dict[str, float] = {}
                if artist_rows:
                    max_w = max((r[1] or 0) for r in artist_rows) or 1.0
                    for artist, w_plays, w_full in artist_rows:
                        w_plays = w_plays or 0
                        w_full = w_full or 0
                        completion_rate = w_full / max(w_plays, 1)
                        normalized = (w_plays / max_w) * 0.6 + completion_rate * 0.4
                        artist_scores[artist] = round(min(1.0, normalized), 4)

                # ── 1: Time-weighted decade scores ────────────────────────────
                decade_rows = conn.execute(
                    f"""
                    SELECT decade,
                           SUM({_weight_case}) AS weighted_plays,
                           SUM(CASE WHEN skipped = 0 THEN {_weight_case} ELSE 0 END) AS weighted_full_plays
                    FROM listening_history
                    WHERE decade IS NOT NULL AND decade != ''
                    GROUP BY decade
                    ORDER BY weighted_plays DESC
                    """,
                ).fetchall()

                decade_scores: dict[str, float] = {}
                if decade_rows:
                    max_w = max((r[1] or 0) for r in decade_rows) or 1.0
                    for decade, w_plays, w_full in decade_rows:
                        w_plays = w_plays or 0
                        w_full = w_full or 0
                        completion_rate = w_full / max(w_plays, 1)
                        normalized = (w_plays / max_w) * 0.6 + completion_rate * 0.4
                        decade_scores[decade] = round(min(1.0, normalized), 4)

                # ── 6: Mood scores derived from genre_scores ──────────────────
                mood_totals: dict[str, list[float]] = {}
                for genre, score in genre_scores.items():
                    genre_lower = genre.lower()
                    for keyword, mood in GENRE_MOOD_MAP.items():
                        if keyword in genre_lower:
                            mood_totals.setdefault(mood, []).append(score)
                            break  # first matching keyword wins
                mood_scores: dict[str, float] = {
                    mood: round(sum(scores_list) / len(scores_list), 4)
                    for mood, scores_list in mood_totals.items()
                }

                # ── 3: Recently active (last 7 days) ──────────────────────────
                recent_raw = conn.execute(
                    """
                    SELECT genre, artist
                    FROM listening_history
                    WHERE timestamp >= datetime('now', '-7 days')
                    """,
                ).fetchall()

                recent_genre_counter: dict[str, int] = defaultdict(int)
                recent_artist_counter: dict[str, int] = defaultdict(int)
                for genre_str, artist in recent_raw:
                    if genre_str:
                        for g in genre_str.split(", "):
                            g = g.strip()
                            if g:
                                recent_genre_counter[g] += 1
                    if artist:
                        recent_artist_counter[artist] += 1

                recent_total = len(recent_raw)
                recently_active: dict = {
                    "period": "7d",
                    "top_genres": [
                        g for g, _ in sorted(
                            recent_genre_counter.items(), key=lambda x: x[1], reverse=True
                        )[:5]
                    ],
                    "top_artists": [
                        a for a, _ in sorted(
                            recent_artist_counter.items(), key=lambda x: x[1], reverse=True
                        )[:10]
                    ],
                    "total_plays": recent_total,
                    "avg_per_day": round(recent_total / 7, 1),
                }

                # ── 4: Listening patterns ──────────────────────────────────────
                pattern_raw = conn.execute(
                    """
                    SELECT genre, hour_of_day, day_of_week
                    FROM listening_history
                    WHERE hour_of_day IS NOT NULL
                    """,
                ).fetchall()

                evening_genres: dict[str, int] = defaultdict(int)
                morning_genres: dict[str, int] = defaultdict(int)
                weekend_genres: dict[str, int] = defaultdict(int)
                hour_counter: dict[int, int] = defaultdict(int)
                day_counter: dict[int, int] = defaultdict(int)

                for genre_str, hour, day in pattern_raw:
                    if hour is not None:
                        hour_counter[int(hour)] += 1
                    if day is not None:
                        day_counter[int(day)] += 1
                    if not genre_str:
                        continue
                    for g in genre_str.split(", "):
                        g = g.strip()
                        if not g:
                            continue
                        if hour is not None and 18 <= int(hour) <= 23:
                            evening_genres[g] += 1
                        if hour is not None and 6 <= int(hour) <= 11:
                            morning_genres[g] += 1
                        if day is not None and int(day) in (5, 6):
                            weekend_genres[g] += 1

                peak_hour: int | None = (
                    max(hour_counter, key=lambda h: hour_counter[h]) if hour_counter else None
                )
                peak_day_num: int | None = (
                    max(day_counter, key=lambda d: day_counter[d]) if day_counter else None
                )
                peak_day: str | None = (
                    _DAY_NAMES.get(peak_day_num) if peak_day_num is not None else None
                )

                def _top3(counter: dict[str, int]) -> list[str]:
                    return [
                        g for g, _ in sorted(counter.items(), key=lambda x: x[1], reverse=True)[:3]
                    ]

                listening_patterns: dict = {
                    "evening_genres": _top3(evening_genres),
                    "morning_genres": _top3(morning_genres),
                    "weekend_genres": _top3(weekend_genres),
                    "peak_hour": peak_hour,
                    "peak_day": peak_day,
                }

                # ── 5: Skip signals ────────────────────────────────────────────
                # Genre skip signals — reuse raw_genre_rows (already has skipped flag)
                skip_genre_total: dict[str, int] = defaultdict(int)
                skip_genre_skipped: dict[str, int] = defaultdict(int)

                for genre_str, _age, skipped in raw_genre_rows:
                    for g in genre_str.split(", "):
                        g = g.strip()
                        if not g:
                            continue
                        skip_genre_total[g] += 1
                        if skipped:
                            skip_genre_skipped[g] += 1

                skip_genre_signals: list[dict] = []
                for g, total in skip_genre_total.items():
                    if total >= 5:
                        sr = skip_genre_skipped[g] / total
                        if sr > 0.5:
                            skip_genre_signals.append(
                                {"genre": g, "skip_rate": round(sr, 3), "plays": total}
                            )
                skip_genre_signals.sort(key=lambda x: x["skip_rate"], reverse=True)
                skip_genre_signals = skip_genre_signals[:10]

                # Artist skip signals — via SQL (artist column is never comma-separated)
                skip_artist_rows = conn.execute(
                    """
                    SELECT artist,
                           COUNT(*) AS total,
                           SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) AS skipped_count
                    FROM listening_history
                    WHERE artist IS NOT NULL AND artist != ''
                    GROUP BY artist
                    HAVING COUNT(*) >= 5
                    ORDER BY (SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) * 1.0 / COUNT(*)) DESC
                    LIMIT 10
                    """,
                ).fetchall()

                skip_artist_signals: list[dict] = []
                for artist, total, skip_count in skip_artist_rows:
                    sr = (skip_count or 0) / max(total, 1)
                    if sr > 0.5:
                        skip_artist_signals.append(
                            {"artist": artist, "skip_rate": round(sr, 3), "plays": total}
                        )

                skip_signals: dict = {
                    "genres": skip_genre_signals,
                    "artists": skip_artist_signals,
                }

                # ── 7: Artist streaks ──────────────────────────────────────────
                streak_rows = conn.execute(
                    """
                    SELECT artist,
                           SUM(CASE WHEN julianday('now') - julianday(timestamp) <= 7  THEN 1 ELSE 0 END) AS plays_7d,
                           SUM(CASE WHEN julianday('now') - julianday(timestamp) <= 30 THEN 1 ELSE 0 END) AS plays_30d
                    FROM listening_history
                    WHERE artist IS NOT NULL AND artist != ''
                    GROUP BY artist
                    HAVING plays_7d >= 5
                    ORDER BY plays_7d DESC
                    LIMIT 5
                    """,
                ).fetchall()

                artist_streaks: list[dict] = [
                    {"artist": r[0], "plays_7d": r[1], "plays_30d": r[2]}
                    for r in streak_rows
                ]

                # ── 8: Top albums (top-level key, limit 15) ────────────────────
                album_rows = conn.execute(
                    """
                    SELECT album, artist, COUNT(*) AS plays
                    FROM listening_history
                    WHERE album IS NOT NULL AND album != ''
                    GROUP BY album, artist
                    ORDER BY plays DESC
                    LIMIT 15
                    """,
                ).fetchall()
                top_albums: list[dict] = [
                    {"album": r[0], "artist": r[1], "plays": r[2]}
                    for r in album_rows
                ]

                # ── General stats ──────────────────────────────────────────────
                stats_row = conn.execute(
                    """
                    SELECT
                        COUNT(*) AS total_tracks,
                        SUM(played_seconds) / 3600.0 AS total_hours,
                        SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS skip_rate,
                        AVG(played_seconds) / 60.0 AS avg_session_min
                    FROM listening_history
                    """,
                ).fetchone()

                # ── Rating stats from taste_events ─────────────────────────────
                rating_rows = conn.execute(
                    """
                    SELECT data_json FROM taste_events
                    WHERE event_type = 'playlist_rated'
                    ORDER BY id DESC
                    LIMIT 100
                    """,
                ).fetchall()

                ratings: list[int] = []
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

            # ── Assemble updates dict ──────────────────────────────────────────
            updates: dict = {}

            if genre_scores:
                updates["genres"] = genre_scores
            if artist_scores:
                updates["artists"] = artist_scores
            if decade_scores:
                updates["decades"] = decade_scores
            if mood_scores:
                updates["moods"] = mood_scores

            # New top-level keys — always overwrite (fresh computation)
            updates["recently_active"] = recently_active
            updates["listening_patterns"] = listening_patterns
            updates["skip_signals"] = skip_signals
            updates["artist_streaks"] = artist_streaks
            updates["top_albums"] = top_albums

            listening_stats: dict = {}
            if stats_row and stats_row[0]:
                listening_stats = {
                    "total_tracks": stats_row[0],
                    "total_hours": round(stats_row[1] or 0, 1),
                    "skip_rate": round(stats_row[2] or 0, 3),
                    "avg_session_min": round(stats_row[3] or 0, 1),
                    "peak_hour": peak_hour,
                    "peak_day": peak_day,
                    # backward-compat: keep top_albums inside stats too (limit 20 → 15)
                    "top_albums": top_albums,
                }

            updates["stats"] = {
                "total_playlists": total_playlists,
                "avg_rating": avg_rating,
                **listening_stats,
            }

            # ── Last.fm data integration ───────────────────────────────────────
            try:
                from backend.lastfm_sync import get_lf_sync_instance  # noqa: PLC0415
                lf_sync = get_lf_sync_instance()
                if lf_sync:
                    lf_top_artists = lf_sync.get_cached_stat("top_artists")
                    if lf_top_artists:
                        updates["lf_top_artists"] = lf_top_artists[:25]

                    lf_similar = lf_sync.get_cached_stat("similar_artists")
                    if lf_similar:
                        updates["lf_similar_artists"] = lf_similar

                    lf_tags = lf_sync.get_cached_stat("artist_tags")
                    if lf_tags:
                        updates["lf_artist_tags"] = lf_tags
                        # Blend tag names into moods with lower weight (0.3)
                        # Collect all tag names from all artists, normalise
                        tag_counter: dict[str, int] = {}
                        for artist_tags in lf_tags.values():
                            for tag_entry in artist_tags:
                                tag_name = tag_entry.get("name", "").lower().strip()
                                if tag_name:
                                    tag_counter[tag_name] = (
                                        tag_counter.get(tag_name, 0)
                                        + tag_entry.get("count", 1)
                                    )
                        if tag_counter:
                            max_tag_count = max(tag_counter.values()) or 1
                            for tag_name, count in tag_counter.items():
                                normalised = round(min(1.0, count / max_tag_count), 4)
                                existing = mood_scores.get(tag_name, 0.0)
                                mood_scores[tag_name] = round(
                                    existing * 0.7 + normalised * 0.3, 4
                                )
                            # Re-apply merged moods
                            updates["moods"] = mood_scores

                    updates["lf_last_synced"] = lf_sync.get_last_sync_time()
            except Exception as lf_exc:
                logger.debug("Last.fm data integration in profile failed: %s", lf_exc)

            # ── ListenBrainz data integration ──────────────────────────────────
            try:
                from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415
                lb_sync = get_sync_instance()
                if lb_sync:
                    genre_activity = lb_sync.get_cached_stat("genre_activity")
                    if genre_activity:
                        updates["lb_genre_by_hour"] = _group_genre_by_hour(genre_activity)

                    era = lb_sync.get_cached_stat("era_activity")
                    if era:
                        updates["lb_era_distribution"] = _bucket_decades(era)

                    daily = lb_sync.get_cached_stat("daily_activity")
                    if daily:
                        payload = daily.get("payload", {}) if isinstance(daily, dict) else {}
                        updates["lb_daily_heatmap"] = payload.get("daily_activity", daily)

                    artist_map = lb_sync.get_cached_stat("artist_map")
                    if artist_map and isinstance(artist_map, list):
                        updates["lb_artist_countries"] = {
                            c.get("country", ""): c.get("artist_count", 0)
                            for c in artist_map
                            if c.get("country")
                        }

                    loved = lb_sync.get_cached_stat("feedback_loved")
                    if loved:
                        updates["lb_loved_recordings"] = loved[:50]

                    hated = lb_sync.get_cached_stat("feedback_hated")
                    if hated:
                        updates["lb_hated_recordings"] = hated[:20]

                    similar = lb_sync.get_cached_stat("similar_users")
                    if similar and isinstance(similar, list):
                        updates["lb_similar_users"] = similar[:10]

                    top_artists = lb_sync.get_cached_stat("top_artists")
                    if top_artists:
                        payload = top_artists.get("payload", {}) if isinstance(top_artists, dict) else {}
                        updates["lb_top_artists"] = payload.get("artists", [])[:25]

                    top_recordings = lb_sync.get_cached_stat("top_recordings")
                    if top_recordings:
                        payload = top_recordings.get("payload", {}) if isinstance(top_recordings, dict) else {}
                        updates["lb_top_recordings"] = payload.get("recordings", [])[:25]

                    top_releases = lb_sync.get_cached_stat("top_releases")
                    if top_releases:
                        payload = top_releases.get("payload", {}) if isinstance(top_releases, dict) else {}
                        updates["lb_top_releases"] = payload.get("releases", [])[:25]

                    listening_activity = lb_sync.get_cached_stat("listening_activity")
                    if listening_activity:
                        updates["lb_listening_activity"] = listening_activity

                    updates["lb_last_synced"] = lb_sync.get_last_sync_time()
            except Exception as lb_exc:
                logger.debug("LB data integration in profile failed: %s", lb_exc)

            new_profile = TasteProfile.update(updates)
            logger.info(
                "Profile recomputed from history: %d genres, %d artists, %d decades",
                len(genre_scores),
                len(artist_scores),
                len(decade_scores),
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
        # Computed analytics (always overwritten on recompute)
        "recently_active": {},
        "listening_patterns": {},
        "skip_signals": {"genres": [], "artists": []},
        "artist_streaks": [],
        "top_albums": [],
        # ListenBrainz-enriched data (prefix lb_)
        "lb_genre_by_hour": {},
        "lb_era_distribution": {},
        "lb_daily_heatmap": {},
        "lb_artist_countries": {},
        "lb_loved_recordings": [],
        "lb_hated_recordings": [],
        "lb_similar_users": [],
        "lb_top_artists": [],
        "lb_top_recordings": [],
        "lb_top_releases": [],
        "lb_listening_activity": [],
        "lb_last_synced": None,
        # Last.fm-enriched data (prefix lf_)
        "lf_top_artists": [],
        "lf_similar_artists": {},
        "lf_artist_tags": {},
        "lf_last_synced": None,
    }


def _group_genre_by_hour(genre_activity: list) -> dict:
    """Group LB genre_activity data by hour bucket.

    Args:
        genre_activity: List of dicts from LB genre-activity endpoint.

    Returns:
        Dict: {hour (0-23): [{"genre": str, "listen_count": int}, ...]}
    """
    by_hour: dict[int, list] = {}
    for item in genre_activity:
        hour = item.get("hour_of_day")
        genre = item.get("genre")
        if hour is None or not genre:
            continue
        if hour not in by_hour:
            by_hour[hour] = []
        by_hour[hour].append({
            "genre": genre,
            "listen_count": item.get("listen_count", 1),
        })
    return by_hour


def _bucket_decades(era_activity: list) -> dict:
    """Bucket year-level listening data into decades.

    Args:
        era_activity: List of {year, listen_count} dicts.

    Returns:
        Dict: {"1990s": 123, "2000s": 456, ...}
    """
    decades: dict[str, int] = {}
    for item in era_activity:
        year = item.get("year") or item.get("release_year")
        if not year:
            continue
        try:
            decade = f"{(int(year) // 10) * 10}s"
            decades[decade] = decades.get(decade, 0) + item.get("listen_count", 1)
        except (ValueError, TypeError):
            pass
    return decades


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
        # Computed analytics — seeded from current; overwritten below if present in updates
        "recently_active":    current.get("recently_active", {}),
        "listening_patterns": current.get("listening_patterns", {}),
        "skip_signals":       current.get("skip_signals", {"genres": [], "artists": []}),
        "artist_streaks":     current.get("artist_streaks", []),
        "top_albums":         current.get("top_albums", []),
        # LB keys: always overwrite (fresh from LB API)
        "lb_genre_by_hour":      current.get("lb_genre_by_hour", {}),
        "lb_era_distribution":   current.get("lb_era_distribution", {}),
        "lb_daily_heatmap":      current.get("lb_daily_heatmap", {}),
        "lb_artist_countries":   current.get("lb_artist_countries", {}),
        "lb_loved_recordings":   current.get("lb_loved_recordings", []),
        "lb_hated_recordings":   current.get("lb_hated_recordings", []),
        "lb_similar_users":      current.get("lb_similar_users", []),
        "lb_top_artists":        current.get("lb_top_artists", []),
        "lb_top_recordings":     current.get("lb_top_recordings", []),
        "lb_top_releases":       current.get("lb_top_releases", []),
        "lb_listening_activity": current.get("lb_listening_activity", []),
        "lb_last_synced":        current.get("lb_last_synced"),
        # Last.fm keys: always overwrite (fresh from Last.fm API)
        "lf_top_artists":     current.get("lf_top_artists", []),
        "lf_similar_artists": current.get("lf_similar_artists", {}),
        "lf_artist_tags":     current.get("lf_artist_tags", {}),
        "lf_last_synced":     current.get("lf_last_synced"),
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

    # All overwrite keys: fresh computed data replaces stored data entirely
    _overwrite_keys = [
        # Computed analytics
        "recently_active",
        "listening_patterns",
        "skip_signals",
        "artist_streaks",
        "top_albums",
        # LB keys
        "lb_genre_by_hour",
        "lb_era_distribution",
        "lb_daily_heatmap",
        "lb_artist_countries",
        "lb_loved_recordings",
        "lb_hated_recordings",
        "lb_similar_users",
        "lb_top_artists",
        "lb_top_recordings",
        "lb_top_releases",
        "lb_listening_activity",
        "lb_last_synced",
        # Last.fm keys
        "lf_top_artists",
        "lf_similar_artists",
        "lf_artist_tags",
        "lf_last_synced",
    ]
    for key in _overwrite_keys:
        if key in updates:
            result[key] = updates[key]

    return result
