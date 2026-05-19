"""Intelligence layer endpoints — taste profile, listening history, saved playlists, tags."""

import asyncio
import json
import logging
from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from backend.db import get_db_connection
from backend.filter_sessions import get_session
from backend.taste_profile import TasteProfile

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["intelligence"])


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
    prompt: Optional[str] = None
    tracks_json: Optional[str] = None   # JSON array of {title, artist, album, item_key}
    source_mode: str = "library"
    tags: Optional[str] = ""           # comma-separated


class SavePlaylistFromSessionRequest(BaseModel):
    """Save playlist directly from a filter_tracks session_id + track_numbers."""
    name: str
    prompt: Optional[str] = None
    session_id: str
    track_numbers: list[int]
    source_mode: str = "library"
    tags: Optional[list[str]] = None


class UpdatePlaylistRequest(BaseModel):
    name: Optional[str] = None
    tags: Optional[str] = None
    rating: Optional[int] = None
    qobuz_playlist_id: Optional[str] = None


class ModifyPlaylistRequest(BaseModel):
    session_id: str
    remove_numbers: Optional[list[int]] = None
    add_numbers: Optional[list[int]] = None
    swap: Optional[list[list[int]]] = None


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
    zone: Optional[str] = Query(None),
    days: int = Query(7, ge=1, le=365),
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
        return [
            {
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
            }
            for r in rows
        ]
    finally:
        conn.close()


@router.get("/listening/stats")
async def get_listening_stats(days: int = Query(7, ge=1, le=365)) -> dict:
    """Return aggregated listening statistics for the last *days* days."""
    cutoff = (datetime.utcnow() - timedelta(days=days)).isoformat()

    conn = get_db_connection()
    try:
        # Top artists
        artist_rows = conn.execute(
            """
            SELECT artist, COUNT(*) as plays,
                   SUM(CASE WHEN skipped = 0 THEN 1 ELSE 0 END) as full_plays
            FROM listening_history
            WHERE timestamp >= ? AND artist IS NOT NULL AND artist != ''
            GROUP BY artist ORDER BY plays DESC LIMIT 15
            """,
            (cutoff,),
        ).fetchall()

        # Top genres
        genre_rows = conn.execute(
            """
            SELECT genre, COUNT(*) as plays
            FROM listening_history
            WHERE timestamp >= ? AND genre IS NOT NULL AND genre != ''
            GROUP BY genre ORDER BY plays DESC LIMIT 10
            """,
            (cutoff,),
        ).fetchall()

        # Overall stats
        totals = conn.execute(
            """
            SELECT COUNT(*) as total,
                   SUM(CASE WHEN skipped = 1 THEN 1 ELSE 0 END) as skipped,
                   SUM(played_seconds) as total_seconds
            FROM listening_history WHERE timestamp >= ?
            """,
            (cutoff,),
        ).fetchone()

        total = totals[0] or 0
        skipped = totals[1] or 0
        total_minutes = round((totals[2] or 0) / 60)
        skip_rate = round(skipped / total * 100, 1) if total else 0.0

        return {
            "period_days":   days,
            "total_tracks":  total,
            "total_minutes": total_minutes,
            "skip_rate_pct": skip_rate,
            "top_artists": [
                {
                    "artist":      r[0],
                    "plays":       r[1],
                    "full_plays":  r[2],
                    "completion":  round(r[2] / r[1] * 100) if r[1] else 0,
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
    tag: Optional[str] = Query(None),
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
        try:
            track_count = len(json.loads(request.tracks_json))
        except Exception:
            pass

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
            try:
                tracks = json.loads(row[1])
            except Exception:
                pass

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
    all_numbers = sorted(int(k) for k in key_map.keys())

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
async def get_intelligence_listening_stats(days: int = Query(30, ge=1, le=365)) -> dict:
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


@router.post("/intelligence/listenbrainz/sync")
async def trigger_listenbrainz_sync() -> dict:
    """Manually trigger a ListenBrainz stats sync. Returns sync summary."""
    try:
        from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415
        lb_sync = get_sync_instance()
        if not lb_sync:
            raise HTTPException(status_code=503, detail="ListenBrainz not configured")
        summary = await lb_sync.sync_all()
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


class ListenFeedbackRequest(BaseModel):
    artist: str
    title: str
    recording_msid: Optional[str] = None
    score: int  # +1 love, -1 hate


@router.post("/intelligence/listening-history/enrich")
async def enrich_listening_history() -> dict:
    """Backfill genre/year/decade for listening_history rows with empty genre.

    Fuzzy-matches tracks against the library cache using artist + title.
    """
    from rapidfuzz import fuzz  # noqa: PLC0415

    conn = get_db_connection()
    try:
        rows = conn.execute(
            """
            SELECT id, track_title, artist
            FROM listening_history
            WHERE (genre IS NULL OR genre = '')
            AND track_title IS NOT NULL AND track_title != ''
            AND artist IS NOT NULL AND artist != ''
            LIMIT 500
            """
        ).fetchall()

        updated = 0
        for row in rows:
            hist_id, title, artist = row[0], row[1], row[2]
            try:
                candidates = conn.execute(
                    "SELECT item_key, title, artist, year FROM tracks WHERE artist LIKE ? LIMIT 20",
                    (f"%{artist[:20]}%",),
                ).fetchall()
                best_key = None
                best_score = 0
                best_year = None
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
                        (genre, best_year, decade, hist_id),
                    )
                    updated += 1
            except Exception as row_exc:
                logger.debug("Enrich row %d failed: %s", hist_id, row_exc)

        conn.commit()
        return {"status": "ok", "rows_checked": len(rows), "rows_updated": updated}
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Roon Tags endpoint
# ---------------------------------------------------------------------------


@router.get("/roon/tags")
async def get_roon_tags() -> list[dict]:
    """Return all user-created Roon Tags via the Browse API."""
    from backend.roon_client import get_roon_client  # noqa: PLC0415

    roon_client = get_roon_client()
    if not roon_client or not roon_client.is_connected():
        raise HTTPException(status_code=503, detail="Roon not connected")

    tags = await asyncio.to_thread(roon_client.get_tags)
    return tags
