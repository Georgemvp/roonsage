"""Circadian Auto-Playlists (v13.6).

Generates 3 LLM-curated playlists per day — morning / afternoon / evening —
biased by the user's taste profile listening_patterns. Distinct from the
existing ``audio_features.circadian`` module (which builds an hourly playlist
on demand from the audio-feature profile).

Flow:
  1. Background scheduler calls :func:`run_daily_circadian` once per day at
     the configured schedule_hour (default 06:00 local).
  2. For each time block, the local LLM (Ollama / custom) generates a short
     curation prompt that reflects the user's typical listening at that hour.
     If no local LLM is available we fall back to a heuristic prompt built
     from the taste profile.
  3. That prompt is run through the main playlist generator (which uses the
     configured main provider — gemini / anthropic / openai by default).
  4. Each playlist is saved via results.py and recorded in
     ``circadian_playlists`` so the UI can display today's set.
  5. The morning playlist is optionally queued to a configured zone.

The prompt builder calls the LLM directly (no shared semaphore) since this
runs at most 3× per day and must not be throttled by continuous trickle tasks.
"""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import date, datetime
from typing import Any

from backend.db import get_db_connection
from backend.llm_client import get_llm_client
from backend.taste_profile import TasteProfile, build_profile_summary

logger = logging.getLogger(__name__)

_run_lock = asyncio.Lock()

TIME_BLOCKS: tuple[tuple[str, str, range], ...] = (
    ("morning",   "06:00–11:00", range(6, 12)),
    ("afternoon", "12:00–17:00", range(12, 18)),
    ("evening",   "18:00–23:00", range(18, 24)),
)

# Context keywords matched against track_vibes.contexts to build a
# time-appropriate pool (OR-union with the genre filter).
BLOCK_VIBE_CONTEXTS: dict[str, list[str]] = {
    "morning":   ["morning", "commute", "energizing", "wake", "workout", "coffee", "focus"],
    "afternoon": ["afternoon", "work", "focus", "drive", "productive", "lunch"],
    "evening":   ["evening", "dinner", "late night", "wind-down", "relax", "night", "chill"],
}

# Mood keywords matched against track_vibes.moods (OR-union).
BLOCK_VIBE_MOODS: dict[str, list[str]] = {
    "morning":   ["energetic", "uplifting", "positive", "bright", "motivating"],
    "afternoon": ["focused", "steady", "confident", "driving"],
    "evening":   ["relaxed", "mellow", "warm", "introspective", "dreamy"],
}


PROMPT_BUILDER_SYSTEM = """You design playlist curation prompts.

You receive:
1. A time block (morning, afternoon or evening) and its hour range
2. The user's listening profile — top genres, favourite artists, recently
   active artists, moods, dislikes, and the genres they actually play at
   this time of day
3. The current day of the week

Write ONE short curation prompt (2-3 sentences, max 280 chars) that a
playlist-generation AI will use to pick ~25 tracks from the user's library
for this exact time block. The prompt must:
- Describe the desired sonic character for the time of day (energy curve,
  mood, density)
- Name 2-4 anchor genres or artists the user actually listens to at this
  hour (use the lb_genre_by_hour / morning_genres / evening_genres fields)
- Avoid anything in the dislikes list

Return ONLY valid JSON:
{"prompt": "..."}"""


def _hours_for_block(block: str) -> range:
    for name, _label, hours in TIME_BLOCKS:
        if name == block:
            return hours
    return range(0, 24)


def _get_block_genres(block: str, profile: dict, top_n: int = 5) -> list[str]:
    """Top genres the user plays during this time block, from ListenBrainz data."""
    hours = _hours_for_block(block)
    lb_by_hour: dict = profile.get("lb_genre_by_hour") or {}
    hour_genres: dict[str, int] = {}
    for h in hours:
        for entry in lb_by_hour.get(h, []) or lb_by_hour.get(str(h), []) or []:
            g = (entry.get("genre") or "").strip()
            if g:
                hour_genres[g] = hour_genres.get(g, 0) + int(entry.get("listen_count", 1))
    if not hour_genres:
        patterns = profile.get("listening_patterns") or {}
        if block == "morning":
            hour_genres = {g: 1 for g in patterns.get("morning_genres", [])}
        elif block == "evening":
            hour_genres = {g: 1 for g in patterns.get("evening_genres", [])}
    top = [g for g, _ in sorted(hour_genres.items(), key=lambda x: -x[1])][:top_n]
    if not top:
        top = list((profile.get("genres") or {}).keys())[:top_n]
    return top


