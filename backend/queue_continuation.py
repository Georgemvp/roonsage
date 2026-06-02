"""Smart Queue Continuation (v13.6).

Automatically extend a Roon zone's queue when it is about to end, using
audio-feature context from the last 8-10 played tracks.

Flow:
  1. ``roon_intelligence`` calls :func:`handle_queue_ending` whenever a
     zone's remaining queue drops below the threshold (or empties).
  2. We collect the most recent listens (skipping skips) for that zone
     from ``listening_history`` and compute the average BPM, energy,
     valence, danceability and the Camelot keys.
  3. The local LLM (Ollama / custom) writes a short continuation prompt
     describing the sonic trajectory. If unavailable we fall back to a
     deterministic prompt built from the feature averages.
  4. The main generator picks ~12 tracks. We pre-filter the candidate
     pool by BPM window + compatible Camelot keys via
     ``filter_tracks_by_audio`` so the LLM only sees sonically-adjacent
     candidates.
  5. The new tracks are appended (NOT replace) to the same zone.

Cooldown protection: each zone fires at most once per
``smart_continuation.cooldown_seconds`` (default 30 minutes).
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections import Counter
from datetime import UTC, datetime, timedelta
from typing import Any

from backend.background_ai import _get_semaphore
from backend.config import get_queue_continuation_config
from backend.db import get_db_connection
from backend.llm_client import get_llm_client

logger = logging.getLogger(__name__)

CONTINUATION_PROMPT_SYSTEM = """You write a one-paragraph continuation prompt for a music curator.

You receive:
1. The last 8-10 tracks the listener actually completed (artist + title + features)
2. Average BPM, energy, valence, danceability across those tracks
3. The dominant Camelot keys (e.g. 8A, 5B)
4. Zone name and current local time

Write 2-3 sentences (max 300 chars) that describe the sonic trajectory the
listener has been on and instruct the curator to "continue this mood".
Mention specifics: average tempo, energy level, mood, and 1-2 anchor
genres or artists from the listening context. Avoid generic music-blog
phrases.

Return ONLY valid JSON:
{"prompt": "..."}"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CAMELOT_WHEEL: list[str] = [
    "1A", "2A", "3A", "4A", "5A", "6A", "7A", "8A", "9A", "10A", "11A", "12A",
    "1B", "2B", "3B", "4B", "5B", "6B", "7B", "8B", "9B", "10B", "11B", "12B",
]


def _compatible_camelot(keys: list[str]) -> list[str]:
    """Expand a set of Camelot codes to harmonically compatible neighbours."""
    compat: set[str] = set()
    for key in keys:
        if not key or len(key) < 2:
            continue
        try:
            number = int(key[:-1])
            letter = key[-1].upper()
        except ValueError:
            continue
        if letter not in ("A", "B"):
            continue
        twin = "B" if letter == "A" else "A"
        compat.add(f"{number}{letter}")
        compat.add(f"{number}{twin}")
        compat.add(f"{((number) % 12) + 1}{letter}")
        compat.add(f"{((number - 2) % 12) + 1}{letter}")
    return sorted(compat)


