"""Track queries and filtering against the local SQLite cache.

All functions open their own connection via get_connection() and return
plain Python dicts so callers have no SQLite dependency.
"""

import json
import logging
import random
import re
import sqlite3
from typing import Any

from backend.db import get_connection

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Full-table reads
# ---------------------------------------------------------------------------


def get_cached_tracks() -> list[dict[str, Any]]:
    """Return all tracks from the cache with genres parsed to a list."""
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT item_key, title, artist, album, duration_ms, year, "
            "genres, is_live FROM tracks"
        ).fetchall()

        tracks = []
        for row in rows:
            track = dict(row)
            track["genres"] = json.loads(track["genres"]) if track["genres"] else []
            tracks.append(track)
        return tracks


def has_cached_tracks() -> bool:
    """Return True if the tracks table contains at least one row.

    Queries the actual table rather than sync_state.track_count so that
    partial syncs (mid-run batch commits) and interrupted syncs correctly
    report True.
    """
    with get_connection() as conn:
        return (
            conn.execute("SELECT EXISTS(SELECT 1 FROM tracks LIMIT 1)").fetchone()[0] == 1
        )


# ---------------------------------------------------------------------------
# Filtered queries
# ---------------------------------------------------------------------------


def get_vibe_tags_for_keys(conn: sqlite3.Connection, keys: list[str]) -> dict[str, dict]:
    """Return {item_key: {"contexts": [...], "moods": [...]}} for the given keys.

    Used by the generator to inject vibe labels into the numbered track list.
    """
    if not keys:
        return {}
    ph = ",".join("?" for _ in keys)
    rows = conn.execute(
        f"SELECT item_key, contexts, moods FROM track_vibes WHERE item_key IN ({ph})",
        keys,
    ).fetchall()
    result: dict[str, dict] = {}
    for row in rows:
        result[row["item_key"]] = {
            "contexts": json.loads(row["contexts"] or "[]"),
            "moods": json.loads(row["moods"] or "[]"),
        }
    return result