def _heuristic_prompt(block: str, profile: dict) -> str:
    """Build a curation prompt without an LLM, using only the taste profile."""
    top_genres = _get_block_genres(block, profile, top_n=4)
    recent = (profile.get("recently_active") or {}).get("top_artists") or []
    anchor_artists = ", ".join(recent[:3]) if recent else ""

    descriptor = {
        "morning":   "Bright, focused, mid-energy music to ease into the day",
        "afternoon": "Steady, engaging music for sustained focus and movement",
        "evening":   "Warmer, deeper, lower-tempo music for winding down",
    }[block]

    parts = [descriptor + "."]
    if top_genres:
        parts.append(f"Favor: {', '.join(top_genres)}.")
    if anchor_artists:
        parts.append(f"Anchor around recently active artists like {anchor_artists}.")

    dislikes = profile.get("dislikes") or []
    if dislikes:
        parts.append(f"Avoid: {', '.join(dislikes[:3])}.")

    return " ".join(parts)[:280]


async def _build_block_prompt(block: str, label: str, profile: dict) -> str:
    """Ask the local LLM for a curation prompt; fall back to heuristic on failure."""
    client = get_llm_client()
    if client is None or client.provider not in ("ollama", "custom"):
        return _heuristic_prompt(block, profile)

    summary = build_profile_summary(profile=profile, mode="full") or ""
    hours = _hours_for_block(block)
    lb_by_hour: dict = profile.get("lb_genre_by_hour") or {}
    hour_genre_counts: dict[str, int] = {}
    for h in hours:
        for entry in lb_by_hour.get(h, []) or lb_by_hour.get(str(h), []) or []:
            g = (entry.get("genre") or "").strip()
            if g:
                hour_genre_counts[g] = hour_genre_counts.get(g, 0) + int(entry.get("listen_count", 1))
    this_hour_summary = ", ".join(
        f"{g} ({c})" for g, c in sorted(hour_genre_counts.items(), key=lambda x: -x[1])[:8]
    ) or "(no logged plays in this window yet)"

    today_name = datetime.now().strftime("%A")
    prompt = (
        f"Time block: {block} ({label}) on {today_name}.\n\n"
        f"Genres this user plays in this window: {this_hour_summary}\n\n"
        f"{summary}"
    )

    try:
        resp = await client.generate_fast(prompt, PROMPT_BUILDER_SYSTEM)
        parsed = client.parse_json_response(resp)
        if isinstance(parsed, dict) and isinstance(parsed.get("prompt"), str):
            text = parsed["prompt"].strip()
            if text:
                return text[:600]
    except Exception as exc:
        logger.warning("circadian prompt builder LLM failed (%s) — using heuristic", exc)

    return _heuristic_prompt(block, profile)


