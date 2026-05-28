"""Intelligence layer endpoints — taste profile, listening history, saved playlists, tags."""

import asyncio
import contextlib
import json
import logging
from datetime import datetime, timedelta

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from backend.db import get_db_connection
from backend.filter_sessions import get_session
from backend.taste_profile import TasteProfile

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["intelligence"])


def _safe_str(v: object) -> object:
    """Return v unchanged unless it's a bytes-like str with invalid UTF-8.

    SQLite may store strings with corrupt byte sequences originating from
    Roon metadata.  Pydantic v2 raises PydanticSerializationError when it
    tries to JSON-encode them.  Replace undecodable bytes with the replacement
    character so the response is always valid UTF-8.
    """
    if not isinstance(v, str):
        return v
    # Fast path — most strings are already valid
    try:
        v.encode("utf-8").decode("utf-8")
        return v
    except (UnicodeEncodeError, UnicodeDecodeError):
        return v.encode("utf-8", errors="replace").decode("utf-8", errors="replace")


def _sanitize(d: dict) -> dict:
    return {k: _safe_str(val) for k, val in d.items()}


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class TasteProfileUpdateRequest(BaseModel):
    updates: dict


class TasteEventRequest(BaseModel):
    event_type: str
    data: dict = {}


class SavePlaylistRequest(BaseModel):
    name: str
    prompt: str | None = None
    tracks_json: str | None = None   # JSON array of {title, artist, album, item_key}
    source_mode: str = "library"
    tags: str | None = ""           # comma-separated


class SavePlaylistFromSessionRequest(BaseModel):
    """Save playlist directly from a filter_tracks session_id + track_numbers."""
    name: str
    prompt: str | None = None
    session_id: str
    track_numbers: list[int]
    source_mode: str = "library"
    tags: list[str] | None = None


class UpdatePlaylistRequest(BaseModel):
    name: str | None = None
    tags: str | None = None
    rating: int | None = None
    qobuz_playlist_id: str | None = None


class ModifyPlaylistRequest(BaseModel):
    session_id: str
    remove_numbers: list[int] | None = None
    add_numbers: list[int] | None = None
    swap: list[list[int]] | None = None


# ---------------------------------------------------------------------------
# Taste Profile endpoints
# ---------------------------------------------------------------------------


@router.get("/taste/profile")
async def get_taste_profile() -> dict:
    """Return the current taste profile (compact — fits in < 2 000 tokens)."""
    profile = TasteProfile.get()
    # Keep top-N entries to stay token-compact
    profile["genres"]  = dict(sorted(profile.get("genres", {}).items(),  key=lambda x: -x[1])[:20])
    profile["artists"] = dict(sorted(profile.get("artists", {}).items(), key=lambda x: -x[1])[:30])
    profile["decades"] = dict(sorted(profile.get("decades", {}).items(), key=lambda x: -x[1])[:10])
    profile["moods"]   = dict(sorted(profile.get("moods", {}).items(),   key=lambda x: -x[1])[:10])
    # Build top_genres as array — frontend taste.js expects [{name, score}, ...]
    profile["top_genres"] = [
        {"name": name, "score": round(score, 4)}
        for name, score in sorted(profile.get("genres", {}).items(), key=lambda x: -x[1])[:20]
    ]
    # Fallback decade data from lb_era_distribution when profile.decades is empty
    if not profile.get("decades"):
        lb_era = profile.get("lb_era_distribution", {})
        if lb_era:
            profile["decades"] = lb_era
    # New keys pass through as-is (already compact from compute)
    # recently_active, listening_patterns, skip_signals, artist_streaks, top_albums
    return profile


@router.post("/taste/profile")
async def update_taste_profile(request: TasteProfileUpdateRequest) -> dict:
    """Merge *updates* into the stored taste profile and return the new profile."""
    return TasteProfile.update(request.updates)


@router.post("/taste/event")
async def log_taste_event(request: TasteEventRequest) -> dict:
    """Log a taste event (playlist_created, playlist_rated, feedback, skip, etc.)."""
    TasteProfile.add_event(request.event_type, request.data)
    return {"status": "ok", "event_type": request.event_type}


@router.get("/taste/events")
async def get_taste_events(limit: int = Query(20, ge=1, le=200)) -> list[dict]:
    """Return the *limit* most recent taste events."""
    return TasteProfile.get_recent_events(limit)


# ---------------------------------------------------------------------------
# Listening History endpoints
# ---------------------------------------------------------------------------