def get_tracks_by_filters(
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    exclude_live: bool = True,
    limit: int = 0,
    bpm_min: float | None = None,
    bpm_max: float | None = None,
    camelot_keys: list[str] | None = None,
    energy_min: float | None = None,
    energy_max: float | None = None,
    danceability_min: float | None = None,
    valence_min: float | None = None,
    valence_max: float | None = None,
    instrumentalness_min: float | None = None,
    vibe_contexts: list[str] | None = None,
    vibe_moods: list[str] | None = None,
) -> list[dict[str, Any]]:
    """Return tracks matching the given filters.

    Args:
        genres:       Genre names to include (OR matching). None = all genres.
        decades:      Decade strings like "1990s" (OR matching). None = all.
        exclude_live: Exclude tracks flagged as live recordings (default True).
        limit:        Maximum rows to return; 0 means no limit.
        bpm_min, bpm_max:        Tempo range (joins track_audio_features).
        camelot_keys:            Restrict to these Camelot codes (joins).
        energy_min, energy_max:  0..1 energy range.
        danceability_min:        Lower bound on heuristic danceability.
        valence_min, valence_max: 0..1 valence (positivity) range.
        instrumentalness_min:    Lower bound on instrumentalness.

    Any audio-feature filter triggers an INNER JOIN on track_audio_features
    so tracks without analysis are silently skipped. Without audio-feature
    params the legacy fast path is taken (no JOIN).

    Returns:
        List of track dicts with genres parsed to a Python list.
    """
    audio_filters_active = any(v is not None for v in [
        bpm_min, bpm_max, energy_min, energy_max,
        danceability_min, valence_min, valence_max, instrumentalness_min,
    ]) or bool(camelot_keys)

    with get_connection() as conn:
        conditions: list[str] = []
        params: list[Any] = []

        if exclude_live:
            conditions.append("t.is_live = 0")

        if decades:
            decade_conditions = []
            for decade in decades:
                try:
                    start_year = int(decade.rstrip("s"))
                except ValueError:
                    continue
                end_year = start_year + 9
                decade_conditions.append("(t.year >= ? AND t.year <= ?)")
                params.extend([start_year, end_year])
            if decade_conditions:
                conditions.append(f"({' OR '.join(decade_conditions)})")

        # Audio-feature conditions — only emitted when at least one param is set,
        # and require an INNER JOIN to be added by the caller branches below.
        if audio_filters_active:
            if bpm_min is not None:
                conditions.append("af.bpm >= ?")
                params.append(bpm_min)
            if bpm_max is not None:
                conditions.append("af.bpm <= ?")
                params.append(bpm_max)
            if camelot_keys:
                ph = ",".join("?" for _ in camelot_keys)
                conditions.append(f"af.camelot IN ({ph})")
                params.extend(camelot_keys)
            if energy_min is not None:
                conditions.append("af.energy >= ?")
                params.append(energy_min)
            if energy_max is not None:
                conditions.append("af.energy <= ?")
                params.append(energy_max)
            if danceability_min is not None:
                conditions.append("af.danceability >= ?")
                params.append(danceability_min)
            if valence_min is not None:
                conditions.append("af.valence >= ?")
                params.append(valence_min)
            if valence_max is not None:
                conditions.append("af.valence <= ?")
                params.append(valence_max)
            if instrumentalness_min is not None:
                conditions.append("af.instrumentalness >= ?")
                params.append(instrumentalness_min)

        audio_join = (
            " JOIN track_audio_features af ON af.item_key = t.item_key"
            if audio_filters_active else ""
        )

        where_clause = " AND ".join(conditions) if conditions else "1=1"

        tracks: list[dict[str, Any]] = []

        if genres:
            has_genre_index = conn.execute(
                "SELECT EXISTS(SELECT 1 FROM track_genres LIMIT 1)"
            ).fetchone()[0]

            if has_genre_index:
                genres_lower = [g.lower() for g in genres]
                genre_placeholders = ",".join("?" for _ in genres_lower)
                query = (
                    f"SELECT DISTINCT t.* FROM tracks t "
                    f"JOIN track_genres tg ON t.item_key = tg.track_key"
                    f"{audio_join} "
                    f"WHERE {where_clause} "
                    f"AND LOWER(tg.genre) IN ({genre_placeholders})"
                )
                genre_params = list(params) + list(genres_lower)
                if limit > 0 and not (vibe_contexts or vibe_moods):
                    query += " ORDER BY RANDOM() LIMIT ?"
                    genre_params.append(limit)
                rows = conn.execute(query, genre_params).fetchall()
                for row in rows:
                    track = dict(row)
                    track["genres"] = json.loads(track["genres"]) if track.get("genres") else []
                    tracks.append(track)
            else:
                # Fallback: junction table empty — filter in Python
                logger.debug("track_genres empty, falling back to Python-side genre filtering")
                base_query = f"SELECT t.* FROM tracks t{audio_join} WHERE {where_clause}"
                rows = conn.execute(base_query, params).fetchall()
                genres_lower_set = {g.lower() for g in genres}
                for row in rows:
                    track = dict(row)
                    track["genres"] = json.loads(track["genres"]) if track.get("genres") else []
                    if any(g.lower() in genres_lower_set for g in track["genres"]):
                        tracks.append(track)
        else:
            # No genre filter
            query = f"SELECT t.* FROM tracks t{audio_join} WHERE {where_clause}"
            if limit > 0 and not (vibe_contexts or vibe_moods):
                query += " ORDER BY RANDOM() LIMIT ?"
                params.append(limit)
            rows = conn.execute(query, params).fetchall()
            for row in rows:
                track = dict(row)
                track["genres"] = json.loads(track["genres"]) if track.get("genres") else []
                tracks.append(track)

        # Vibe-context/mood merge: OR-union with the genre results above.
        if vibe_contexts or vibe_moods:
            vibe_kw_conds: list[str] = []
            vibe_kw_params: list[Any] = []
            for kw in (vibe_contexts or []):
                vibe_kw_conds.append("LOWER(tv.contexts) LIKE ?")
                vibe_kw_params.append(f"%{kw.lower()}%")
            for kw in (vibe_moods or []):
                vibe_kw_conds.append("LOWER(tv.moods) LIKE ?")
                vibe_kw_params.append(f"%{kw.lower()}%")
            if vibe_kw_conds:
                base = ["t.is_live = 0"] if exclude_live else []
                vibe_where = (" AND ".join(base) + " AND " if base else "") + f"({' OR '.join(vibe_kw_conds)})"
                vibe_rows = conn.execute(
                    f"SELECT DISTINCT t.* FROM tracks t "
                    f"JOIN track_vibes tv ON tv.item_key = t.item_key "
                    f"WHERE {vibe_where}",
                    vibe_kw_params,
                ).fetchall()
                seen = {t["item_key"] for t in tracks}
                for row in vibe_rows:
                    vt = dict(row)
                    vt["genres"] = json.loads(vt["genres"]) if vt.get("genres") else []
                    if vt["item_key"] not in seen:
                        tracks.append(vt)
                        seen.add(vt["item_key"])

        # Apply limit + shuffle after potential vibe merge
        if limit > 0 and len(tracks) > limit:
            random.shuffle(tracks)
            tracks = tracks[:limit]

        return tracks