async def _consume_stream_async(
    prompt: str,
    track_count: int,
    max_tracks_to_ai: int = 150,
    genres: list[str] | None = None,
    vibe_contexts: list[str] | None = None,
    vibe_moods: list[str] | None = None,
    lastfm_tags: list[str] | None = None,
) -> dict:
    """Consume the SSE playlist generator directly in the current event loop."""
    from backend.generator import generate_playlist_stream  # noqa: PLC0415

    tracks: list = []
    playlist_title = ""
    narrative = ""
    track_reasons: dict = {}
    result_id: str | None = None

    async for chunk in generate_playlist_stream(
        prompt=prompt,
        track_count=track_count,
        genres=genres,
        vibe_contexts=vibe_contexts,
        vibe_moods=vibe_moods,
        lastfm_tags=lastfm_tags,
        max_tracks_to_ai=max_tracks_to_ai,
        exclude_live=True,
        source_mode="library",
        use_taste_profile=True,
        is_background=True,
        auto_analyze=False,
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
                narrative = payload.get("narrative") or narrative
                track_reasons = payload.get("track_reasons") or track_reasons
                if payload.get("result_id"):
                    result_id = payload["result_id"]
            elif payload.get("step") == "complete" and payload.get("result_id"):
                result_id = payload["result_id"]

    return {
        "tracks": tracks,
        "playlist_title": playlist_title,
        "narrative": narrative,
        "track_reasons": track_reasons,
        "result_id": result_id,
    }


async def generate_block(block: str, label: str, track_count: int = 25) -> dict[str, Any]:
    """Generate (and persist) a single time-block playlist. Returns metadata."""
    from backend.analyzer import analyze_prompt as do_analyze  # noqa: PLC0415
    from backend.tracks import count_tracks_by_filters  # noqa: PLC0415

    profile = TasteProfile.get()
    genres = _get_block_genres(block, profile)
    vibe_contexts = list(BLOCK_VIBE_CONTEXTS.get(block) or [])
    vibe_moods = list(BLOCK_VIBE_MOODS.get(block) or [])

    if genres:
        pool_size = count_tracks_by_filters(genres=genres, exclude_live=True)
        if pool_size < 50:
            logger.info("Circadian %s: genre pool too small (%d tracks), using vibe-context only", block, pool_size)
            genres = None
        else:
            logger.info("Circadian %s: genre+vibe pool — genres=%s vibe_contexts=%s (%d genre tracks)", block, genres, vibe_contexts, pool_size)
    else:
        logger.info("Circadian %s: no genre data, using vibe-context pool — %s", block, vibe_contexts)

    prompt = await _build_block_prompt(block, label, profile)
    # Anchor the curation prompt to the pool's actual genres so the AI doesn't
    # search for genres that aren't in the filtered track list.
    if genres:
        prompt = f"{prompt} Draw from: {', '.join(genres[:4])}."
    logger.info("Circadian %s prompt: %s", block, prompt)

    # Analyze the final prompt to extract Last.fm tags and enrich vibe signals.
    lastfm_tags: list[str] | None = None
    try:
        analysis = await do_analyze(prompt, use_taste_profile=True)
        if analysis.suggested_lastfm_tags:
            lastfm_tags = analysis.suggested_lastfm_tags
        # Merge any additional vibe signals the analyzer found with the block defaults.
        if analysis.suggested_vibe_contexts:
            seen = set(vibe_contexts)
            vibe_contexts += [c for c in analysis.suggested_vibe_contexts if c not in seen]
        if analysis.suggested_vibe_moods:
            seen = set(vibe_moods)
            vibe_moods += [m for m in analysis.suggested_vibe_moods if m not in seen]
        logger.info(
            "Circadian %s analyze: lastfm=%s extra_contexts=%s extra_moods=%s",
            block, lastfm_tags,
            analysis.suggested_vibe_contexts, analysis.suggested_vibe_moods,
        )
    except Exception as exc:
        logger.warning("Circadian %s: analyze_prompt failed (%s), continuing without lastfm_tags", block, exc)

    data = await _consume_stream_async(
        prompt, track_count,
        max_tracks_to_ai=75,
        genres=genres,
        vibe_contexts=vibe_contexts or None,
        vibe_moods=vibe_moods or None,
        lastfm_tags=lastfm_tags,
    )
    if not data.get("tracks"):
        raise RuntimeError(f"Circadian {block} produced no tracks")

    today = date.today().isoformat()
    conn = get_db_connection()
    try:
        conn.execute(
            """
            INSERT OR REPLACE INTO circadian_playlists
                (date, time_block, prompt_used, result_id, created_at)
            VALUES (?, ?, ?, ?, datetime('now'))
            """,
            (today, block, prompt, data.get("result_id")),
        )
        conn.commit()
    finally:
        conn.close()

    return {
        "date": today,
        "time_block": block,
        "prompt": prompt,
        "result_id": data.get("result_id"),
        "track_count": len(data.get("tracks", [])),
        "playlist_title": data.get("playlist_title"),
    }


async def run_daily_circadian(
    queue_morning_to_zone: str | None = None,
    track_count: int = 25,
    skip_existing: bool = False,
) -> list[dict[str, Any]]:
    """Generate today's morning + afternoon + evening playlists.

    When ``queue_morning_to_zone`` is set and a matching Roon zone is
    found, the morning playlist is queued to it (replace mode).
    When ``skip_existing`` is True, blocks already saved for today are skipped.
    """
    if _run_lock.locked():
        logger.info("Circadian: generation already in progress, skipping")
        return []
    async with _run_lock:
        return await _run_daily_circadian(queue_morning_to_zone, track_count, skip_existing)


async def _run_daily_circadian(
    queue_morning_to_zone: str | None = None,
    track_count: int = 25,
    skip_existing: bool = False,
) -> list[dict[str, Any]]:
    existing_blocks: set[str] = set()
    if skip_existing:
        existing_blocks = {r["time_block"] for r in get_today_circadian()["playlists"]}

    out: list[dict[str, Any]] = []
    for block, label, _hours in TIME_BLOCKS:
        if block in existing_blocks:
            logger.info("Circadian %s already done for today, skipping", block)
            continue
        try:
            meta = await generate_block(block, label, track_count=track_count)
            out.append(meta)
        except Exception as exc:
            logger.warning("Circadian %s failed: %s", block, exc)
            out.append({"time_block": block, "error": str(exc)})
        await asyncio.sleep(1.0)

    if queue_morning_to_zone:
        await _queue_morning(out, queue_morning_to_zone)

    return out


async def _queue_morning(results: list[dict], zone_name: str) -> None:
    """Best-effort: queue the morning playlist to the configured zone."""
    morning = next((r for r in results if r.get("time_block") == "morning"), None)
    if not morning or not morning.get("result_id"):
        return

    from backend.results import get_result  # noqa: PLC0415
    from backend.roon_client import get_roon_client  # noqa: PLC0415

    record = get_result(morning["result_id"])
    if not record:
        return
    tracks = (record.get("snapshot") or {}).get("tracks") or []
    item_keys = [t.get("item_key") for t in tracks if t.get("item_key")]
    if not item_keys:
        return

    roon = get_roon_client()
    if not roon or not roon.is_connected():
        logger.info("Circadian: morning playlist not queued — Roon disconnected")
        return

    zones = roon.get_zones()
    zone_id: str | None = None
    needle = zone_name.lower()
    for z in zones:
        display = (z.display_name if hasattr(z, "display_name") else z.get("display_name", "")) or ""
        if needle in display.lower():
            zone_id = z.zone_id if hasattr(z, "zone_id") else z.get("zone_id")
            break
    if not zone_id:
        logger.info("Circadian: zone %r not found", zone_name)
        return

    try:
        await asyncio.to_thread(roon.play_tracks, zone_id, item_keys, "replace")
        conn = get_db_connection()
        try:
            conn.execute(
                "UPDATE circadian_playlists SET queued_to_zone = ? "
                "WHERE date = ? AND time_block = 'morning'",
                (zone_name, date.today().isoformat()),
            )
            conn.commit()
        finally:
            conn.close()
        logger.info("Circadian morning playlist queued to zone %r", zone_name)
    except Exception as exc:
        logger.warning("Circadian morning queue failed: %s", exc)


def get_today_circadian() -> dict[str, Any]:
    """Return today's generated circadian playlists (joined with results)."""
    today = date.today().isoformat()
    conn = get_db_connection()
    try:
        rows = conn.execute(
            """
            SELECT cp.date, cp.time_block, cp.prompt_used, cp.result_id,
                   cp.queued_to_zone, cp.created_at,
                   r.title AS playlist_title, r.track_count, r.art_item_key
              FROM circadian_playlists cp
         LEFT JOIN results r ON r.id = cp.result_id
             WHERE cp.date = ?
             ORDER BY CASE cp.time_block
                        WHEN 'morning' THEN 1
                        WHEN 'afternoon' THEN 2
                        WHEN 'evening' THEN 3
                        ELSE 4
                      END
            """,
            (today,),
        ).fetchall()
        playlists = [dict(r) for r in rows]
    finally:
        conn.close()
    return {"date": today, "playlists": playlists}


def get_recent_circadian(days: int = 7) -> list[dict[str, Any]]:
    """Return the last *days* of circadian playlists for history view."""
    conn = get_db_connection()
    try:
        rows = conn.execute(
            """
            SELECT cp.date, cp.time_block, cp.prompt_used, cp.result_id,
                   cp.queued_to_zone, cp.created_at,
                   r.title AS playlist_title, r.track_count
              FROM circadian_playlists cp
         LEFT JOIN results r ON r.id = cp.result_id
             WHERE cp.date >= date('now', ?)
             ORDER BY cp.date DESC, cp.time_block
            """,
            (f"-{int(days)} days",),
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()