def _gather_recent_context(zone_name: str | None, n: int = 10) -> dict[str, Any]:
    """Pull the last *n* completed listens for *zone_name* (or globally) +
    their audio features when available.
    """
    conn = get_db_connection()
    try:
        if zone_name:
            rows = conn.execute(
                """
                SELECT lh.track_title, lh.artist, lh.album, lh.genre,
                       lh.timestamp, lh.played_seconds, lh.duration_seconds,
                       lh.zone_name
                  FROM listening_history lh
                 WHERE lh.zone_name = ?
                   AND lh.skipped = 0
                   AND lh.played_seconds >= 20
                 ORDER BY lh.id DESC
                 LIMIT ?
                """,
                (zone_name, int(n)),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT lh.track_title, lh.artist, lh.album, lh.genre,
                       lh.timestamp, lh.played_seconds, lh.duration_seconds,
                       lh.zone_name
                  FROM listening_history lh
                 WHERE lh.skipped = 0
                   AND lh.played_seconds >= 20
                 ORDER BY lh.id DESC
                 LIMIT ?
                """,
                (int(n),),
            ).fetchall()

        listens = [dict(r) for r in rows]
        if not listens:
            return {"listens": [], "features": {}, "camelot_keys": [], "genres": []}

        # Batch-fetch audio features for all listens in one query to avoid N+1
        titles_lower = list({
            listen["track_title"].lower()
            for listen in listens
            if listen.get("track_title") and listen.get("artist")
        })
        feature_rows: list[dict] = []
        if titles_lower:
            placeholders = ",".join("?" * len(titles_lower))
            feat_rows = conn.execute(
                f"""
                SELECT t.item_key,
                       LOWER(t.title) AS title_lower,
                       LOWER(t.artist) AS artist_lower,
                       taf.bpm, taf.energy, taf.valence,
                       taf.danceability, taf.camelot, taf.acousticness
                  FROM tracks t
             LEFT JOIN track_audio_features taf ON taf.item_key = t.item_key
                 WHERE LOWER(t.title) IN ({placeholders})
                """,
                titles_lower,
            ).fetchall()
            by_title: dict[str, list[dict]] = {}
            for r in feat_rows:
                by_title.setdefault(r["title_lower"], []).append(dict(r))
            for listen in listens:
                title_l = (listen.get("track_title") or "").lower()
                artist_l = (listen.get("artist") or "").lower()
                if not title_l or not artist_l:
                    continue
                for candidate in by_title.get(title_l, []):
                    if artist_l in (candidate.get("artist_lower") or ""):
                        feature_rows.append(candidate)
                        break

        bpms = [r["bpm"] for r in feature_rows if r.get("bpm")]
        energies = [r["energy"] for r in feature_rows if r.get("energy") is not None]
        valences = [r["valence"] for r in feature_rows if r.get("valence") is not None]
        dances = [r["danceability"] for r in feature_rows if r.get("danceability") is not None]
        keys = [r["camelot"] for r in feature_rows if r.get("camelot")]
        genres = [g for r in listens for g in (r.get("genre") or "").split(",") if g.strip()]

        return {
            "listens": listens,
            "features": {
                "bpm": round(sum(bpms) / len(bpms), 1) if bpms else None,
                "energy": round(sum(energies) / len(energies), 3) if energies else None,
                "valence": round(sum(valences) / len(valences), 3) if valences else None,
                "danceability": round(sum(dances) / len(dances), 3) if dances else None,
                "n_with_features": len(feature_rows),
            },
            "camelot_keys": [k for k, _ in Counter(keys).most_common(3)],
            "genres": [g for g, _ in Counter(g.strip() for g in genres).most_common(3)],
        }
    finally:
        conn.close()


def _heuristic_prompt(context: dict, zone_name: str | None) -> str:
    feats = context.get("features") or {}
    bpm = feats.get("bpm")
    energy = feats.get("energy")
    valence = feats.get("valence")
    genres = context.get("genres") or []
    artists = []
    for listen in context.get("listens", [])[:6]:
        a = listen.get("artist")
        if a and a not in artists:
            artists.append(a)

    bits: list[str] = []
    if bpm:
        bits.append(f"around {round(bpm)} BPM")
    if energy is not None:
        if energy >= 0.7:
            bits.append("high energy")
        elif energy >= 0.4:
            bits.append("moderate energy")
        else:
            bits.append("low energy")
    if valence is not None:
        bits.append("uplifting" if valence >= 0.6 else ("darker" if valence < 0.35 else "balanced"))

    descriptor = ", ".join(bits) if bits else "matching the current mood"
    parts = [f"The listener has been enjoying {descriptor} music"]
    if genres:
        parts[-1] += f" (mostly {', '.join(genres[:3])})"
    parts[-1] += "."

    if artists:
        parts.append(f"Recently played: {', '.join(artists[:4])}.")

    parts.append("Continue this mood with 10-15 sonically-adjacent tracks — keep the energy and tempo close, avoid jarring transitions.")
    text = " ".join(parts)
    return text[:600]


async def _build_continuation_prompt(context: dict, zone_name: str | None) -> str:
    client = get_llm_client()
    if client is None or client.provider not in ("ollama", "custom"):
        return _heuristic_prompt(context, zone_name)

    feats = context.get("features") or {}
    listens = context.get("listens") or []
    listen_lines = "\n".join(
        f"  {i+1}. {x.get('artist','?')} — {x.get('title') or x.get('track_title','?')}"
        for i, x in enumerate(listens[:8])
    ) or "  (no recent context)"

    now = datetime.now().strftime("%A %H:%M")
    prompt = (
        f"Zone: {zone_name or 'unknown'} ({now})\n\n"
        f"Recent tracks:\n{listen_lines}\n\n"
        f"Averages: BPM={feats.get('bpm')}, energy={feats.get('energy')}, "
        f"valence={feats.get('valence')}, danceability={feats.get('danceability')}\n"
        f"Dominant Camelot keys: {', '.join(context.get('camelot_keys') or []) or 'unknown'}\n"
        f"Top genres: {', '.join(context.get('genres') or []) or 'unknown'}\n"
    )

    try:
        async with _get_semaphore():
            resp = await client.generate_fast(prompt, CONTINUATION_PROMPT_SYSTEM)
        parsed = client.parse_json_response(resp)
        if isinstance(parsed, dict) and isinstance(parsed.get("prompt"), str):
            return parsed["prompt"].strip()[:600]
    except Exception as exc:
        logger.warning("Continuation LLM failed (%s) — using heuristic", exc)

    return _heuristic_prompt(context, zone_name)


def _consume_stream(prompt: str, track_count: int, candidate_keys: list[str] | None) -> dict:
    """Run the generator and collect the final result.

    When ``candidate_keys`` is provided we constrain the library pool via
    a tiny shim around library_cache.get_tracks_by_filters by intersecting
    the pulled tracks against the candidate set.
    """
    from backend.generator import generate_playlist_stream  # noqa: PLC0415

    async def _run() -> dict:
        tracks: list = []
        playlist_title = ""
        result_id: str | None = None
        async for chunk in generate_playlist_stream(
            prompt=prompt,
            track_count=track_count,
            exclude_live=True,
            source_mode="library",
            use_taste_profile=True,
        ):
            for line in chunk.splitlines():
                line = line.strip()
                if not line.startswith("data:"):
                    continue
                try:
                    payload = json.loads(line[5:].strip())
                except Exception:
                    continue
                if not isinstance(payload, dict):
                    continue
                if "batch" in payload:
                    tracks.extend(payload["batch"])
                elif "playlist_title" in payload:
                    playlist_title = payload.get("playlist_title") or playlist_title
                    if payload.get("result_id"):
                        result_id = payload["result_id"]
                elif payload.get("step") == "complete" and payload.get("result_id"):
                    result_id = payload["result_id"]
        if candidate_keys:
            wanted = set(candidate_keys)
            filtered = [t for t in tracks if t.get("item_key") in wanted]
            if len(filtered) >= max(3, track_count // 2):
                tracks = filtered
        return {
            "tracks": tracks,
            "playlist_title": playlist_title,
            "result_id": result_id,
        }

    return asyncio.run(_run())


def _candidate_pool(context: dict, bpm_window: int = 10) -> list[str]:
    """Pre-filter the library by BPM ± window + compatible Camelot keys."""
    feats = context.get("features") or {}
    bpm = feats.get("bpm")
    keys = context.get("camelot_keys") or []
    if not bpm and not keys:
        return []

    compat = _compatible_camelot(keys) if keys else []
    conn = get_db_connection()
    try:
        if bpm and compat:
            placeholders = ",".join("?" * len(compat))
            rows = conn.execute(
                f"""
                SELECT taf.item_key
                  FROM track_audio_features taf
                 WHERE taf.bpm BETWEEN ? AND ?
                   AND taf.camelot IN ({placeholders})
                 LIMIT 1500
                """,
                (bpm - bpm_window, bpm + bpm_window, *compat),
            ).fetchall()
        elif bpm:
            rows = conn.execute(
                """
                SELECT taf.item_key
                  FROM track_audio_features taf
                 WHERE taf.bpm BETWEEN ? AND ?
                 LIMIT 1500
                """,
                (bpm - bpm_window, bpm + bpm_window),
            ).fetchall()
        elif compat:
            placeholders = ",".join("?" * len(compat))
            rows = conn.execute(
                f"SELECT taf.item_key FROM track_audio_features taf "
                f"WHERE taf.camelot IN ({placeholders}) LIMIT 1500",
                compat,
            ).fetchall()
        else:
            rows = []
        return [r["item_key"] for r in rows]
    finally:
        conn.close()


def _record_run(
    zone_id: str,
    zone_name: str | None,
    result_id: str | None,
    track_count: int,
    status: str,
    error: str | None,
) -> None:
    conn = get_db_connection()
    try:
        conn.execute(
            """
            INSERT OR REPLACE INTO queue_continuation_log
                (zone_id, zone_name, last_fired_at, last_result_id,
                 last_track_count, last_status, last_error)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                zone_id,
                zone_name,
                datetime.now(UTC).isoformat(),
                result_id,
                track_count,
                status,
                error,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def _last_fired(zone_id: str) -> datetime | None:
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT last_fired_at FROM queue_continuation_log WHERE zone_id = ?",
            (zone_id,),
        ).fetchone()
        if not row:
            return None
        try:
            return datetime.fromisoformat(row["last_fired_at"].replace("Z", "+00:00"))
        except Exception:
            return None
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def trigger_continuation(
    zone_id: str,
    zone_name: str | None = None,
    track_count: int | None = None,
    bpm_window: int | None = None,
    skip_cooldown: bool = False,
) -> dict[str, Any]:
    """Generate and append a continuation queue for *zone_id*.

    Returns a dict with ``status`` ('queued', 'skipped', 'no_context', ...)
    and metadata about what was added. Safe to await from the event loop
    or call via ``asyncio.run_coroutine_threadsafe``.
    """
    cfg = get_queue_continuation_config()
    if not cfg["enabled"]:
        return {"status": "skipped", "reason": "smart_continuation disabled"}

    track_count = int(track_count or cfg["track_count"])
    bpm_window = int(bpm_window or cfg["bpm_window"])

    if not skip_cooldown:
        last = _last_fired(zone_id)
        if last:
            elapsed = (datetime.now(UTC) - last).total_seconds()
            if elapsed < cfg["cooldown_seconds"]:
                return {
                    "status": "skipped",
                    "reason": f"cooldown ({int(cfg['cooldown_seconds'] - elapsed)}s remaining)",
                }

    context = _gather_recent_context(zone_name)
    if not context["listens"]:
        return {"status": "no_context", "reason": "no recent listens for this zone"}

    prompt = await _build_continuation_prompt(context, zone_name)
    candidate_keys = _candidate_pool(context, bpm_window=bpm_window)
    logger.info(
        "Smart continuation zone=%s tracks=%d candidates=%d",
        zone_name, track_count, len(candidate_keys),
    )

    try:
        data = await asyncio.to_thread(
            _consume_stream, prompt, track_count, candidate_keys
        )
    except Exception as exc:
        _record_run(zone_id, zone_name, None, 0, "failed", str(exc))
        return {"status": "failed", "error": str(exc)}

    tracks = data.get("tracks") or []
    if not tracks:
        _record_run(zone_id, zone_name, None, 0, "empty", "generator returned no tracks")
        return {"status": "empty"}

    item_keys = [t.get("item_key") for t in tracks if t.get("item_key")]
    if not item_keys:
        _record_run(zone_id, zone_name, None, 0, "empty", "no item_keys")
        return {"status": "empty"}

    from backend.roon_client import get_roon_client  # noqa: PLC0415
    roon = get_roon_client()
    if not roon or not roon.is_connected():
        _record_run(zone_id, zone_name, data.get("result_id"), len(item_keys), "no_roon", "Roon disconnected")
        return {"status": "no_roon"}

    try:
        await asyncio.to_thread(roon.play_tracks, zone_id, item_keys, "queue")
    except Exception as exc:
        _record_run(zone_id, zone_name, data.get("result_id"), len(item_keys), "failed", str(exc))
        return {"status": "failed", "error": str(exc)}

    _record_run(
        zone_id, zone_name, data.get("result_id"), len(item_keys), "queued", None
    )
    return {
        "status": "queued",
        "zone_id": zone_id,
        "zone_name": zone_name,
        "track_count": len(item_keys),
        "result_id": data.get("result_id"),
        "playlist_title": data.get("playlist_title"),
        "prompt": prompt,
    }


