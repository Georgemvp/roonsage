"""Listening Session Summaries (v13.6) — automatic music journal.

Session detection:
  A session starts when a zone begins playback and ends when there's a gap
  of more than ``gap_minutes`` (default 30) with no playback in any zone.

Detection lives in :func:`detect_sessions` — it runs periodically as a
background task. New sessions are inserted with summarized=0 and then a
separate background task (:func:`summarize_pending_sessions`) picks them up,
generates a 2-3 sentence LLM summary, and marks them complete.

The summarizer runs through the shared background-AI semaphore so it doesn't
contend with vibe tagging.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections import Counter
from datetime import UTC, datetime, timedelta
from typing import Any

from backend.background_ai import _get_semaphore
from backend.config import get_session_summary_config
from backend.db import get_db_connection
from backend.llm_client import get_llm_client, is_background_ai_enabled
from backend.taste_profile import build_profile_summary

logger = logging.getLogger(__name__)


SESSION_SUMMARY_SYSTEM = """Summarize a listening session for a music journal.

You receive:
1. Session metadata (date, duration, zone, track count)
2. The tracks played, in order (artist, title, album, genre)
3. Audio-feature summary (avg BPM, energy trend) if available
4. The listener's taste profile summary (for "compares to your typical
   listening" context)

Write a JSON object with:
- summary: 2-3 sentences, max 400 chars. Mention the genres covered, the
  mood arc (built? wound down? consistent?), 1-2 standout tracks, and how
  it compares to the listener's normal taste. Sound like a knowledgeable
  friend, not a music critic.
- mood_arc: ONE of "ascending" | "descending" | "steady" | "u-shaped" |
  "arch" | "volatile"
- standout_tracks: up to 3 objects of {"artist": "...", "title": "..."}