def count_tracks_by_filters(
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    exclude_live: bool = True,
) -> int:
    """Count tracks matching filters without fetching full row data.

    Returns:
        Count of matching tracks, or -1 if the cache is empty.
    """
    with get_connection() as conn:
        has_rows = conn.execute(
            "SELECT EXISTS(SELECT 1 FROM tracks LIMIT 1)"
        ).fetchone()[0]
        if not has_rows:
            return -1

        conditions: list[str] = []
        params: list[Any] = []

        if exclude_live:
            conditions.append("is_live = 0")

        if decades:
            decade_conditions = []
            for decade in decades:
                try:
                    start_year = int(decade.rstrip("s"))
                except ValueError:
                    continue
                end_year = start_year + 9
                decade_conditions.append("(year >= ? AND year <= ?)")
                params.extend([start_year, end_year])
            if decade_conditions:
                conditions.append(f"({' OR '.join(decade_conditions)})")

        where_clause = " AND ".join(conditions) if conditions else "1=1"

        if not genres:
            count = conn.execute(
                f"SELECT COUNT(*) FROM tracks WHERE {where_clause}", params
            ).fetchone()[0]
            return count

        has_genre_index = conn.execute(
            "SELECT EXISTS(SELECT 1 FROM track_genres LIMIT 1)"
        ).fetchone()[0]

        if has_genre_index:
            genres_lower = [g.lower() for g in genres]
            genre_placeholders = ",".join("?" for _ in genres_lower)
            query = (
                f"SELECT COUNT(DISTINCT t.item_key) FROM tracks t "
                f"JOIN track_genres tg ON t.item_key = tg.track_key "
                f"WHERE {where_clause} "
                f"AND LOWER(tg.genre) IN ({genre_placeholders})"
            )
            params.extend(genres_lower)
            return conn.execute(query, params).fetchone()[0]

        # Fallback: count via Python
        rows = conn.execute(
            f"SELECT genres FROM tracks WHERE {where_clause}", params
        ).fetchall()
        genres_lower_set = {g.lower() for g in genres}
        count = 0
        for row in rows:
            if row["genres"] and any(
                g.lower() in genres_lower_set
                for g in json.loads(row["genres"])
            ):
                count += 1
        return count


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------


def search_cached_tracks(query: str, limit: int = 20) -> list[dict[str, Any]]:
    """Case-insensitive LIKE search across artist, title, and album fields.

    Results are sorted: artist-name matches first, then by artist / album /
    title order.
    """
    with get_connection() as conn:
        search_term = f"%{query}%"
        rows = conn.execute(
            """
            SELECT item_key, title, artist, album,
                   duration_ms, year, genres
            FROM tracks
            WHERE artist LIKE ? COLLATE NOCASE
               OR title LIKE ? COLLATE NOCASE
               OR album LIKE ? COLLATE NOCASE
            ORDER BY
                CASE WHEN artist LIKE ? COLLATE NOCASE THEN 0 ELSE 1 END,
                artist, album, title
            LIMIT ?
            """,
            (search_term, search_term, search_term, search_term, limit),
        ).fetchall()

        tracks = []
        for row in rows:
            track = dict(row)
            track["genres"] = (
                json.loads(track["genres"]) if track.get("genres") else []
            )
            tracks.append(track)
        return tracks