@router.get("/listening/history")
async def get_listening_history(
    limit: int = Query(50, ge=1, le=500),
    zone: str | None = Query(None),
    days: int = Query(7, ge=1, le=3650),
) -> list[dict]:
    """Return recent listening history rows."""
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()

    conn = get_db_connection()
    try:
        sql = """
            SELECT id, timestamp, zone_name, track_title, artist, album,
                   genre, duration_seconds, played_seconds, skipped
            FROM listening_history
            WHERE timestamp >= ?
        """
        params: list = [cutoff]
        if zone:
            sql += " AND zone_name = ?"
            params.append(zone)
        sql += " ORDER BY timestamp DESC LIMIT ?"
        params.append(limit)

        rows = conn.execute(sql, params).fetchall()
        result = []
        for r in rows:
            # Use the album image_key (from albums table) which is the correct Roon image key.
            # Fall back to track item_key if no album image_key is found.
            art_key = None
            if r[5] and r[4]:  # album and artist
                art_row = conn.execute(
                    "SELECT image_key FROM albums WHERE title = ? AND artist = ? LIMIT 1",
                    (r[5], r[4]),
                ).fetchone()
                if art_row and art_row[0]:
                    art_key = art_row[0]
            if not art_key and r[3] and r[4]:  # fallback: track item_key
                art_row = conn.execute(
                    "SELECT t.parent_item_key FROM tracks t WHERE t.title = ? AND t.artist = ? LIMIT 1",
                    (r[3], r[4]),
                ).fetchone()
                if art_row and art_row[0]:
                    fallback = conn.execute(
                        "SELECT image_key FROM albums WHERE item_key = ? LIMIT 1",
                        (art_row[0],),
                    ).fetchone()
                    if fallback and fallback[0]:
                        art_key = fallback[0]
            result.append(_sanitize({
                "id":               r[0],
                "timestamp":        r[1],
                "zone_name":        r[2],
                "track_title":      r[3],
                "artist":           r[4],
                "album":            r[5],
                "genre":            r[6],
                "duration_seconds": r[7],
                "played_seconds":   r[8],
                "skipped":          bool(r[9]),
                "image_key":        art_key,
            }))
        return result
    finally:
        conn.close()


@router.get("/listening/stats/zones")
async def get_listening_stats_zones(days: int = Query(30, ge=1, le=3650)) -> list[dict]:
    """Return per-zone listening stats for the last *days* days."""
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
    conn = get_db_connection()
    try:
        zone_rows = conn.execute(
            """
            SELECT zone_name,
                   COUNT(*) as total_plays,
                   SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) as skipped,
                   SUM(played_seconds) as total_seconds,
                   MAX(timestamp) as last_played
            FROM listening_history
            WHERE timestamp >= ? AND zone_name IS NOT NULL AND zone_name != ''
            GROUP BY zone_name ORDER BY total_plays DESC
            """,
            (cutoff,),
        ).fetchall()

        result = []
        for zr in zone_rows:
            zone_name, total, skipped_count, seconds, last_played = zr
            skip_rate = round(skipped_count / total * 100, 1) if total else 0.0

            top_artists = conn.execute(
                """
                SELECT artist, COUNT(*) as plays
                FROM listening_history
                WHERE timestamp >= ? AND zone_name = ?
                  AND artist IS NOT NULL AND artist != ''
                GROUP BY artist ORDER BY plays DESC LIMIT 5
                """,
                (cutoff, zone_name),
            ).fetchall()

            top_genres = conn.execute(
                """
                SELECT genre, COUNT(*) as plays
                FROM listening_history
                WHERE timestamp >= ? AND zone_name = ?
                  AND genre IS NOT NULL AND genre != ''
                GROUP BY genre ORDER BY plays DESC LIMIT 5
                """,
                (cutoff, zone_name),
            ).fetchall()

            result.append({
                "zone_name":     zone_name,
                "total_plays":   total,
                "total_minutes": round((seconds or 0) / 60),
                "skip_rate_pct": skip_rate,
                "last_played":   last_played,
                "top_artists":   [{"artist": r[0], "plays": r[1]} for r in top_artists],
                "top_genres":    [{"genre": r[0], "plays": r[1]} for r in top_genres],
            })
        return result
    finally:
        conn.close()