def get_recent_runs(limit: int = 20) -> list[dict[str, Any]]:
    """Return the recent continuation log entries for UI display."""
    conn = get_db_connection()
    try:
        rows = conn.execute(
            """SELECT zone_id, zone_name, last_fired_at, last_result_id,
                      last_track_count, last_status, last_error
                 FROM queue_continuation_log
                ORDER BY last_fired_at DESC
                LIMIT ?""",
            (int(limit),),
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def is_zone_allowed(zone_name: str | None) -> bool:
    """True when the configured zone-list is empty (= all zones) or matches."""
    if not zone_name:
        return True
    cfg = get_queue_continuation_config()
    zones = cfg.get("zones") or []
    if not zones:
        return True
    needle = zone_name.lower()
    return any(needle == z.lower() or needle in z.lower() for z in zones)


# ---------------------------------------------------------------------------
# Stateful per-zone observer — called from roon_intelligence when a zone's
# remaining queue drops below the threshold or empties.
# ---------------------------------------------------------------------------

_FIRED_FOR_QUEUE_TOKEN: dict[str, str] = {}


def _queue_token(now_playing: dict | None) -> str:
    """Stable identifier for the current queue position — used to ensure we
    don't fire twice for the same 'last track' state."""
    if not now_playing:
        return ""
    three = now_playing.get("three_line") or {}
    return f"{three.get('line1','')}|{three.get('line2','')}"


async def maybe_fire_continuation(
    zone_id: str,
    zone_name: str | None,
    remaining_in_queue: int,
    now_playing: dict | None,
) -> None:
    """Fire continuation if conditions are met.

    Called from the zone monitor whenever queue depth changes. Idempotent —
    a given (zone, queue-position) only triggers once.
    """
    if remaining_in_queue > 1:
        return

    if not is_zone_allowed(zone_name):
        return

    token = f"{zone_id}::{_queue_token(now_playing)}"
    if _FIRED_FOR_QUEUE_TOKEN.get(zone_id) == token:
        return
    _FIRED_FOR_QUEUE_TOKEN[zone_id] = token

    # Trim the dict so it can't grow forever
    if len(_FIRED_FOR_QUEUE_TOKEN) > 64:
        for k in list(_FIRED_FOR_QUEUE_TOKEN.keys())[:32]:
            _FIRED_FOR_QUEUE_TOKEN.pop(k, None)

    try:
        result = await trigger_continuation(zone_id, zone_name)
        logger.info("Smart continuation fired for %s -> %s", zone_name, result.get("status"))
    except Exception as exc:
        logger.warning("Smart continuation crash for %s: %s", zone_name, exc)


def reset_for_zone(zone_id: str) -> None:
    """Clear the dedupe token for a zone — call when user manually changes queue."""
    _FIRED_FOR_QUEUE_TOKEN.pop(zone_id, None)


def get_last_fired_iso(zone_id: str) -> str | None:
    dt = _last_fired(zone_id)
    return dt.isoformat() if dt else None


def force_expire_cooldown(zone_id: str) -> None:
    """Test/admin helper: pretend the cooldown has long since elapsed."""
    conn = get_db_connection()
    try:
        conn.execute(
            "UPDATE queue_continuation_log SET last_fired_at = ? WHERE zone_id = ?",
            ((datetime.now(UTC) - timedelta(days=1)).isoformat(), zone_id),
        )
        conn.commit()
    finally:
        conn.close()