def get_album_tracks(artist: str, album: str, limit: int = 100) -> list[dict[str, Any]]:
    """Return an album's tracks from the cache, matched by text (artist + album).

    Discovery sections cache Roon browse keys that go stale after a resync, so
    playing by key fails. Matching on artist/album text yields the *current*
    item_keys, which remain valid for playback.
    """
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT item_key, title, artist, album, duration_ms, year, genres
            FROM tracks
            WHERE album = ? COLLATE NOCASE
              AND artist LIKE ? COLLATE NOCASE
            ORDER BY track_index IS NULL, track_index, item_key
            LIMIT ?
            """,
            (album, f"%{artist}%", limit),
        ).fetchall()
        tracks = []
        for row in rows:
            track = dict(row)
            track["genres"] = json.loads(track["genres"]) if track.get("genres") else []
            tracks.append(track)
        return tracks


# ---------------------------------------------------------------------------
# Lookup by key(s)
# ---------------------------------------------------------------------------


def get_tracks_by_item_keys(item_keys: list[str]) -> dict[str, dict[str, Any]]:
    """Fetch title/artist/album for a list of item_keys.

    Returns:
        Dict mapping item_key → {title, artist, album}. Missing keys are
        absent from the result.
    """
    if not item_keys:
        return {}
    with get_connection() as conn:
        placeholders = ",".join("?" * len(item_keys))
        rows = conn.execute(
            f"SELECT item_key, title, artist, album "
            f"FROM tracks WHERE item_key IN ({placeholders})",
            item_keys,
        ).fetchall()
        return {row["item_key"]: dict(row) for row in rows}


# ---------------------------------------------------------------------------
# Artist album listing
# ---------------------------------------------------------------------------


def get_albums_by_artist(artist: str, max_albums: int = 50) -> list[dict[str, Any]]:
    """Return albums in the cache matching an artist name (partial, case-insensitive).

    Args:
        artist:     Artist name to search for (partial match).
        max_albums: Maximum number of albums to return.

    Returns:
        List of dicts with item_key, album, artist, year, genres.
    """
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT parent_item_key, album, artist, year, genres
            FROM tracks
            WHERE LOWER(artist) LIKE LOWER(?)
            GROUP BY album, artist
            ORDER BY year DESC NULLS LAST, album
            LIMIT ?
            """,
            (f"%{artist}%", max_albums),
        ).fetchall()

        return [
            {
                "item_key": row[0],
                "album": row[1],
                "artist": row[2],
                "year": row[3],
                "genres": json.loads(row[4]) if row[4] else [],
            }
            for row in rows
        ]


# ---------------------------------------------------------------------------
# Album candidates (for recommendation engine)
# ---------------------------------------------------------------------------


def get_album_candidates(
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    exclude_live: bool = True,
) -> list[dict[str, Any]]:
    """Return album candidates for the recommendation engine.

    Queries the dedicated albums table when populated (post-migration sync),
    falling back to aggregating from the tracks table for older databases.

    Args:
        genres:       Optional genre filter (OR matching).
        decades:      Optional decade filter (OR matching, e.g. "1990s").
        exclude_live: Exclude live recordings (default True).

    Returns:
        List of album dicts: parent_item_key, album, album_artist, year,
        genres, decade, track_count, track_item_keys.
    """
    with get_connection() as conn:
        has_albums = conn.execute(
            "SELECT EXISTS(SELECT 1 FROM albums LIMIT 1)"
        ).fetchone()[0]

        if has_albums:
            return _get_album_candidates_from_albums_table(
                conn, genres, decades, exclude_live
            )

        logger.info(
            "albums table empty, falling back to track-aggregation for album candidates"
        )
        return _get_album_candidates_legacy(conn, genres, decades, exclude_live)