@router.get("/listening/stats")
async def get_listening_stats(
    days: int = Query(7, ge=1, le=3650),
    zone: str | None = Query(None),
) -> dict:
    """Return aggregated listening statistics for the last *days* days.

    Args:
        days: Number of days to look back (1–3650).
        zone: Optional Roon zone name to filter by (e.g. "Woonkamer").
    """
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()
    zone_clause = "AND zone_name = ?" if zone else ""
    base_params: list = [cutoff, zone] if zone else [cutoff]

    conn = get_db_connection()
    try:
        artist_rows = conn.execute(
            f"""
            SELECT artist, COUNT(*) as plays,
                   SUM(CASE WHEN skipped = 0 THEN 1 ELSE 0 END) as full_plays
            FROM listening_history
            WHERE timestamp >= ? {zone_clause}
              AND artist IS NOT NULL AND artist != ''
            GROUP BY artist ORDER BY plays DESC LIMIT 15
            """,
            base_params,
        ).fetchall()

        genre_rows = conn.execute(
            f"""
            SELECT genre, COUNT(*) as plays
            FROM listening_history
            WHERE timestamp >= ? {zone_clause}
              AND genre IS NOT NULL AND genre != ''
            GROUP BY genre ORDER BY plays DESC LIMIT 10
            """,
            base_params,
        ).fetchall()

        totals = conn.execute(
            f"""
            SELECT COUNT(*) as total,
                   SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) as skipped,
                   SUM(played_seconds) as total_seconds
            FROM listening_history WHERE timestamp >= ? {zone_clause}
            """,
            base_params,
        ).fetchone()

        daily_rows = conn.execute(
            f"""
            SELECT date(timestamp) as day, COUNT(*) as plays
            FROM listening_history
            WHERE timestamp >= ? {zone_clause}
            GROUP BY day ORDER BY day
            """,
            base_params,
        ).fetchall()

        total = totals[0] or 0
        skipped = totals[1] or 0
        total_minutes = round((totals[2] or 0) / 60)
        skip_rate = round(skipped / total * 100, 1) if total else 0.0

        return {
            "period_days":   days,
            "zone":          zone,
            "total_tracks":  total,
            "total_minutes": total_minutes,
            "skip_rate_pct": skip_rate,
            "daily_plays":   [{"date": r[0], "count": r[1]} for r in daily_rows],
            "top_artists": [
                {
                    "artist":     r[0],
                    "plays":      r[1],
                    "full_plays": r[2],
                    "completion": round(r[2] / r[1] * 100) if r[1] else 0,
                }
                for r in artist_rows
            ],
            "top_genres": [
                {"genre": r[0], "plays": r[1]} for r in genre_rows
            ],
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Saved Playlists endpoints
# ---------------------------------------------------------------------------


@router.get("/playlists/saved")
async def list_saved_playlists(
    limit: int = Query(50, ge=1, le=200),
    tag: str | None = Query(None),
) -> list[dict]:
    """Return saved playlists, optionally filtered by tag."""
    conn = get_db_connection()
    try:
        if tag:
            rows = conn.execute(
                """
                SELECT id, name, prompt, created_at, source_mode, track_count, tags, rating
                FROM saved_playlists
                WHERE (',' || tags || ',') LIKE ?
                ORDER BY created_at DESC LIMIT ?
                """,
                (f"%,{tag},%", limit),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT id, name, prompt, created_at, source_mode, track_count, tags, rating
                FROM saved_playlists ORDER BY created_at DESC LIMIT ?
                """,
                (limit,),
            ).fetchall()

        return [
            {
                "id":          r[0],
                "name":        r[1],
                "prompt":      r[2],
                "created_at":  r[3],
                "source_mode": r[4],
                "track_count": r[5],
                "tags":        [t.strip() for t in (r[6] or "").split(",") if t.strip()],
                "rating":      r[7],
            }
            for r in rows
        ]
    finally:
        conn.close()


@router.post("/playlists/saved")
async def save_playlist(request: SavePlaylistRequest) -> dict:
    """Save a playlist with a pre-built tracks_json string."""
    track_count = 0
    if request.tracks_json:
        with contextlib.suppress(Exception):
            track_count = len(json.loads(request.tracks_json))

    conn = get_db_connection()
    try:
        cursor = conn.execute(
            """
            INSERT INTO saved_playlists (name, prompt, source_mode, track_count, tracks_json, tags)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                request.name,
                request.prompt,
                request.source_mode,
                track_count,
                request.tracks_json,
                request.tags or "",
            ),
        )
        conn.commit()
        playlist_id = cursor.lastrowid
    finally:
        conn.close()

    # Log a taste event
    TasteProfile.add_event("playlist_created", {
        "playlist_id": playlist_id,
        "name": request.name,
        "source_mode": request.source_mode,
        "track_count": track_count,
    })

    return {"status": "saved", "playlist_id": playlist_id, "track_count": track_count}


