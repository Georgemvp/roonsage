"""Background AI enrichment — only runs for free providers (ollama / custom).

Tasks:
  enrich_vibes_batch             — listening-context + mood tags on library tracks
  score_watchlist_release        — relevance scoring for new releases
  generate_cluster_labels        — vivid AI names + descriptions for sonic clusters
  generate_song_path_narrative   — narrative for the sonic journey between two tracks
  generate_template_suggestions  — suggest new playlist templates from patterns
  enrich_notification            — personalise a notification message
  generate_weekly_insights       — personalised weekly listening digest
  generate_discovery_description — AI tagline + blurb for a discovery section
  generate_playlist_description  — description + tags for a saved playlist
  extract_lyrics_themes_batch    — theme/arc/language extraction from lyrics
"""

import asyncio
import datetime
import json
import logging

from backend.background_tasks import task_tracker
from backend.db import get_db_connection
from backend.llm_client import get_llm_client, is_background_ai_enabled

logger = logging.getLogger(__name__)

BATCH_SIZE = 25

# ---------------------------------------------------------------------------
# Concurrency gate + night-window helpers
# ---------------------------------------------------------------------------

# One LLM request at a time — Gemma 4 locks up with parallel calls.
# Lazily created so it binds to the running event loop, not import-time.
_LLM_SEMAPHORE: asyncio.Semaphore | None = None

NIGHT_START = 1   # 01:00 local — heavy batch jobs may start
NIGHT_END   = 7   # 07:00 local — heavy batch jobs must finish (or pause)

BATCH_PAUSE     = 5    # seconds between vibe-tagging batches at night
DAY_PAUSE       = 60   # seconds between vibe-tagging batches during the day
LYRICS_PAUSE    = 10   # seconds between lyrics batches at night
LYRICS_DAY_PAUSE = 90  # seconds between lyrics batches during the day


def _get_semaphore() -> asyncio.Semaphore:
    """Return the singleton LLM semaphore, creating it on first call."""
    global _LLM_SEMAPHORE
    if _LLM_SEMAPHORE is None:
        _LLM_SEMAPHORE = asyncio.Semaphore(1)
    return _LLM_SEMAPHORE


def _is_night_window() -> bool:
    """True when the current local hour is inside the heavy-task window."""
    return NIGHT_START <= datetime.datetime.now().hour < NIGHT_END


async def _sleep_until_night() -> None:
    """Sleep until the next NIGHT_START:00 local time.

    Returns immediately if we are already inside the night window.
    """
    now = datetime.datetime.now()
    h = now.hour
    if NIGHT_START <= h < NIGHT_END:
        return
    target = now.replace(hour=NIGHT_START, minute=0, second=0, microsecond=0)
    if h >= NIGHT_END:          # today's window has passed → tomorrow
        target += datetime.timedelta(days=1)
    wait = max(0.0, (target - now).total_seconds())
    logger.info(
        "Heavy AI task deferred — %.0f min until night window (%02d:00)",
        wait / 60,
        NIGHT_START,
    )
    await asyncio.sleep(wait)


# ---------------------------------------------------------------------------
# System prompts
# ---------------------------------------------------------------------------

ENRICHMENT_VIBE_SYSTEM = """Tag each track with 2-4 listening contexts and 1-2 mood labels.

Listening contexts describe WHEN and WHERE someone would play the track:
"late night coding", "morning commute", "dinner party", "Sunday cleaning",
"workout warmup", "rainy afternoon reading", "road trip", "pre-sleep wind-down".

Mood labels describe the FEELING:
"melancholic", "euphoric", "tense", "dreamy", "aggressive", "tender",
"hypnotic", "playful", "brooding", "uplifting".

Use the artist, title, album, year, genre, and any existing tags to inform
your choices. Be specific — "late night coding" is better than "night".

Return ONLY a JSON array:
[
  {"number": 1, "contexts": ["late night coding", "rainy afternoon"],
   "moods": ["melancholic", "dreamy"]},
  {"number": 2, "contexts": ["morning commute", "workout warmup"],
   "moods": ["uplifting", "euphoric"]},
  ...
]"""

WATCHLIST_RELEVANCE_SYSTEM = """Score a new release's relevance to a listener's taste profile.

You receive:
1. A new release (artist, album title, release type, date)
2. The listener's taste profile summary (top genres, favorite artists, moods, dislikes)
3. The listener's history with this artist (play count, last played, owned albums)

Assess how excited this listener should be about this release on a 1-5 scale:
5 = must-listen (core artist, matching genre/mood)
4 = highly relevant (adjacent artist or genre sweet spot)
3 = worth checking out
2 = tangential interest
1 = unlikely match

Return ONLY a JSON object:
{"score": 4, "reason": "One sentence explaining why this score.",
 "highlight": "One compelling detail to use in the notification."
}"""