Return ONLY valid JSON:
{"summary": "...", "mood_arc": "steady", "standout_tracks": [{"artist": "...", "title": "..."}]}"""


# ---------------------------------------------------------------------------
# Session detection
# ---------------------------------------------------------------------------


def _row_to_listen(row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "ts": row["timestamp"],
        "zone": row["zone_name"],
        "title": row["track_title"],
        "artist": row["artist"],
        "album": row["album"],
        "genre": row["genre"] or "",
        "played": row["played_seconds"] or 0,
        "duration": row["duration_seconds"] or 0,
        "skipped": int(row["skipped"] or 0),
    }


def _parse_ts(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value.replace(" ", "T"))
    except Exception:
        return datetime.now(UTC).replace(tzinfo=None)


def _existing_session_window() -> datetime | None:
    """The end-time of the most recently recorded session — we never re-detect
    listens older than this. Returns None if no sessions exist."""
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT MAX(ended_at) AS m FROM listening_sessions"
        ).fetchone()
        if not row or not row["m"]:
            return None
        return _parse_ts(row["m"])
    finally:
        conn.close()


def detect_sessions(
    gap_minutes: int | None = None,
    min_tracks: int | None = None,
    delay_minutes: int | None = None,
) -> int:
    """Detect newly-completed listening sessions and insert them into DB.

    A session is "complete" only once the configured ``delay_minutes`` have
    passed since its last track (false-end detection guard). Returns the
    number of new sessions inserted.
    """
    cfg = get_session_summary_config()
    if not cfg["enabled"]:
        return 0

    gap = int(gap_minutes or cfg["gap_minutes"])
    min_n = int(min_tracks or cfg["min_tracks"])
    delay = int(delay_minutes or cfg["delay_minutes"])

    # Don't re-detect anything that already overlaps with an existing session
    window_start = _existing_session_window()
    cutoff = (datetime.now() - timedelta(minutes=delay)).replace(microsecond=0)

    conn = get_db_connection()
    try:
        params: list[Any] = []
        where_parts = ["source = 'library'"]
        if window_start:
            where_parts.append("timestamp > ?")
            params.append(window_start.isoformat(sep=" ", timespec="seconds"))
        where_parts.append("timestamp <= ?")
        params.append(cutoff.isoformat(sep=" ", timespec="seconds"))

        rows = conn.execute(
            f"""
            SELECT id, timestamp, zone_name, track_title, artist, album, genre,
                   played_seconds, duration_seconds, skipped
              FROM listening_history
             WHERE {' AND '.join(where_parts)}
             ORDER BY timestamp ASC
            """,
            params,
        ).fetchall()
        listens = [_row_to_listen(r) for r in rows]

        if not listens:
            return 0

        # Sequentially scan and split on gaps > gap_minutes
        sessions: list[list[dict]] = []
        cur: list[dict] = []
        last_ts: datetime | None = None
        for listen in listens:
            ts = _parse_ts(listen["ts"])
            if cur and last_ts and (ts - last_ts) > timedelta(minutes=gap):
                sessions.append(cur)
                cur = []
            cur.append(listen)
            last_ts = ts
        if cur:
            sessions.append(cur)

        # Only insert sessions whose final listen is at least `delay` ago.
        threshold = datetime.now() - timedelta(minutes=delay)
        inserted = 0
        for session in sessions:
            if len(session) < min_n:
                continue
            last = _parse_ts(session[-1]["ts"])
            if last > threshold:
                continue  # too recent — might still be active

            first = _parse_ts(session[0]["ts"])
            total_sec = sum(item["played"] for item in session)
            genres: list[str] = []
            for item in session:
                for g in (item["genre"] or "").split(","):
                    g = g.strip()
                    if g:
                        genres.append(g)
            top_genres = [g for g, _ in Counter(genres).most_common(5)]
            zone_counter = Counter(item["zone"] for item in session if item["zone"])
            primary_zone = zone_counter.most_common(1)[0][0] if zone_counter else None

            try:
                conn.execute(
                    """
                    INSERT INTO listening_sessions
                        (started_at, ended_at, zone_name, track_count,
                         total_duration_minutes, genres_json,
                         summary_text, mood_arc, standout_tracks_json,
                         energy_curve_json, summarized, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, '', '', '[]', '[]', 0, datetime('now'))
                    """,
                    (
                        first.isoformat(sep=" ", timespec="seconds"),
                        last.isoformat(sep=" ", timespec="seconds"),
                        primary_zone,
                        len(session),
                        round(total_sec / 60.0, 1),
                        json.dumps(top_genres, ensure_ascii=False),
                    ),
                )
                inserted += 1
            except Exception as exc:
                logger.warning("session insert failed: %s", exc)

        if inserted:
            conn.commit()
            logger.info("Detected %d new listening session(s)", inserted)
        return inserted
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Summary generation
# ---------------------------------------------------------------------------


def _session_listens(started_at: str, ended_at: str, zone_name: str | None) -> list[dict]:
    conn = get_db_connection()
    try:
        if zone_name:
            rows = conn.execute(
                """
                SELECT timestamp, track_title, artist, album, genre,
                       played_seconds, duration_seconds, skipped
                  FROM listening_history
                 WHERE timestamp >= ? AND timestamp <= ?
                   AND (zone_name = ? OR zone_name IS NULL)
                 ORDER BY timestamp ASC
                """,
                (started_at, ended_at, zone_name),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT timestamp, track_title, artist, album, genre,
                       played_seconds, duration_seconds, skipped
                  FROM listening_history
                 WHERE timestamp >= ? AND timestamp <= ?
                 ORDER BY timestamp ASC
                """,
                (started_at, ended_at),
            ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def _energy_curve(listens: list[dict]) -> list[float]:
    titles_lower = list({
        (listen.get("track_title") or "").lower()
        for listen in listens
        if listen.get("track_title") and listen.get("artist")
    })
    if not titles_lower:
        return []

    conn = get_db_connection()
    try:
        placeholders = ",".join("?" * len(titles_lower))
        rows = conn.execute(
            f"""
            SELECT LOWER(t.title) AS title_lower,
                   LOWER(t.artist) AS artist_lower,
                   taf.energy
              FROM tracks t
         LEFT JOIN track_audio_features taf ON taf.item_key = t.item_key
             WHERE LOWER(t.title) IN ({placeholders})
               AND taf.energy IS NOT NULL
            """,
            titles_lower,
        ).fetchall()
        by_title: dict[str, list[dict]] = {}
        for r in rows:
            by_title.setdefault(r["title_lower"], []).append(dict(r))

        out: list[float] = []
        for listen in listens:
            title_l = (listen.get("track_title") or "").lower()
            artist_l = (listen.get("artist") or "").lower()
            if not title_l or not artist_l:
                continue
            for candidate in by_title.get(title_l, []):
                if artist_l in (candidate.get("artist_lower") or ""):
                    out.append(round(float(candidate["energy"]), 3))
                    break
        return out
    finally:
        conn.close()