@router.post("/playlists/saved/from-session")
async def save_playlist_from_session(request: SavePlaylistFromSessionRequest) -> dict:
    """Resolve track numbers via a filter_tracks session and save as a playlist."""
    session = get_session(request.session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session expired or not found")

    key_map: dict[str, str] = session["key_map"]

    # Look up track metadata from SQLite
    item_keys = [key_map[str(n)] for n in request.track_numbers if str(n) in key_map]
    if not item_keys:
        raise HTTPException(status_code=400, detail="No valid track numbers in session")

    conn = get_db_connection()
    try:
        placeholders = ",".join("?" * len(item_keys))
        rows = conn.execute(
            f"SELECT item_key, title, artist, album FROM tracks WHERE item_key IN ({placeholders})",
            item_keys,
        ).fetchall()
        meta = {r[0]: {"item_key": r[0], "title": r[1], "artist": r[2], "album": r[3]} for r in rows}

        tracks_list = [meta.get(k, {"item_key": k, "title": "", "artist": "", "album": ""}) for k in item_keys]
        tracks_json = json.dumps(tracks_list, ensure_ascii=False)
        tags_str = ",".join(request.tags) if request.tags else ""

        cursor = conn.execute(
            """
            INSERT INTO saved_playlists
                (name, prompt, source_mode, track_count, tracks_json, tags)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                request.name,
                request.prompt,
                request.source_mode,
                len(tracks_list),
                tracks_json,
                tags_str,
            ),
        )
        conn.commit()
        playlist_id = cursor.lastrowid
    finally:
        conn.close()

    TasteProfile.add_event("playlist_created", {
        "playlist_id": playlist_id,
        "name": request.name,
        "source_mode": request.source_mode,
        "track_count": len(tracks_list),
    })

    return {
        "status":      "saved",
        "playlist_id": playlist_id,
        "track_count": len(tracks_list),
    }


@router.put("/playlists/saved/{playlist_id}")
async def update_saved_playlist(playlist_id: int, request: UpdatePlaylistRequest) -> dict:
    """Update mutable fields on a saved playlist (name, tags, rating, qobuz_playlist_id)."""
    conn = get_db_connection()
    try:
        existing = conn.execute(
            "SELECT id FROM saved_playlists WHERE id = ?", (playlist_id,)
        ).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Playlist not found")

        updates: list[tuple] = []
        if request.name is not None:
            updates.append(("name", request.name))
        if request.tags is not None:
            updates.append(("tags", request.tags))
        if request.rating is not None:
            if not 1 <= request.rating <= 5:
                raise HTTPException(status_code=400, detail="Rating must be 1-5")
            updates.append(("rating", request.rating))
        if request.qobuz_playlist_id is not None:
            updates.append(("qobuz_playlist_id", request.qobuz_playlist_id))

        updated_rating = None
        if updates:
            set_clause = ", ".join(f"{col} = ?" for col, _ in updates)
            values = [v for _, v in updates] + [playlist_id]
            conn.execute(f"UPDATE saved_playlists SET {set_clause} WHERE id = ?", values)
            conn.commit()

            if request.rating is not None:
                updated_rating = request.rating
                TasteProfile.add_event("playlist_rated", {
                    "playlist_id": playlist_id,
                    "rating": request.rating,
                })

    finally:
        conn.close()

    result: dict = {"status": "updated", "playlist_id": playlist_id}
    if updated_rating is not None:
        result["rating"] = updated_rating
    return result


@router.delete("/playlists/saved/{playlist_id}")
async def delete_saved_playlist(playlist_id: int) -> dict:
    """Delete a saved playlist."""
    conn = get_db_connection()
    try:
        result = conn.execute(
            "DELETE FROM saved_playlists WHERE id = ?", (playlist_id,)
        )
        conn.commit()
        if result.rowcount == 0:
            raise HTTPException(status_code=404, detail="Playlist not found")
    finally:
        conn.close()
    return {"status": "deleted", "playlist_id": playlist_id}


@router.get("/playlists/saved/{playlist_id}/tracks")
async def get_saved_playlist_tracks(playlist_id: int) -> dict:
    """Return the full track list for a saved playlist."""
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT name, tracks_json, track_count, source_mode FROM saved_playlists WHERE id = ?",
            (playlist_id,),
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Playlist not found")

        tracks = []
        if row[1]:
            with contextlib.suppress(Exception):
                tracks = json.loads(row[1])

        return {
            "playlist_id": playlist_id,
            "name":        row[0],
            "track_count": row[2],
            "source_mode": row[3],
            "tracks":      tracks,
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Playlist Modify endpoint
# ---------------------------------------------------------------------------


@router.post("/playlists/modify")
async def modify_playlist(request: ModifyPlaylistRequest) -> dict:
    """Modify a curated playlist in an active session (add/remove/swap track numbers).

    Returns the updated ordered track list so Claude can call curate_and_play
    with the new track_numbers.
    """
    session = get_session(request.session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session expired or not found")

    key_map: dict[str, str] = session["key_map"]
    all_numbers = sorted(int(k) for k in key_map)

    # Start with all numbers; the caller is responsible for passing the current selection.
    # Here we treat the full pool as the working list and apply operations.
    # (The caller should track their selected subset and pass diffs.)
    working: list[int] = list(all_numbers)

    removed: list[int] = []
    added: list[int] = []
    swapped: list[list[int]] = []

    # Remove
    if request.remove_numbers:
        to_remove = set(request.remove_numbers)
        working = [n for n in working if n not in to_remove]
        removed = list(to_remove)

    # Add (from the full pool — numbers that aren't already in working)
    if request.add_numbers:
        present = set(working)
        for n in request.add_numbers:
            if n in key_map and n not in present:
                working.append(n)
                added.append(n)
                present.add(n)

    # Swap positions (swap indices of two numbers within working list)
    if request.swap:
        for pair in request.swap:
            if len(pair) == 2:
                a, b = pair[0], pair[1]
                try:
                    ia = working.index(a)
                    ib = working.index(b)
                    working[ia], working[ib] = working[ib], working[ia]
                    swapped.append([a, b])
                except ValueError:
                    pass

    # Resolve track metadata for the resulting list
    item_keys = [key_map.get(str(n), "") for n in working]
    conn = get_db_connection()
    try:
        if item_keys:
            placeholders = ",".join("?" * len(item_keys))
            meta_rows = conn.execute(
                f"SELECT item_key, title, artist FROM tracks WHERE item_key IN ({placeholders})",
                item_keys,
            ).fetchall()
            meta = {r[0]: {"title": r[1], "artist": r[2]} for r in meta_rows}
        else:
            meta = {}
    finally:
        conn.close()

    result_tracks = [
        {
            "number": n,
            "item_key": key_map.get(str(n), ""),
            "artist": meta.get(key_map.get(str(n), ""), {}).get("artist", ""),
            "title":  meta.get(key_map.get(str(n), ""), {}).get("title", ""),
        }
        for n in working
    ]

    return {
        "session_id":     request.session_id,
        "track_numbers":  working,
        "track_count":    len(working),
        "removed":        removed,
        "added":          added,
        "swapped":        swapped,
        "tracks":         result_tracks,
        "note": (
            "Gebruik deze track_numbers met curate_and_play om de gewijzigde selectie af te spelen."
        ),
    }


# ---------------------------------------------------------------------------
# ListenBrainz integration endpoints
# ---------------------------------------------------------------------------


@router.get("/intelligence/listening-stats")
async def get_intelligence_listening_stats(days: int = Query(30, ge=1, le=3650)) -> dict:
    """Combined local + ListenBrainz stats in one response."""
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()

    conn = get_db_connection()
    try:
        # Local stats
        totals = conn.execute(
            """
            SELECT COUNT(*) as total,
                   SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) as skipped,
                   SUM(played_seconds) as total_seconds
            FROM listening_history WHERE timestamp >= ?
            """,
            (cutoff,),
        ).fetchone()

        artist_rows = conn.execute(
            """
            SELECT artist, COUNT(*) as plays
            FROM listening_history
            WHERE timestamp >= ? AND artist IS NOT NULL AND artist != ''
            GROUP BY artist ORDER BY plays DESC LIMIT 15
            """,
            (cutoff,),
        ).fetchall()

        genre_rows = conn.execute(
            """
            SELECT genre, COUNT(*) as plays
            FROM listening_history
            WHERE timestamp >= ? AND genre IS NOT NULL AND genre != ''
            GROUP BY genre ORDER BY plays DESC LIMIT 10
            """,
            (cutoff,),
        ).fetchall()

        decade_rows = conn.execute(
            """
            SELECT decade, COUNT(*) as plays
            FROM listening_history
            WHERE timestamp >= ? AND decade IS NOT NULL AND decade != ''
            GROUP BY decade ORDER BY plays DESC
            """,
            (cutoff,),
        ).fetchall()

        # Hour heatmap (local)
        hour_rows = conn.execute(
            """
            SELECT hour_of_day, COUNT(*) as plays
            FROM listening_history
            WHERE timestamp >= ? AND hour_of_day IS NOT NULL
            GROUP BY hour_of_day ORDER BY hour_of_day
            """,
            (cutoff,),
        ).fetchall()

        total = totals[0] or 0
        skipped_count = totals[1] or 0
        total_minutes = round((totals[2] or 0) / 60)
        skip_rate = round(skipped_count / total * 100, 1) if total else 0.0

        local_stats = {
            "period_days": days,
            "total_tracks": total,
            "total_minutes": total_minutes,
            "skip_rate_pct": skip_rate,
            "top_artists": [{"artist": r[0], "plays": r[1]} for r in artist_rows],
            "top_genres": [{"genre": r[0], "plays": r[1]} for r in genre_rows],
            "decades": [{"decade": r[0], "plays": r[1]} for r in decade_rows],
            "hour_heatmap": {str(r[0]): r[1] for r in hour_rows},
        }
    finally:
        conn.close()

    # ListenBrainz cached stats
    lb_data: dict = {}
    try:
        from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415
        lb_sync = get_sync_instance()
        if lb_sync:
            for stat_key in [
                "genre_activity", "daily_activity", "era_activity",
                "artist_map", "top_artists", "top_recordings",
                "similar_users", "feedback_loved", "listening_activity",
            ]:
                cached = lb_sync.get_cached_stat(stat_key)
                if cached is not None:
                    lb_data[stat_key] = cached
            lb_data["last_synced"] = lb_sync.get_last_sync_time()
    except Exception as lb_exc:
        logger.debug("LB stats fetch failed: %s", lb_exc)

    return {"local": local_stats, "listenbrainz": lb_data}


@router.get("/intelligence/taste-profile/detailed")
async def get_detailed_taste_profile() -> dict:
    """Return the full taste profile including ListenBrainz data."""
    profile = TasteProfile.get()
    # Also recompute from history for freshness (async to avoid blocking)
    try:
        profile = await asyncio.to_thread(TasteProfile.compute_profile_from_history)
    except Exception as exc:
        logger.warning("compute_profile_from_history failed: %s", exc)
    return profile


@router.get("/intelligence/taste-profile/summary")
async def get_taste_profile_summary() -> dict:
    """Return a compact text summary of the taste profile (~150-200 tokens).

    Used by the MCP filter_tracks tool so Claude Desktop always sees the user's
    listening profile inline with filter results, without an extra round-trip.
    """
    from backend.taste_profile import build_profile_summary  # noqa: PLC0415
    try:
        summary = await asyncio.to_thread(build_profile_summary)
    except Exception as exc:
        logger.warning("build_profile_summary failed: %s", exc)
        summary = ""
    return {"summary": summary}


@router.post("/intelligence/listenbrainz/sync")
async def trigger_listenbrainz_sync() -> dict:
    """Manually trigger a ListenBrainz stats sync.

    Always forces a full re-fetch (ignores cache TTL) so that stale or
    corrupt data from a previous buggy sync is always overwritten.
    Returns sync summary.
    """
    try:
        from backend.db import get_db_connection  # noqa: PLC0415
        from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415

        lb_sync = get_sync_instance()
        if not lb_sync:
            raise HTTPException(status_code=503, detail="ListenBrainz not configured")

        # Clear the entire cache before a forced sync so that buggy/empty entries
        # from a previous deployment cannot survive as "fresh" data.
        conn = get_db_connection()
        try:
            conn.execute("DELETE FROM lb_stats_cache")
            conn.commit()
            logger.info("Cleared lb_stats_cache for forced manual sync")
        finally:
            conn.close()

        # force=True bypasses the 6-hour TTL — the whole point of a manual sync.
        summary = await lb_sync.sync_all(force=True)
        return {"status": "ok", "summary": summary}
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("LB sync failed: %s", exc)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@router.get("/intelligence/listenbrainz/status")
async def get_listenbrainz_status() -> dict:
    """Return ListenBrainz configuration and sync status."""
    from backend.config import get_listenbrainz_config  # noqa: PLC0415

    lb_cfg = get_listenbrainz_config()
    configured = bool(lb_cfg["token"])
    username = lb_cfg["username"] or ""

    # Scrobble count (listens with source != null)
    scrobble_count = 0
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT COUNT(*) FROM listening_history WHERE source IS NOT NULL AND source != ''"
        ).fetchone()
        scrobble_count = row[0] if row else 0
    finally:
        conn.close()

    # Last sync time
    last_synced = None
    try:
        from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415
        lb_sync = get_sync_instance()
        if lb_sync:
            last_synced = lb_sync.get_last_sync_time()
    except Exception:
        pass

    return {
        "configured": configured,
        "username": username,
        "last_synced": last_synced,
        "scrobble_count": scrobble_count,
        "connected": configured,
        "profile_url": f"https://listenbrainz.org/user/{username}" if username else None,
    }


@router.get("/intelligence/listenbrainz/recommendations")
async def get_listenbrainz_recommendations() -> list[dict]:
    """Return ListenBrainz 'created for you' playlist recommendations."""
    try:
        from backend.listenbrainz_client import get_lb_client  # noqa: PLC0415
        lb = get_lb_client()
        if not lb:
            raise HTTPException(status_code=503, detail="ListenBrainz not configured")
        playlists = await lb.get_playlists_created_for()
        return playlists
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("LB recommendations fetch failed: %s", exc)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


# ---------------------------------------------------------------------------
# Last.fm endpoints
# ---------------------------------------------------------------------------


@router.get("/intelligence/lastfm/status")
async def get_lastfm_status() -> dict:
    """Return Last.fm configuration and sync status."""
    from backend.config import get_lastfm_config  # noqa: PLC0415

    lf_cfg = get_lastfm_config()
    configured = bool(lf_cfg["api_key"] and lf_cfg["api_secret"])
    can_scrobble = configured and bool(lf_cfg["session_key"])
    username = lf_cfg["username"] or ""

    last_synced = None
    try:
        from backend.lastfm_sync import get_lf_sync_instance  # noqa: PLC0415
        lf_sync = get_lf_sync_instance()
        if lf_sync:
            last_synced = lf_sync.get_last_sync_time()
    except Exception:
        pass

    return {
        "configured":   configured,
        "can_scrobble": can_scrobble,
        "username":     username,
        "last_synced":  last_synced,
        "connected":    can_scrobble,
        "profile_url":  f"https://www.last.fm/user/{username}" if username else None,
    }


class LastFmAuthTokenResponse(BaseModel):
    token: str
    auth_url: str


@router.post("/intelligence/lastfm/auth/token")
async def lastfm_get_auth_token() -> dict:
    """Request a Last.fm auth token and return the auth URL to open in a browser.

    The user must visit auth_url to grant permission, then call
    POST /intelligence/lastfm/auth/session with the same token.
    """
    from backend.config import get_lastfm_config  # noqa: PLC0415
    from backend.lastfm_client import LastFmClient, get_lf_client  # noqa: PLC0415

    lf_cfg = get_lastfm_config()
    if not lf_cfg["api_key"] or not lf_cfg["api_secret"]:
        raise HTTPException(status_code=400, detail="Last.fm API key and secret must be configured first")

    # Use a temporary client (the singleton may not exist yet)
    client = get_lf_client() or LastFmClient(
        api_key=lf_cfg["api_key"],
        api_secret=lf_cfg["api_secret"],
    )

    token = await client.get_auth_token()
    if not token:
        raise HTTPException(status_code=502, detail="Failed to obtain auth token from Last.fm")

    auth_url = client.get_auth_url(token)
    return {"token": token, "auth_url": auth_url}


class LastFmSessionRequest(BaseModel):
    token: str


@router.post("/intelligence/lastfm/auth/session")
async def lastfm_get_session(request: LastFmSessionRequest) -> dict:
    """Exchange an authorised Last.fm token for a permanent session key.

    Saves the session key (and username if available) to config.user.yaml.
    """
    from backend.config import get_lastfm_config, save_user_config  # noqa: PLC0415
    from backend.lastfm_client import LastFmClient, get_lf_client, init_lf_client  # noqa: PLC0415
    from backend.lastfm_sync import init_lf_sync_instance  # noqa: PLC0415

    lf_cfg = get_lastfm_config()
    if not lf_cfg["api_key"] or not lf_cfg["api_secret"]:
        raise HTTPException(status_code=400, detail="Last.fm API key and secret not configured")

    client = get_lf_client() or LastFmClient(
        api_key=lf_cfg["api_key"],
        api_secret=lf_cfg["api_secret"],
    )

    session = await client.get_session(request.token)
    if not session:
        raise HTTPException(
            status_code=400,
            detail="Failed to get session — have you authorised the token at last.fm?",
        )

    session_key = session["key"]
    username = session["name"]

    # Persist to config
    try:
        save_user_config({"lastfm": {"session_key": session_key, "username": username}})
    except Exception as save_exc:
        logger.warning("Failed to save Last.fm session key: %s", save_exc)

    # Re-init the singleton client with the new session key
    try:
        lf = init_lf_client(
            api_key=lf_cfg["api_key"],
            api_secret=lf_cfg["api_secret"],
            session_key=session_key,
            username=username,
        )
        init_lf_sync_instance(lf)
    except Exception as init_exc:
        logger.warning("Failed to re-init Last.fm client: %s", init_exc)

    return {
        "status":      "ok",
        "username":    username,
        "session_key": session_key,
    }


@router.post("/intelligence/lastfm/sync")
async def trigger_lastfm_sync() -> dict:
    """Manually trigger a Last.fm stats sync (force-re-fetch, ignores TTL)."""
    try:
        from backend.lastfm_sync import get_lf_sync_instance  # noqa: PLC0415

        lf_sync = get_lf_sync_instance()
        if not lf_sync:
            raise HTTPException(status_code=503, detail="Last.fm not configured")

        summary = await lf_sync.sync_all(force=True)
        return {"status": "ok", "summary": summary}
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("Last.fm sync failed: %s", exc)
        raise HTTPException(status_code=500, detail=str(exc)) from exc


class ListenFeedbackRequest(BaseModel):
    artist: str
    title: str
    recording_msid: str | None = None
    score: int  # +1 love, -1 hate


@router.post("/intelligence/listening-history/enrich")
async def enrich_listening_history() -> dict:
    """Backfill genre/year/decade for imported scrobble rows.

    Pass 1 (fast, SQL): exact lowercased title+artist match against the library.
    Pass 2 (fuzzy, Python): rapidfuzz on rows still missing genre after pass 1,
    handles minor title/artist variations (e.g. featuring credits, remaster tags).
    """
    from rapidfuzz import fuzz  # noqa: PLC0415  # noqa: I001

    from backend.scrobble_import import enrich_imported_genres  # noqa: PLC0415

    conn = get_db_connection()
    try:
        # -- Pass 1: fast SQL exact match ----------------------------------
        sql_updated = enrich_imported_genres(conn)

        # -- Pass 2: fuzzy match for remaining unmatched rows --------------
        unmatched = conn.execute(
            """
            SELECT id, track_title, artist
            FROM listening_history
            WHERE (genre IS NULL OR genre = '')
              AND source IN ('lastfm', 'listenbrainz')
              AND track_title IS NOT NULL AND track_title != ''
              AND artist IS NOT NULL AND artist != ''
            LIMIT 5000
            """
        ).fetchall()

        fuzzy_updated = 0
        for row in unmatched:
            hist_id, title, artist = row[0], row[1], row[2]
            try:
                candidates = conn.execute(
                    "SELECT item_key, title, artist, year FROM tracks WHERE LOWER(artist) LIKE ? LIMIT 30",
                    (f"%{artist[:20].lower()}%",),
                ).fetchall()
                best_key, best_score, best_year = None, 0, None
                for c in candidates:
                    score = fuzz.token_sort_ratio(
                        f"{artist} {title}",
                        f"{c['artist']} {c['title']}",
                    )
                    if score > best_score:
                        best_score = score
                        best_key = c["item_key"]
                        best_year = c["year"]
                if best_key and best_score >= 80:
                    genre_rows = conn.execute(
                        "SELECT genre FROM track_genres WHERE track_key = ?",
                        (best_key,),
                    ).fetchall()
                    genre = ", ".join(r[0] for r in genre_rows)
                    decade = f"{(best_year // 10) * 10}s" if best_year else None
                    conn.execute(
                        "UPDATE listening_history SET genre=?, year=?, decade=? WHERE id=?",
                        (genre or None, best_year, decade, hist_id),
                    )
                    fuzzy_updated += 1
            except Exception as row_exc:
                logger.debug("Enrich row %d failed: %s", hist_id, row_exc)

        conn.commit()
        return {
            "status": "ok",
            "sql_updated": sql_updated,
            "fuzzy_checked": len(unmatched),
            "fuzzy_updated": fuzzy_updated,
            "total_updated": sql_updated + fuzzy_updated,
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Roon Tags endpoint
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Scrobble history import (Last.fm + ListenBrainz)
# ---------------------------------------------------------------------------


@router.post("/intelligence/lastfm/import-history")
async def start_lastfm_history_import() -> dict:
    """Start a background import of all Last.fm scrobbles since 2014."""
    from backend.lastfm_client import get_lf_client  # noqa: PLC0415
    from backend.scrobble_import import is_running, start_lastfm_import  # noqa: PLC0415

    lf_client = get_lf_client()
    if lf_client is None or not lf_client.is_configured():
        raise HTTPException(status_code=400, detail="Last.fm not configured")
    if is_running("lastfm"):
        return {"started": False, "message": "Import already in progress"}
    await start_lastfm_import(lf_client, from_year=2014)
    return {"started": True, "message": "Last.fm history import started"}


@router.get("/intelligence/lastfm/import-status")
async def get_lastfm_import_status() -> dict:
    """Get the current status of the Last.fm history import."""
    from backend.scrobble_import import get_import_state, is_running  # noqa: PLC0415

    state = get_import_state("lastfm")
    state["is_running"] = is_running("lastfm")
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT COUNT(*) FROM listening_history WHERE source='lastfm' AND (genre IS NULL OR genre='')"
        ).fetchone()
        state["rows_missing_genre"] = row[0] if row else 0
    finally:
        conn.close()
    return state


@router.post("/intelligence/listenbrainz/import-history")
async def start_lb_history_import() -> dict:
    """Start a background import of all ListenBrainz listens."""
    from backend.listenbrainz_client import get_lb_client  # noqa: PLC0415
    from backend.scrobble_import import is_running, start_lb_import  # noqa: PLC0415

    lb_client = get_lb_client()
    if lb_client is None or not await lb_client.is_configured():
        raise HTTPException(status_code=400, detail="ListenBrainz not configured")
    if is_running("listenbrainz"):
        return {"started": False, "message": "Import already in progress"}
    await start_lb_import(lb_client, from_year=2014)
    return {"started": True, "message": "ListenBrainz history import started"}


@router.get("/intelligence/listenbrainz/import-status")
async def get_lb_import_status() -> dict:
    """Get the current status of the ListenBrainz history import."""
    from backend.scrobble_import import get_import_state, is_running  # noqa: PLC0415

    state = get_import_state("listenbrainz")
    state["is_running"] = is_running("listenbrainz")
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT COUNT(*) FROM listening_history WHERE source='listenbrainz' AND (genre IS NULL OR genre='')"
        ).fetchone()
        state["rows_missing_genre"] = row[0] if row else 0
    finally:
        conn.close()
    return state


@router.post("/intelligence/lastfm/tag-enrich")
async def start_lastfm_tag_enrichment() -> dict:
    """Start background enrichment of unmatched scrobbles via Last.fm artist.getTopTags.

    Fetches genre tags for every distinct artist that still has scrobbles with
    a NULL genre (i.e. tracks not in the Roon library).  Runs at ~4.5 req/s;
    expect ~17 minutes for 4 000+ unique artists.
    """
    from backend.lastfm_client import get_lf_client  # noqa: PLC0415
    from backend.scrobble_import import (  # noqa: PLC0415
        get_tag_enrich_state,
        start_lastfm_tag_enrich,
    )

    lf_client = get_lf_client()
    if lf_client is None or not lf_client.is_configured():
        raise HTTPException(status_code=400, detail="Last.fm not configured")
    if get_tag_enrich_state().get("status") == "running":
        return {"started": False, "message": "Tag enrichment already running"}
    await start_lastfm_tag_enrich(lf_client)
    return {"started": True, "message": "Last.fm tag enrichment started"}


@router.get("/intelligence/lastfm/tag-enrich-status")
async def get_lastfm_tag_enrich_status() -> dict:
    """Return progress of the Last.fm tag enrichment job."""
    from backend.scrobble_import import get_tag_enrich_state  # noqa: PLC0415

    state = get_tag_enrich_state()
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT COUNT(*) FROM listening_history WHERE source IN ('lastfm','listenbrainz') AND (genre IS NULL OR genre='')"
        ).fetchone()
        state["rows_still_missing_genre"] = row[0] if row else 0
    finally:
        conn.close()
    return state


@router.get("/roon/tags")
async def get_roon_tags() -> list[dict]:
    """Return all user-created Roon Tags via the Browse API."""
    from backend.roon_client import get_roon_client  # noqa: PLC0415

    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    tags = await asyncio.to_thread(roon_client.get_tags)
    return tags