WEEKLY_INSIGHTS_SYSTEM = """Write a brief weekly listening digest for a music lover.

You receive:
1. This week's listening stats (hours, top artists, top genres, new discoveries)
2. Comparison with previous weeks (trends, changes)
3. Taste profile (favorite genres, top artists, moods, peak hours)

Write exactly 3 insights — each one sentence, personal and specific:
- One PATTERN observation ("You listened to 40% more jazz this week than usual")
- One REDISCOVERY prompt ("You haven't played Portishead in 23 days — longest gap since March")
- One SUGGESTION based on recent trends ("Your ambient listening peaks at 11pm — try Grouper's 'Dragging a Dead Deer Up a Hill'")

Return ONLY a JSON object:
{"insights": [
  {"type": "pattern", "text": "..."},
  {"type": "rediscovery", "text": "..."},
  {"type": "suggestion", "text": "...", "artist": "...", "album": "..."}
],
 "headline": "3-5 word summary of the week, e.g. 'Jazz Revival Week'"
}"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _taste_summary(profile: dict) -> str:
    """Compact one-block text representation of a taste profile for prompts."""
    genres  = ", ".join(list(profile.get("genres", {}).keys())[:8])
    artists = ", ".join(list(profile.get("artists", {}).keys())[:8])
    moods   = ", ".join(list(profile.get("moods", {}).keys())[:6])
    dislikes = ", ".join((profile.get("dislikes") or [])[:6])
    peak = profile.get("listening_patterns", {}).get("peak_hour")
    peak_str = f"  Peak listening hour: {peak}:00" if peak is not None else ""
    return (
        f"Top genres: {genres or '—'}\n"
        f"Favourite artists: {artists or '—'}\n"
        f"Moods: {moods or '—'}\n"
        f"Dislikes: {dislikes or '—'}{peak_str}"
    )


def _get_taste_profile() -> dict:
    conn = get_db_connection()
    try:
        row = conn.execute("SELECT profile_json FROM taste_profile WHERE id = 1").fetchone()
        return json.loads(row["profile_json"]) if row else {}
    finally:
        conn.close()


def _parse_json_response(content: str) -> dict | list | None:
    """Strip markdown fences and parse JSON from an LLM response."""
    text = content.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


# ---------------------------------------------------------------------------
# Task 1 — vibe / context tagging
# ---------------------------------------------------------------------------

async def enrich_vibes_batch(
    item_keys: list[str] | None = None,
    max_batches: int | None = None,
) -> None:
    """LLM-tag library tracks with listening contexts and moods.

    If item_keys is None, processes untagged tracks.
    max_batches limits how many batches of BATCH_SIZE to process per call
    (None = all untagged tracks, 1 = one batch of 20 for trickle mode).
    """
    if not is_background_ai_enabled():
        logger.debug("enrich_vibes_batch skipped — background AI disabled")
        return

    client = get_llm_client()
    if not client:
        return

    conn = get_db_connection()
    try:
        if item_keys:
            placeholders = ",".join("?" * len(item_keys))
            rows = conn.execute(
                f"""
                SELECT t.item_key, t.title, t.artist, t.album, t.year,
                       GROUP_CONCAT(tg.genre, ', ') AS genres
                FROM tracks t
                LEFT JOIN track_genres tg ON tg.track_key = t.item_key
                LEFT JOIN track_vibes tv ON tv.item_key = t.item_key
                WHERE t.item_key IN ({placeholders}) AND tv.item_key IS NULL
                GROUP BY t.item_key
                """,
                item_keys,
            ).fetchall()
        elif max_batches is not None:
            rows = conn.execute(
                """
                SELECT t.item_key, t.title, t.artist, t.album, t.year,
                       GROUP_CONCAT(tg.genre, ', ') AS genres
                FROM tracks t
                LEFT JOIN track_genres tg ON tg.track_key = t.item_key
                LEFT JOIN track_vibes tv ON tv.item_key = t.item_key
                WHERE tv.item_key IS NULL
                GROUP BY t.item_key
                LIMIT ?
                """,
                (max_batches * BATCH_SIZE,),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT t.item_key, t.title, t.artist, t.album, t.year,
                       GROUP_CONCAT(tg.genre, ', ') AS genres
                FROM tracks t
                LEFT JOIN track_genres tg ON tg.track_key = t.item_key
                LEFT JOIN track_vibes tv ON tv.item_key = t.item_key
                WHERE tv.item_key IS NULL
                GROUP BY t.item_key
                """
            ).fetchall()
    finally:
        conn.close()

    if not rows:
        return

    task_tracker.start("vibe_tagging", total=len(rows))
    try:
        for batch_start in range(0, len(rows), BATCH_SIZE):
            batch = rows[batch_start : batch_start + BATCH_SIZE]
            prompt_lines = []
            for i, row in enumerate(batch, 1):
                parts = [f"{row['artist']} — {row['title']}"]
                if row["album"]:
                    parts.append(f"({row['album']}")
                    if row["year"]:
                        parts[-1] += f", {row['year']}"
                    parts[-1] += ")"
                if row["genres"]:
                    parts.append(f"[{row['genres']}]")
                prompt_lines.append(f"{i}. " + " ".join(parts))

            prompt = "\n".join(prompt_lines)
            try:
                async with _get_semaphore():
                    resp = await client.generate_fast(prompt, ENRICHMENT_VIBE_SYSTEM)
                parsed = _parse_json_response(resp.content)
                if not isinstance(parsed, list):
                    raise ValueError("Expected JSON array")

                conn = get_db_connection()
                try:
                    for entry in parsed:
                        idx = entry.get("number", 0) - 1
                        if 0 <= idx < len(batch):
                            item_key = batch[idx]["item_key"]
                            conn.execute(
                                """
                                INSERT OR REPLACE INTO track_vibes
                                    (item_key, contexts, moods, updated_at)
                                VALUES (?, ?, ?, datetime('now'))
                                """,
                                (
                                    item_key,
                                    json.dumps(entry.get("contexts", [])),
                                    json.dumps(entry.get("moods", [])),
                                ),
                            )
                    conn.commit()
                finally:
                    conn.close()

            except Exception as exc:
                logger.warning("vibe_tagging batch error: %s", exc)

            task_tracker.progress("vibe_tagging", completed=batch_start + len(batch))
            await asyncio.sleep(BATCH_PAUSE)

        task_tracker.finish("vibe_tagging")
    except Exception as exc:
        task_tracker.fail("vibe_tagging", str(exc))
        raise