async def _llm_summarize(session: dict, listens: list[dict], curve: list[float]) -> dict | None:
    if not is_background_ai_enabled():
        return None
    client = get_llm_client()
    if client is None:
        return None

    track_lines = "\n".join(
        f"{i+1}. {item.get('artist','?')} — {item.get('track_title','?')}"
        f" ({item.get('album','?') or '—'}) [{item.get('genre','—')}]"
        for i, item in enumerate(listens[:30])
    )
    energy_note = ""
    if curve:
        first_third = curve[: max(1, len(curve) // 3)]
        last_third = curve[-max(1, len(curve) // 3):]
        avg_start = sum(first_third) / len(first_third)
        avg_end = sum(last_third) / len(last_third)
        energy_note = f"Energy: started {avg_start:.2f}, ended {avg_end:.2f}\n"

    profile_summary = build_profile_summary(mode="full") or ""

    prompt = (
        f"Session metadata:\n"
        f"  Started: {session['started_at']}\n"
        f"  Ended:   {session['ended_at']}\n"
        f"  Zone:    {session.get('zone_name') or 'mixed'}\n"
        f"  Tracks:  {session['track_count']}\n"
        f"  Duration: {session['total_duration_minutes']:.1f} min\n"
        f"  Top genres: {', '.join(session.get('genres') or [])}\n"
        f"{energy_note}\n"
        f"Tracks played:\n{track_lines}\n\n"
        f"Listener profile:\n{profile_summary}"
    )

    async with _get_semaphore():
        resp = await client.generate_fast(prompt, SESSION_SUMMARY_SYSTEM)
    parsed = client.parse_json_response(resp)
    if not isinstance(parsed, dict):
        return None
    return parsed


async def summarize_session(session_id: int) -> dict[str, Any]:
    """Generate + store a summary for a single session row."""
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT * FROM listening_sessions WHERE id = ?", (session_id,)
        ).fetchone()
        if not row:
            return {"status": "not_found", "id": session_id}
        session = dict(row)
        try:
            session["genres"] = json.loads(session.get("genres_json") or "[]")
        except Exception:
            session["genres"] = []
    finally:
        conn.close()

    listens = _session_listens(
        session["started_at"], session["ended_at"], session.get("zone_name")
    )
    curve = _energy_curve(listens)

    try:
        parsed = await _llm_summarize(session, listens, curve)
    except Exception as exc:
        logger.warning("session summary LLM failed for %d: %s", session_id, exc)
        return {"status": "failed", "id": session_id, "reason": str(exc)}
    if parsed is None:
        return {"status": "skipped", "id": session_id, "reason": "no LLM available"}

    summary = (parsed.get("summary") or "").strip()
    mood_arc = (parsed.get("mood_arc") or "").strip()
    standouts = parsed.get("standout_tracks") or []
    if not isinstance(standouts, list):
        standouts = []

    conn = get_db_connection()
    try:
        conn.execute(
            """
            UPDATE listening_sessions
               SET summary_text = ?, mood_arc = ?, standout_tracks_json = ?,
                   energy_curve_json = ?, summarized = 1
             WHERE id = ?
            """,
            (
                summary,
                mood_arc,
                json.dumps(standouts, ensure_ascii=False),
                json.dumps(curve),
                session_id,
            ),
        )
        conn.commit()
    finally:
        conn.close()

    return {
        "status": "summarized",
        "id": session_id,
        "summary": summary,
        "mood_arc": mood_arc,
        "standout_tracks": standouts,
    }


def _mark_summarize_failed(session_id: int, reason: str) -> None:
    """Mark a session as permanently failed (summarized=2) so it is not retried."""
    conn = get_db_connection()
    try:
        conn.execute(
            "UPDATE listening_sessions SET summarized = 2, summary_text = ? WHERE id = ?",
            (f"[LLM error: {reason[:200]}]", session_id),
        )
        conn.commit()
    finally:
        conn.close()


async def summarize_pending_sessions(limit: int = 5) -> int:
    """Process up to *limit* unsummarized sessions. Returns how many succeeded."""
    if not is_background_ai_enabled():
        return 0
    conn = get_db_connection()
    try:
        rows = conn.execute(
            """SELECT id FROM listening_sessions
               WHERE summarized = 0 ORDER BY ended_at DESC LIMIT ?""",
            (int(limit),),
        ).fetchall()
        ids = [r["id"] for r in rows]
    finally:
        conn.close()

    done = 0
    for sid in ids:
        try:
            result = await summarize_session(sid)
            status = result.get("status")
            if status == "summarized":
                done += 1
            elif status == "failed":
                # LLM error — mark session so it's not retried on every run
                _mark_summarize_failed(sid, result.get("reason", ""))
        except Exception as exc:
            logger.warning("summarize_session(%d) crashed: %s", sid, exc)
        # Trickle: at most 1 per minute
        await asyncio.sleep(60)
    return done


# ---------------------------------------------------------------------------
# Query helpers (used by routes)
# ---------------------------------------------------------------------------


def _row_to_dict(row) -> dict:
    d = dict(row)
    for key in ("genres_json", "standout_tracks_json", "energy_curve_json"):
        if isinstance(d.get(key), str):
            try:
                d[key.removesuffix("_json")] = json.loads(d[key])
            except Exception:
                d[key.removesuffix("_json")] = []
            d.pop(key, None)
    d["summarized"] = bool(d.get("summarized", 0))
    return d


def list_sessions(limit: int = 30, offset: int = 0) -> dict[str, Any]:
    """List recent sessions (newest first)."""
    conn = get_db_connection()
    try:
        total = conn.execute(
            "SELECT COUNT(*) AS n FROM listening_sessions"
        ).fetchone()["n"]
        rows = conn.execute(
            """SELECT * FROM listening_sessions
               ORDER BY ended_at DESC
               LIMIT ? OFFSET ?""",
            (int(limit), int(offset)),
        ).fetchall()
        return {
            "total": int(total),
            "sessions": [_row_to_dict(r) for r in rows],
        }
    finally:
        conn.close()


def get_session(session_id: int) -> dict[str, Any] | None:
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT * FROM listening_sessions WHERE id = ?", (int(session_id),)
        ).fetchone()
        if not row:
            return None
        out = _row_to_dict(row)
        out["listens"] = _session_listens(
            out["started_at"], out["ended_at"], out.get("zone_name")
        )
        return out
    finally:
        conn.close()


def session_stats() -> dict[str, Any]:
    """Aggregate stats over all stored sessions."""
    conn = get_db_connection()
    try:
        row = conn.execute(
            """
            SELECT COUNT(*) AS total,
                   AVG(total_duration_minutes) AS avg_minutes,
                   AVG(track_count) AS avg_tracks
              FROM listening_sessions
            """
        ).fetchone()

        all_genres: Counter = Counter()
        for r in conn.execute(
            "SELECT genres_json FROM listening_sessions LIMIT 500"
        ).fetchall():
            try:
                for g in json.loads(r["genres_json"] or "[]"):
                    if g:
                        all_genres[g] += 1
            except Exception:
                continue

        return {
            "total_sessions": int(row["total"] or 0),
            "avg_duration_minutes": round(row["avg_minutes"] or 0, 1),
            "avg_tracks": round(row["avg_tracks"] or 0, 1),
            "top_genres": [
                {"genre": g, "session_count": n}
                for g, n in all_genres.most_common(10)
            ],
        }
    finally:
        conn.close()