def _get_album_candidates_from_albums_table(
    conn: sqlite3.Connection,
    genres: list[str] | None,
    decades: list[str] | None,
    exclude_live: bool,
) -> list[dict[str, Any]]:
    """Query album candidates directly from the albums table."""
    conditions: list[str] = []
    params: list[Any] = []

    if decades:
        decade_conditions = []
        for decade in decades:
            try:
                start_year = int(decade.rstrip("s"))
            except ValueError:
                continue
            end_year = start_year + 9
            decade_conditions.append("(year >= ? AND year <= ?)")
            params.extend([start_year, end_year])
        if decade_conditions:
            conditions.append(f"({' OR '.join(decade_conditions)})")

    where_clause = " AND ".join(conditions) if conditions else "1=1"
    rows = conn.execute(
        f"SELECT item_key, title, artist, year, genres, image_key "
        f"FROM albums WHERE {where_clause}",
        params,
    ).fetchall()

    result: list[dict[str, Any]] = []
    genres_lower = [g.lower() for g in genres] if genres else None

    for row in rows:
        album_genres = json.loads(row["genres"]) if row["genres"] else []

        if genres_lower:
            album_genres_lower = [g.lower() for g in album_genres]
            if not any(g in album_genres_lower for g in genres_lower):
                continue

        year = row["year"]
        decade = f"{(year // 10) * 10}s" if year else ""

        if exclude_live:
            title = row["title"] or ""
            if re.search(r"\b(?:live|concert|bootleg)\b", title, re.IGNORECASE):
                continue
            if re.search(r"\d{4}[-/]\d{2}[-/]\d{2}", title):
                continue

        result.append({
            "parent_item_key": row["item_key"],
            "album": row["title"],
            "album_artist": row["artist"],
            "year": year,
            "genres": album_genres,
            "decade": decade,
            "track_count": 0,        # Not needed for recommendation selection
            "track_item_keys": [],   # Populated lazily at play time
        })

    return result


def _get_album_candidates_legacy(
    conn: sqlite3.Connection,
    genres: list[str] | None,
    decades: list[str] | None,
    exclude_live: bool,
) -> list[dict[str, Any]]:
    """Aggregate album candidates from the tracks table (pre-albums-table databases)."""
    conditions = ["parent_item_key IS NOT NULL", "parent_item_key != ''"]
    if exclude_live:
        conditions.append("is_live = 0")
    params: list[Any] = []

    if decades:
        decade_conditions = []
        for decade in decades:
            try:
                start_year = int(decade.rstrip("s"))
            except ValueError:
                continue
            end_year = start_year + 9
            decade_conditions.append("(year >= ? AND year <= ?)")
            params.extend([start_year, end_year])
        if decade_conditions:
            conditions.append(f"({' OR '.join(decade_conditions)})")

    where_clause = " AND ".join(conditions)
    rows = conn.execute(
        f"SELECT item_key, title, artist, album, year, genres, parent_item_key "
        f"FROM tracks WHERE {where_clause} "
        f"ORDER BY parent_item_key, item_key",
        params,
    ).fetchall()

    albums: dict[str, dict[str, Any]] = {}
    for row in rows:
        prk = row["parent_item_key"]
        track_genres = json.loads(row["genres"]) if row["genres"] else []

        if prk not in albums:
            year = row["year"]
            decade = ""
            if year:
                decade = f"{(year // 10) * 10}s"
            albums[prk] = {
                "parent_item_key": prk,
                "album": row["album"],
                "album_artist": row["artist"],
                "year": year,
                "genres": [],
                "decade": decade,
                "track_count": 0,
                "track_item_keys": [],
                "_genre_set": set(),
            }

        album = albums[prk]
        album["track_count"] += 1
        album["track_item_keys"].append(row["item_key"])
        for g in track_genres:
            if g not in album["_genre_set"]:
                album["_genre_set"].add(g)
                album["genres"].append(g)

    genres_lower = [g.lower() for g in genres] if genres else None
    result: list[dict[str, Any]] = []
    for album in albums.values():
        del album["_genre_set"]
        if genres_lower:
            album_genres_lower = [g.lower() for g in album["genres"]]
            if not any(g in album_genres_lower for g in genres_lower):
                continue
        result.append(album)

    return result


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------