# ---------------------------------------------------------------------------
# Task 2 — watchlist release scoring
# ---------------------------------------------------------------------------

async def score_watchlist_release(
    release: dict,
    artist_history: dict,
) -> dict | None:
    """Score a new release against the user's taste profile.

    release:        {artist_name, album_title, release_type, release_date}
    artist_history: {play_count, last_played, owned_albums: [...]}
    Returns:        {score, reason, highlight} or None on error.
    """
    if not is_background_ai_enabled():
        logger.debug("score_watchlist_release skipped — background AI disabled")
        return None

    client = get_llm_client()
    if not client:
        return None

    profile = _get_taste_profile()
    taste = _taste_summary(profile)

    prompt = (
        f"New release:\n"
        f"  Artist: {release.get('artist_name', '—')}\n"
        f"  Album:  {release.get('album_title', '—')}\n"
        f"  Type:   {release.get('release_type', '—')}\n"
        f"  Date:   {release.get('release_date', '—')}\n\n"
        f"Listener taste profile:\n{taste}\n\n"
        f"Artist history for this listener:\n"
        f"  Play count:    {artist_history.get('play_count', 0)}\n"
        f"  Last played:   {artist_history.get('last_played', 'never')}\n"
        f"  Owned albums:  {', '.join(artist_history.get('owned_albums', [])) or '—'}"
    )

    try:
        async with _get_semaphore():
            resp = await client.analyze(prompt, WATCHLIST_RELEVANCE_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if isinstance(parsed, dict) and "score" in parsed:
            return parsed
    except Exception as exc:
        logger.warning("score_watchlist_release error: %s", exc)

    return None


# ---------------------------------------------------------------------------
# Task 3 — weekly insights
# ---------------------------------------------------------------------------

async def generate_weekly_insights(this_week: dict, prev_weeks: list[dict]) -> dict | None:
    """Generate a personalised weekly listening digest.

    this_week:  {hours, top_artists, top_genres, new_discoveries, total_plays}
    prev_weeks: list of similar dicts for the previous 3 weeks
    Returns:    {insights: [...], headline: str} or None on error.
    """
    if not is_background_ai_enabled():
        logger.debug("generate_weekly_insights skipped — background AI disabled")
        return None

    client = get_llm_client()
    if not client:
        return None

    profile = _get_taste_profile()
    taste = _taste_summary(profile)

    def _week_summary(w: dict) -> str:
        artists = ", ".join((w.get("top_artists") or [])[:5])
        genres  = ", ".join((w.get("top_genres") or [])[:5])
        return (
            f"  Hours: {w.get('hours', 0):.1f}  Plays: {w.get('total_plays', 0)}\n"
            f"  Top artists: {artists or '—'}\n"
            f"  Top genres:  {genres or '—'}\n"
            f"  New discoveries: {w.get('new_discoveries', 0)}"
        )

    prev_block = "\n\n".join(
        f"Week -{i + 1}:\n{_week_summary(w)}" for i, w in enumerate(prev_weeks[:3])
    )

    prompt = (
        f"This week:\n{_week_summary(this_week)}\n\n"
        f"{prev_block}\n\n"
        f"Taste profile:\n{taste}"
    )

    task_tracker.start("weekly_insights", total=1)
    try:
        async with _get_semaphore():
            resp = await client.analyze(prompt, WEEKLY_INSIGHTS_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if isinstance(parsed, dict) and "insights" in parsed:
            conn = get_db_connection()
            try:
                conn.execute(
                    """
                    INSERT OR REPLACE INTO weekly_insights_cache
                        (id, insights, headline, generated_at)
                    VALUES (1, ?, ?, datetime('now'))
                    """,
                    (json.dumps(parsed["insights"]), parsed.get("headline", "")),
                )
                conn.commit()
            finally:
                conn.close()

            task_tracker.finish("weekly_insights")
            return parsed
    except Exception as exc:
        task_tracker.fail("weekly_insights", str(exc))
        logger.warning("generate_weekly_insights error: %s", exc)

    return None


# ---------------------------------------------------------------------------
# Task 4 — discovery section descriptions
# ---------------------------------------------------------------------------

DISCOVERY_DESCRIPTION_SYSTEM = """Write a short, personal discovery description for a music library section.

You receive:
1. Section type: one of "undiscovered_albums", "deep_cuts", "forgotten_favorites", "genre_explorer"
2. The tracks/albums in that section (artist, title, genre, play count, last played)
3. The listener's taste profile summary

For each section, write:
- tagline: A punchy 4-8 word hook (e.g., "Albums hiding in plain sight")
- description: 1-2 sentences explaining why THESE specific results matter to THIS listener.
  Reference specific artists or albums from the section. Make it personal, not generic.

Return ONLY a JSON object:
{"tagline": "...", "description": "..."}"""

PLAYLIST_DESCRIPTION_SYSTEM = """Write a short description for a saved playlist.

You receive:
1. Playlist title
2. Track list (artist, title, album, year) — up to 30 tracks
3. How it was generated (prompt, template name, seed track, or schedule)

Write:
- description: 2-3 sentences capturing the playlist's character. Mention 2-3 specific
  tracks or artists. Describe the arc or flow — does it build energy, wind down, or
  stay steady? Sound like a knowledgeable friend, not a music critic.
- short_tags: 3-5 one-word tags for filtering (e.g., ["chill", "jazz", "evening", "instrumental"])

Return ONLY a JSON object:
{"description": "...", "short_tags": ["...", "..."]}"""

LYRICS_THEME_SYSTEM = """Extract themes and emotional content from song lyrics.

You receive a batch of tracks with their lyrics text. For each track, identify:
- themes: 2-4 thematic labels from this vocabulary:
  "love", "loss", "longing", "rebellion", "identity", "nature", "urban life",
  "mortality", "freedom", "isolation", "celebration", "nostalgia", "anger",
  "spirituality", "travel", "addiction", "political", "heartbreak", "hope",
  "existential", "fantasy", "relationships", "self-reflection", "protest"
- emotional_arc: one of "builds", "descends", "steady", "volatile", "cathartic"
- language: detected language code (e.g., "en", "nl", "fr", "instrumental")
- abstract_level: "literal", "metaphorical", or "abstract"

If lyrics are minimal, instrumental, or unintelligible, set themes to []
and language to "instrumental".

Return ONLY a JSON array:
[
  {"number": 1, "themes": ["longing", "nostalgia"],
   "emotional_arc": "builds", "language": "en",
   "abstract_level": "metaphorical"},
  ...
]"""

LYRICS_BATCH_SIZE = 8  # lyrics are long — keep batches small

CLUSTER_LABEL_SYSTEM = """Name and describe audio feature clusters from a music library.

You receive a list of clusters, each with:
- cluster_id
- track_count
- top artists (by frequency)
- top genres (by frequency)
- average audio features (BPM, energy, danceability, valence, instrumentalness)
- sample tracks (5-10 representative tracks)

For each cluster, write:
- label: A vivid 2-5 word name describing the cluster's sonic identity.
  Good: "Atmospheric Post-Rock", "Uptempo 70s Funk", "Dense Electronic Textures"
  Bad: "Cluster 3", "Mixed Genre", "Various Artists"
- description: 1 sentence capturing what unites these tracks sonically.
  Reference the actual audio features and specific artists.
- color_hint: A CSS color name that evokes the cluster's mood
  (e.g., "slategray", "coral", "midnightblue", "goldenrod")

Return ONLY a JSON array:
[
  {"cluster_id": 0, "label": "...", "description": "...", "color_hint": "..."},
  ...
]"""

SONG_PATH_NARRATIVE_SYSTEM = """Narrate the sonic journey between two tracks.

You receive an ordered path of tracks bridging a start and end track,
with audio features for each step (BPM, key, energy, valence, danceability).

Write a brief journey narrative (3-5 sentences total) describing how the
music transitions. Focus on:
- The sonic shift at each step (what changes, what stays)
- The overall arc (does energy build? does mood darken?)
- Why each stepping stone makes sense as a bridge

Reference specific tracks by name. Be concise and vivid.

Return ONLY a JSON object:
{"narrative": "...",
 "arc_type": "ascending" | "descending" | "u-shaped" | "arch" | "flat",
 "key_transition": "One sentence about the harmonic journey"
}"""

TEMPLATE_SUGGESTION_SYSTEM = """Suggest new playlist templates based on a listener's patterns.

You receive:
1. Listening patterns by day/hour (heatmap data: which genres at which times)
2. Existing templates (names + prompts — do NOT duplicate these)
3. Taste profile (top genres, moods, favorite artists, peak hours)
4. Recent playlist history (last 10 generated playlists with prompts)

Suggest exactly 3 new templates the user doesn't have yet. Each template
should fill a gap in their listening routine — a time slot, mood, or
activity they listen to but haven't templated.

Return ONLY a JSON array:
[
  {"name": "Friday Wind-Down",
   "prompt": "Mellow, atmospheric tracks for ending the work week. Favor ambient, downtempo, and post-rock.",
   "genres": ["Ambient", "Post-Rock", "Downtempo"],
   "decades": [],
   "track_count": 20,
   "reasoning": "You listen to ambient 3x more on Fridays after 18:00 but have no template for it."
  },
  ...
]"""

NOTIFICATION_ENRICH_SYSTEM = """Write a personalized notification message for a music event.

You receive:
1. Event type: "playlist_generated", "new_release_found", "listening_milestone", or "library_sync_complete"
2. Event data (track count, playlist title, artist name, milestone details, etc.)
3. Listener's taste profile summary (top artists, genres, moods)

Write a short, personal notification message (1-2 sentences max, under 200 chars).
Sound like a knowledgeable friend who knows their music taste, not a generic app.

Examples of good messages:
- "24 tracks with a heavy Miles Davis lean — perfect for your usual Thursday night jazz session."
- "New Floating Points album just dropped. Given your ambient obsession lately, this is mandatory."
- "500 hours of listening! Your top 3: Radiohead, Nick Cave, Portishead. Taste hasn't budged in months."

Examples of bad messages (too generic):
- "Your playlist has been generated with 24 tracks!"
- "A new release has been found for an artist on your watchlist."

Return ONLY a JSON object:
{"message": "...", "emoji": "one relevant emoji"}"""


async def generate_discovery_description(
    section_type: str,
    tracks: list[dict],
) -> dict | None:
    """Generate a tagline + description for a discovery section and cache it.

    tracks: list of dicts with keys like artist, title, play_count, last_played_at.
    Returns {tagline, description} or None on error.
    """
    if not is_background_ai_enabled():
        logger.debug("generate_discovery_description skipped — background AI disabled")
        return None

    client = get_llm_client()
    if not client:
        return None

    profile = _get_taste_profile()
    taste = _taste_summary(profile)

    track_lines = []
    for t in tracks[:20]:
        parts = [f"{t.get('artist', '—')} — {t.get('title') or t.get('album', '—')}"]
        if t.get("play_count") is not None:
            parts.append(f"({t['play_count']} plays)")
        if t.get("total_plays") is not None:
            parts.append(f"({t['total_plays']} plays)")
        if t.get("last_played_at"):
            parts.append(f"last: {t['last_played_at'][:10]}")
        track_lines.append(" ".join(parts))

    prompt = (
        f"Section type: {section_type}\n\n"
        f"Tracks/albums:\n" + "\n".join(track_lines) + "\n\n"
        f"Taste profile:\n{taste}"
    )

    try:
        async with _get_semaphore():
            resp = await client.generate_fast(prompt, DISCOVERY_DESCRIPTION_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if isinstance(parsed, dict) and "tagline" in parsed:
            conn = get_db_connection()
            try:
                conn.execute(
                    """
                    INSERT OR REPLACE INTO discovery_descriptions
                        (section_type, tagline, description, generated_at)
                    VALUES (?, ?, ?, datetime('now'))
                    """,
                    (section_type, parsed["tagline"], parsed.get("description", "")),
                )
                conn.commit()
            finally:
                conn.close()
            return parsed
    except Exception as exc:
        logger.warning("generate_discovery_description error: %s", exc)

    return None


async def refresh_discovery_descriptions(force: bool = False) -> None:
    """Proactively regenerate AI descriptions for all three discovery sections.

    Skips any section whose cached entry is younger than 24 h (unless force=True).
    Called at startup and on a 24 h loop so descriptions are always warm in the
    cache before the user opens the Discovery tab.
    """
    import asyncio as _asyncio  # noqa: PLC0415
    from datetime import UTC, datetime, timedelta  # noqa: PLC0415

    if not is_background_ai_enabled():
        logger.debug("refresh_discovery_descriptions skipped — background AI disabled")
        return

    from backend.discovery import (  # noqa: PLC0415
        get_deep_cuts,
        get_forgotten_favorites,
        get_genre_explorer,
    )

    sections = [
        ("deep_cuts",           get_deep_cuts),
        ("forgotten_favorites", get_forgotten_favorites),
        ("genre_explorer",      get_genre_explorer),
    ]

    for section_type, getter in sections:
        if not force:
            conn = get_db_connection()
            try:
                row = conn.execute(
                    "SELECT generated_at FROM discovery_descriptions WHERE section_type = ?",
                    (section_type,),
                ).fetchone()
            finally:
                conn.close()
            if row:
                try:
                    generated = datetime.fromisoformat(row["generated_at"].replace(" ", "T"))
                    if generated.tzinfo is None:
                        generated = generated.replace(tzinfo=UTC)
                    if datetime.now(UTC) - generated < timedelta(hours=24):
                        logger.debug("Discovery description for %s is fresh, skipping", section_type)
                        continue
                except Exception:
                    pass  # parse error → fall through and regenerate

        try:
            tracks = await _asyncio.to_thread(getter)
        except Exception as exc:
            logger.warning("Could not fetch tracks for discovery section %s: %s", section_type, exc)
            continue

        if not tracks:
            continue

        logger.info("Refreshing discovery description: %s (%d items)", section_type, len(tracks))
        await generate_discovery_description(section_type, tracks)
        await _asyncio.sleep(3)  # brief gap between LLM calls


async def generate_playlist_description(
    title: str,
    tracks: list[dict],
    origin: str,
    result_id: str | None = None,
) -> dict | None:
    """Generate a description + tags for a saved playlist.

    tracks: list of {artist, title, album, year}.
    origin: human-readable string — prompt text, template name, seed track, or schedule name.
    result_id: if set, stores ai_description + ai_tags back onto the results row.
    Returns {description, short_tags} or None on error.
    """
    if not is_background_ai_enabled():
        logger.debug("generate_playlist_description skipped — background AI disabled")
        return None

    client = get_llm_client()
    if not client:
        return None

    track_lines = []
    for t in tracks[:30]:
        year = f" ({t['year']})" if t.get("year") else ""
        track_lines.append(f"{t.get('artist', '—')} — {t.get('title', '—')}{year}")

    prompt = (
        f"Playlist title: {title}\n\n"
        f"Generated from: {origin}\n\n"
        f"Tracks:\n" + "\n".join(track_lines)
    )

    try:
        async with _get_semaphore():
            resp = await client.generate_fast(prompt, PLAYLIST_DESCRIPTION_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if isinstance(parsed, dict) and "description" in parsed:
            if result_id:
                conn = get_db_connection()
                try:
                    conn.execute(
                        """
                        UPDATE results
                        SET ai_description = ?, ai_tags = ?
                        WHERE id = ?
                        """,
                        (
                            parsed["description"],
                            json.dumps(parsed.get("short_tags", [])),
                            result_id,
                        ),
                    )
                    conn.commit()
                finally:
                    conn.close()
            return parsed
    except Exception as exc:
        logger.warning("generate_playlist_description error: %s", exc)

    return None


async def extract_lyrics_themes_batch(
    item_keys: list[str] | None = None,
    max_batches: int | None = None,
) -> None:
    """Extract themes, arc, language from lyrics and store in track_lyrics_themes.

    If item_keys is None, processes tracks with lyrics but no themes yet.
    max_batches limits how many batches of LYRICS_BATCH_SIZE to process per call
    (None = all untagged tracks, 1 = one batch of 5 for trickle mode).
    """
    if not is_background_ai_enabled():
        logger.debug("extract_lyrics_themes_batch skipped — background AI disabled")
        return

    client = get_llm_client()
    if not client:
        return

    conn = get_db_connection()
    try:
        if item_keys:
            placeholders = ",".join("?" * len(item_keys))
            rows = conn.execute(
                f"""
                SELECT ld.item_key, t.title, t.artist, ld.lyrics
                FROM lyrics_data ld
                JOIN tracks t ON t.item_key = ld.item_key
                LEFT JOIN track_lyrics_themes lt ON lt.item_key = ld.item_key
                WHERE ld.item_key IN ({placeholders})
                  AND ld.lyrics IS NOT NULL AND ld.lyrics != ''
                  AND lt.item_key IS NULL
                """,
                item_keys,
            ).fetchall()
        elif max_batches is not None:
            rows = conn.execute(
                """
                SELECT ld.item_key, t.title, t.artist, ld.lyrics
                FROM lyrics_data ld
                JOIN tracks t ON t.item_key = ld.item_key
                LEFT JOIN track_lyrics_themes lt ON lt.item_key = ld.item_key
                WHERE ld.lyrics IS NOT NULL AND ld.lyrics != ''
                  AND lt.item_key IS NULL
                LIMIT ?
                """,
                (max_batches * LYRICS_BATCH_SIZE,),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT ld.item_key, t.title, t.artist, ld.lyrics
                FROM lyrics_data ld
                JOIN tracks t ON t.item_key = ld.item_key
                LEFT JOIN track_lyrics_themes lt ON lt.item_key = ld.item_key
                WHERE ld.lyrics IS NOT NULL AND ld.lyrics != ''
                  AND lt.item_key IS NULL
                """
            ).fetchall()
    finally:
        conn.close()

    if not rows:
        return

    task_tracker.start("lyrics_themes", total=len(rows))
    try:
        for batch_start in range(0, len(rows), LYRICS_BATCH_SIZE):
            batch = rows[batch_start : batch_start + LYRICS_BATCH_SIZE]
            prompt_parts = []
            for i, row in enumerate(batch, 1):
                lyrics_snippet = (row["lyrics"] or "")[:800]
                prompt_parts.append(
                    f"{i}. {row['artist']} — {row['title']}\n{lyrics_snippet}"
                )

            prompt = "\n\n---\n\n".join(prompt_parts)
            try:
                async with _get_semaphore():
                    resp = await client.generate_fast(prompt, LYRICS_THEME_SYSTEM)
                parsed = _parse_json_response(resp.content)
                if not isinstance(parsed, list):
                    raise ValueError("Expected JSON array")

                conn = get_db_connection()
                try:
                    for entry in parsed:
                        idx = entry.get("number", 0) - 1
                        if 0 <= idx < len(batch):
                            item_key = batch[idx]["item_key"]
                            conn.execute(
                                """
                                INSERT OR REPLACE INTO track_lyrics_themes
                                    (item_key, themes, emotional_arc, language,
                                     abstract_level, updated_at)
                                VALUES (?, ?, ?, ?, ?, datetime('now'))
                                """,
                                (
                                    item_key,
                                    json.dumps(entry.get("themes", [])),
                                    entry.get("emotional_arc", ""),
                                    entry.get("language", ""),
                                    entry.get("abstract_level", ""),
                                ),
                            )
                    conn.commit()
                finally:
                    conn.close()

            except Exception as exc:
                logger.warning("lyrics_themes batch error: %s", exc)

            task_tracker.progress("lyrics_themes", completed=batch_start + len(batch))
            await asyncio.sleep(LYRICS_PAUSE)

        task_tracker.finish("lyrics_themes")
    except Exception as exc:
        task_tracker.fail("lyrics_themes", str(exc))
        raise


# ---------------------------------------------------------------------------
# Task 7 — cluster AI labels
# ---------------------------------------------------------------------------

async def generate_cluster_labels(cluster_ids: list[int] | None = None) -> None:
    """Generate vivid AI names + descriptions for sonic clusters."""
    if not is_background_ai_enabled():
        return

    client = get_llm_client()
    if not client:
        return

    conn = get_db_connection()
    try:
        cluster_rows = conn.execute("""
            SELECT
                af.cluster_id,
                COUNT(*) AS track_count,
                AVG(af.bpm) AS avg_bpm,
                AVG(af.energy) AS avg_energy,
                AVG(af.valence) AS avg_valence,
                AVG(af.danceability) AS avg_danceability,
                AVG(af.instrumentalness) AS avg_instrumentalness
            FROM track_audio_features af
            WHERE af.cluster_id IS NOT NULL AND af.cluster_id != -1
            GROUP BY af.cluster_id
            ORDER BY track_count DESC
        """).fetchall()

        if not cluster_rows:
            return

        clusters_data = []
        for cr in cluster_rows:
            cid = cr["cluster_id"]
            if cluster_ids is not None and cid not in cluster_ids:
                continue

            artists = conn.execute("""
                SELECT t.artist, COUNT(*) AS n
                FROM tracks t
                JOIN track_audio_features af ON af.item_key = t.item_key
                WHERE af.cluster_id = ?
                GROUP BY t.artist ORDER BY n DESC LIMIT 5
            """, (cid,)).fetchall()

            genres = conn.execute("""
                SELECT tg.genre, COUNT(*) AS n
                FROM track_genres tg
                JOIN track_audio_features af ON af.item_key = tg.track_key
                WHERE af.cluster_id = ?
                GROUP BY tg.genre ORDER BY n DESC LIMIT 5
            """, (cid,)).fetchall()

            samples = conn.execute("""
                SELECT t.title, t.artist FROM tracks t
                JOIN track_audio_features af ON af.item_key = t.item_key
                WHERE af.cluster_id = ?
                ORDER BY RANDOM() LIMIT 8
            """, (cid,)).fetchall()

            clusters_data.append({
                "cluster_id": cid,
                "track_count": cr["track_count"],
                "top_artists": [r["artist"] for r in artists],
                "top_genres":  [r["genre"]  for r in genres],
                "avg_features": {
                    "bpm":            round(cr["avg_bpm"] or 0, 1),
                    "energy":         round(cr["avg_energy"] or 0, 2),
                    "valence":        round(cr["avg_valence"] or 0, 2),
                    "danceability":   round(cr["avg_danceability"] or 0, 2),
                    "instrumentalness": round(cr["avg_instrumentalness"] or 0, 2),
                },
                "sample_tracks": [f"{r['artist']} — {r['title']}" for r in samples],
            })
    finally:
        conn.close()

    if not clusters_data:
        return

    lines = []
    for c in clusters_data:
        f = c["avg_features"]
        lines.append(
            f"Cluster {c['cluster_id']} ({c['track_count']} tracks):\n"
            f"  Top artists: {', '.join(c['top_artists'])}\n"
            f"  Top genres:  {', '.join(c['top_genres'])}\n"
            f"  Avg features: BPM={f['bpm']}, energy={f['energy']}, "
            f"danceability={f['danceability']}, valence={f['valence']}, "
            f"instrumentalness={f['instrumentalness']}\n"
            f"  Samples: {', '.join(c['sample_tracks'][:6])}"
        )

    prompt = "\n\n".join(lines)

    task_tracker.start("cluster_labels", total=len(clusters_data))
    try:
        async with _get_semaphore():
            resp = await client.generate_fast(prompt, CLUSTER_LABEL_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if not isinstance(parsed, list):
            raise ValueError("Expected JSON array")

        conn = get_db_connection()
        try:
            for entry in parsed:
                cid = entry.get("cluster_id")
                if cid is None:
                    continue
                conn.execute(
                    """INSERT OR REPLACE INTO cluster_ai_labels
                       (cluster_id, label, description, color_hint, generated_at)
                       VALUES (?, ?, ?, ?, datetime('now'))""",
                    (cid, entry.get("label", ""), entry.get("description", ""),
                     entry.get("color_hint", "")),
                )
            conn.commit()
        finally:
            conn.close()

        task_tracker.finish("cluster_labels")
        logger.info("Generated AI labels for %d clusters", len(parsed))
    except Exception as exc:
        task_tracker.fail("cluster_labels", str(exc))
        logger.warning("generate_cluster_labels error: %s", exc)


# ---------------------------------------------------------------------------
# Task 8 — song path narrative
# ---------------------------------------------------------------------------

async def generate_song_path_narrative(
    cache_key: str,
    path_tracks: list[dict],
) -> dict | None:
    """Narrate the sonic journey along a song path and cache the result."""
    if not is_background_ai_enabled():
        return None

    client = get_llm_client()
    if not client:
        return None

    # Return cached result if available
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT narrative, arc_type, key_transition "
            "FROM song_path_narratives WHERE cache_key = ?",
            (cache_key,),
        ).fetchone()
        if row:
            return {"narrative": row["narrative"], "arc_type": row["arc_type"],
                    "key_transition": row["key_transition"]}
    finally:
        conn.close()

    steps = []
    for i, t in enumerate(path_tracks):
        step = f"{i + 1}. {t.get('artist', '—')} — {t.get('title', '—')}"
        feats = []
        if t.get("bpm"):
            feats.append(f"BPM={round(t['bpm'])}")
        if t.get("energy") is not None:
            feats.append(f"energy={t['energy']:.2f}")
        if t.get("valence") is not None:
            feats.append(f"valence={t['valence']:.2f}")
        if t.get("camelot"):
            feats.append(f"key={t['camelot']}")
        if feats:
            step += f" [{', '.join(feats)}]"
        steps.append(step)

    prompt = "Path:\n" + "\n".join(steps)

    try:
        async with _get_semaphore():
            resp = await client.generate_fast(prompt, SONG_PATH_NARRATIVE_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if isinstance(parsed, dict) and "narrative" in parsed:
            conn = get_db_connection()
            try:
                conn.execute(
                    """INSERT OR REPLACE INTO song_path_narratives
                       (cache_key, narrative, arc_type, key_transition, generated_at)
                       VALUES (?, ?, ?, ?, datetime('now'))""",
                    (cache_key, parsed["narrative"],
                     parsed.get("arc_type", ""), parsed.get("key_transition", "")),
                )
                conn.commit()
            finally:
                conn.close()
            return parsed
    except Exception as exc:
        logger.warning("generate_song_path_narrative error: %s", exc)

    return None


# ---------------------------------------------------------------------------
# Task 9 — template suggestions
# ---------------------------------------------------------------------------

async def generate_template_suggestions() -> list[dict] | None:
    """Suggest 3 new playlist templates based on the user's listening patterns."""
    if not is_background_ai_enabled():
        return None

    client = get_llm_client()
    if not client:
        return None

    from backend.templates import get_all_templates  # noqa: PLC0415

    conn = get_db_connection()
    try:
        pattern_rows = conn.execute("""
            SELECT strftime('%w', listened_at) AS dow,
                   strftime('%H', listened_at) AS hour,
                   tg.genre,
                   COUNT(*) AS n
            FROM listening_history lh
            LEFT JOIN track_genres tg ON tg.track_key = lh.item_key
            WHERE lh.listened_at > datetime('now', '-60 days')
            GROUP BY dow, hour, genre
            ORDER BY n DESC
            LIMIT 80
        """).fetchall()

        recent_playlists = conn.execute("""
            SELECT title, prompt FROM results
            WHERE type IN ('prompt_playlist', 'seed_playlist')
            ORDER BY created_at DESC LIMIT 10
        """).fetchall()
    finally:
        conn.close()

    profile = _get_taste_profile()
    taste = _taste_summary(profile)

    _DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    patterns = "\n".join(
        f"{_DOW[int(r['dow'])] if r['dow'] else '?'} {r['hour']}h: "
        f"{r['genre'] or 'mixed'} ({r['n']} plays)"
        for r in pattern_rows
    )

    all_templates = get_all_templates()
    existing = "\n".join(f"- {t.name}: {t.prompt[:80]}" for t in all_templates[:60])

    recent = "\n".join(
        f"- {r['title']}: {(r['prompt'] or '')[:80]}" for r in recent_playlists
    )

    prompt = (
        f"Listening patterns (last 60 days):\n{patterns}\n\n"
        f"Existing templates (do NOT duplicate):\n{existing}\n\n"
        f"Taste profile:\n{taste}\n\n"
        f"Recent playlists:\n{recent}"
    )

    task_tracker.start("template_suggestions", total=1)
    try:
        async with _get_semaphore():
            resp = await client.generate_fast(prompt, TEMPLATE_SUGGESTION_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if isinstance(parsed, list) and parsed:
            conn = get_db_connection()
            try:
                conn.execute(
                    """INSERT OR REPLACE INTO template_suggestions_cache
                       (id, suggestions, generated_at)
                       VALUES (1, ?, datetime('now'))""",
                    (json.dumps(parsed),),
                )
                conn.commit()
            finally:
                conn.close()
            task_tracker.finish("template_suggestions")
            logger.info("Generated %d template suggestions", len(parsed))
            return parsed
    except Exception as exc:
        task_tracker.fail("template_suggestions", str(exc))
        logger.warning("generate_template_suggestions error: %s", exc)

    return None


# ---------------------------------------------------------------------------
# Task 10 — notification enrichment (on-demand, no cache)
# ---------------------------------------------------------------------------

async def enrich_notification(event_type: str, event_data: dict) -> dict | None:
    """Generate a personalised notification message for a music event.

    Returns {message, emoji} or None on failure / provider not available.
    Called with a short timeout — falls back to the regular message if slow.
    """
    if not is_background_ai_enabled():
        return None

    client = get_llm_client()
    if not client:
        return None

    profile = _get_taste_profile()
    taste = _taste_summary(profile)

    data_lines = "\n".join(f"  {k}: {v}" for k, v in event_data.items()
                           if not k.startswith("ai_"))
    prompt = (
        f"Event type: {event_type}\n\n"
        f"Event data:\n{data_lines}\n\n"
        f"Listener taste profile:\n{taste}"
    )

    try:
        async with _get_semaphore():
            resp = await client.generate_fast(prompt, NOTIFICATION_ENRICH_SYSTEM)
        parsed = _parse_json_response(resp.content)
        if isinstance(parsed, dict) and "message" in parsed:
            return parsed
    except Exception as exc:
        logger.debug("enrich_notification error: %s", exc)

    return None