def get_cached_genre_decade_stats() -> dict[str, Any]:
    """Return genre/decade/total stats from the local cache.

    When track-level year coverage is sparse (<10 %), decade counts are
    supplemented from the albums table via a parent_item_key join.

    Returns:
        Dict with ``total_tracks`` (int), ``genres`` and ``decades`` lists
        of ``{"name": str, "count": int}`` sorted by name.
    """
    with get_connection() as conn:
        total_tracks: int = conn.execute(
            "SELECT COUNT(*) FROM tracks"
        ).fetchone()[0]

        rows = conn.execute("SELECT genres, year FROM tracks").fetchall()

        genre_counts: dict[str, int] = {}
        decade_counts: dict[str, int] = {}

        for row in rows:
            if row["genres"]:
                for g in json.loads(row["genres"]):
                    genre_counts[g] = genre_counts.get(g, 0) + 1

            year = row["year"]
            if year:
                decade_name = f"{(year // 10) * 10}s"
                decade_counts[decade_name] = decade_counts.get(decade_name, 0) + 1

        # Supplement from albums table when track-level year data is sparse
        tracks_with_year = sum(decade_counts.values())
        if total_tracks > 0 and tracks_with_year < total_tracks * 0.10:
            album_rows = conn.execute(
                "SELECT a.year, COUNT(t.item_key) AS cnt "
                "FROM albums a "
                "JOIN tracks t ON t.parent_item_key = a.item_key "
                "WHERE a.year IS NOT NULL "
                "GROUP BY a.year"
            ).fetchall()
            for album_row in album_rows:
                decade_name = f"{(album_row['year'] // 10) * 10}s"
                decade_counts[decade_name] = (
                    decade_counts.get(decade_name, 0) + album_row["cnt"]
                )

        genres = sorted(
            [{"name": n, "count": c} for n, c in genre_counts.items()],
            key=lambda x: x["name"],
        )
        decades = sorted(
            [{"name": n, "count": c} for n, c in decade_counts.items()],
            key=lambda x: x["name"],
        )

        return {"total_tracks": total_tracks, "genres": genres, "decades": decades}


# ---------------------------------------------------------------------------
# Familiarity
# ---------------------------------------------------------------------------


def get_album_familiarity(
    parent_item_keys: list[str] | None = None,
) -> dict[str, dict]:
    """Aggregate play-count data for albums into familiarity levels.

    Classifies each album as:
    - ``"unplayed"``   — 0 total plays across all tracks
    - ``"well-loved"`` — average plays per track ≥ 3
    - ``"light"``      — some plays but average < 3

    Args:
        parent_item_keys: Albums to query; None returns all albums.

    Returns:
        Dict mapping parent_item_key → ``{"level": str, "last_viewed_at": str|None}``.
    """
    with get_connection() as conn:
        query = (
            "SELECT parent_item_key, "
            "SUM(view_count) AS total_plays, "
            "AVG(view_count) AS avg_plays, "
            "MAX(last_viewed_at) AS last_viewed "
            "FROM tracks "
            "WHERE parent_item_key IS NOT NULL AND parent_item_key != '' "
        )
        params: list[str] = []

        if parent_item_keys is not None:
            placeholders = ",".join("?" for _ in parent_item_keys)
            query += f"AND parent_item_key IN ({placeholders}) "
            params.extend(parent_item_keys)

        query += "GROUP BY parent_item_key"

        rows = conn.execute(query, params).fetchall()

        result: dict[str, dict] = {}
        for row in rows:
            total_plays = row["total_plays"] or 0
            avg_plays = row["avg_plays"] or 0

            if total_plays == 0:
                level = "unplayed"
            elif avg_plays >= 3:
                level = "well-loved"
            else:
                level = "light"

            result[row["parent_item_key"]] = {
                "level": level,
                "last_viewed_at": row["last_viewed"],
            }

        return result


# ---------------------------------------------------------------------------
# Enrichment helpers
# ---------------------------------------------------------------------------


def get_enriched_tags_for_keys(item_keys: list[str]) -> dict[str, list[str]]:
    """Return a mapping of item_key → combined enriched tags (MB + Last.fm).

    Only item_keys that have a row in ``track_metadata_ext`` are returned.
    Tags are de-duplicated and capped at 8 per track to stay token-efficient.

    Args:
        item_keys: Roon item_keys to look up.

    Returns:
        Dict mapping item_key → list of tag strings (may be empty list).
    """
    if not item_keys:
        return {}

    with get_connection() as conn:
        placeholders = ",".join("?" for _ in item_keys)
        rows = conn.execute(
            f"SELECT item_key, mb_tags, lastfm_tags "
            f"FROM track_metadata_ext WHERE item_key IN ({placeholders})",
            item_keys,
        ).fetchall()

    result: dict[str, list[str]] = {}
    for row in rows:
        tags: list[str] = []
        seen: set[str] = set()

        for col in ("mb_tags", "lastfm_tags"):
            raw = row[col]
            if raw:
                try:
                    for t in json.loads(raw):
                        t_lower = t.lower().strip()
                        if t_lower and t_lower not in seen:
                            tags.append(t)
                            seen.add(t_lower)
                except (json.JSONDecodeError, TypeError):
                    pass

        result[row["item_key"]] = tags[:8]  # Cap per track

    return result
