"""Prompt analysis and seed track dimension extraction."""

import contextlib

from backend.llm_client import get_llm_client
from backend.models import (
    AnalyzePromptResponse,
    AnalyzeTrackResponse,
    DecadeCount,
    Dimension,
    GenreCount,
    Track,
)
from backend.roon_client import get_roon_client
from backend.taste_profile import TasteProfile

PROMPT_ANALYSIS_SYSTEM = """You are a music expert helping to create playlists from a user's music library.

Analyze the user's prompt and suggest appropriate filters that would help find matching tracks.

Return a JSON object with:
- genres: Array of genre names that match the prompt (e.g., ["Alternative", "Rock", "Indie"])
- decades: Array of decade strings (e.g., ["1990s", "2000s"])
- moods: Array of mood labels chosen from the CLAP mood vocabulary
- vibe_contexts: Array of listening context tags from the vibe vocabulary (e.g., ["dinner party", "road trip"])
- vibe_moods: Array of emotional mood tags from the vibe vocabulary (e.g., ["melancholic", "uplifting"])
- lastfm_tags: Array of matching Last.fm style tags from the provided list (max 3, omit if none fit)
- reasoning: Brief explanation of why you chose these filters

Be specific. Consider:
- Mood/atmosphere → map to vibe_moods and moods vocabularies
- Listening context (studying, party, morning routine) → map to vibe_contexts
- Era references → decades
- Genre keywords → genres
- Last.fm tags can provide additional genre/style context

Only use values that appear in the provided vocabularies — never invent new ones. Leave arrays empty if nothing fits.

Return ONLY valid JSON, no markdown formatting.

If the user's listening preferences are provided, weight your genre suggestions toward their most-listened genres when the request is ambiguous. Always exclude genres they dislike."""


TRACK_ANALYSIS_SYSTEM = """You are a music expert analyzing a song to identify its distinctive characteristics.

Given a track's title, artist, album, and year, identify 5-7 specific musical dimensions that make this track unique. These dimensions will help the user explore similar music.

For each dimension, provide:
- id: A short identifier (e.g., "mood", "era", "instrumentation")
- label: A specific, evocative label (NOT generic like "the mood" - be specific like "The melancholy, bittersweet mood")
- description: A brief explanation of this dimension

Make dimensions SPECIFIC to this track, not generic. Bad: "The genre". Good: "90s British alternative rock with Britpop influences".

Return a JSON object with:
{
  "dimensions": [
    {"id": "mood", "label": "The melancholy, introspective mood", "description": "..."},
    ...
  ]
}

Return ONLY valid JSON, no markdown formatting."""


async def analyze_prompt(prompt: str, use_taste_profile: bool = True) -> AnalyzePromptResponse:
    """Analyze a natural language prompt to suggest filters.

    Args:
        prompt: User's playlist description
        use_taste_profile: When True (default), bias suggestions toward the user's
            stored taste profile (top genres, currently active, dislikes).

    Returns:
        AnalyzePromptResponse with suggested and available filters

    Raises:
        ValueError: If LLM response cannot be parsed
        RuntimeError: If clients are not initialized
    """
    llm_client = get_llm_client()
    roon_client = get_roon_client()

    if not llm_client:
        raise RuntimeError("LLM client not initialized")
    if not roon_client:
        raise RuntimeError("Roon client not initialized")

    # Get library stats for available filters
    stats = roon_client.get_library_stats()
    available_genres = [GenreCount(**g) for g in stats.get("genres", [])]
    available_decades = [DecadeCount(**d) for d in stats.get("decades", [])]

    # Mood vocabulary — derived from the mood tagger (CLAP K-Means). Only moods
    # that have actually been assigned to library tracks are surfaced; we fall
    # back to the full default vocabulary when the tagger hasn't run yet.
    available_moods = _load_available_moods()
    available_vibe_contexts, available_vibe_moods = _load_available_vibes()
    top_lastfm_tags = _load_top_lastfm_tags()

    # Build prompt with available filter context
    analysis_prompt = f"""User's playlist request: "{prompt}"

Available genres in their library:
{', '.join(f"{g.name} ({g.count})" if g.count else g.name for g in available_genres[:30])}

Available decades in their library:
{', '.join(f"{d.name} ({d.count})" if d.count else d.name for d in available_decades)}

Available CLAP mood vocabulary:
{', '.join(available_moods) if available_moods else '(mood tagging not yet run — leave moods empty)'}

Available vibe contexts (listening situations):
{', '.join(available_vibe_contexts) if available_vibe_contexts else '(no vibe tags yet — leave vibe_contexts empty)'}

Available vibe moods (emotional qualities):
{', '.join(available_vibe_moods) if available_vibe_moods else '(no vibe tags yet — leave vibe_moods empty)'}

Available Last.fm tags (top tags from this library):
{', '.join(top_lastfm_tags) if top_lastfm_tags else '(no Last.fm tags yet — leave lastfm_tags empty)'}

Suggest genres, decades, moods, vibe_contexts, vibe_moods, and lastfm_tags from the available options that best match the user's request."""

    # Add taste profile context (gated by use_taste_profile flag)
    if use_taste_profile:
        try:
            profile = TasteProfile.get()
            preferred_genres = sorted(
                profile.get("genres", {}).items(), key=lambda x: -x[1]
            )[:10]
            if preferred_genres:
                analysis_prompt += "\n\nUser's most-listened genres (prioritize these when the request is ambiguous):\n"
                analysis_prompt += ", ".join(f"{g} ({s:.0%})" for g, s in preferred_genres)
            recent = profile.get("recently_active", {})
            if recent.get("top_genres"):
                analysis_prompt += f"\n\nCurrently active genres (last 7 days): {', '.join(recent['top_genres'][:5])}"
            dislikes = profile.get("dislikes", [])
            if dislikes:
                analysis_prompt += f"\n\nUser dislikes (never suggest these): {', '.join(dislikes)}"
        except Exception:
            pass  # Profile unavailable — continue without it

    # Call LLM (async)
    response = await llm_client.analyze(analysis_prompt, PROMPT_ANALYSIS_SYSTEM)

    # Parse response
    data = llm_client.parse_json_response(response)

    available_genre_names = {g.name for g in available_genres}
    available_decade_names = {d.name for d in available_decades}
    available_mood_set = {m.lower() for m in available_moods}
    available_vibe_ctx_set = {v.lower() for v in available_vibe_contexts}
    available_vibe_mood_set = {v.lower() for v in available_vibe_moods}
    top_lastfm_set = {t.lower() for t in top_lastfm_tags}

    suggested_genres = [g for g in data.get("genres", []) if g in available_genre_names]
    suggested_decades = [d for d in data.get("decades", []) if d in available_decade_names]

    # LLM-suggested moods, restricted to the available vocabulary. Fall back to
    # a keyword scan of the raw prompt for the case where the LLM omits moods.
    llm_moods = [m.lower().strip() for m in data.get("moods", []) if isinstance(m, str)]
    suggested_moods = [m for m in llm_moods if m in available_mood_set]
    if not suggested_moods and available_mood_set:
        prompt_lower = prompt.lower()
        suggested_moods = [m for m in available_moods if m.lower() in prompt_lower]

    llm_vibe_contexts = [v.lower().strip() for v in data.get("vibe_contexts", []) if isinstance(v, str)]
    suggested_vibe_contexts = [v for v in llm_vibe_contexts if v in available_vibe_ctx_set]

    llm_vibe_moods = [v.lower().strip() for v in data.get("vibe_moods", []) if isinstance(v, str)]
    suggested_vibe_moods = [v for v in llm_vibe_moods if v in available_vibe_mood_set]

    llm_lastfm = [t.lower().strip() for t in data.get("lastfm_tags", []) if isinstance(t, str)]
    suggested_lastfm_tags = [t for t in llm_lastfm if t in top_lastfm_set]

    return AnalyzePromptResponse(
        suggested_genres=suggested_genres,
        suggested_decades=suggested_decades,
        suggested_moods=suggested_moods,
        suggested_vibe_contexts=suggested_vibe_contexts,
        suggested_vibe_moods=suggested_vibe_moods,
        suggested_lastfm_tags=suggested_lastfm_tags,
        available_genres=available_genres,
        available_decades=available_decades,
        available_moods=available_moods,
        available_vibe_contexts=available_vibe_contexts,
        available_vibe_moods=available_vibe_moods,
        reasoning=data.get("reasoning", ""),
        token_count=response.total_tokens,
        estimated_cost=response.estimated_cost(),
    )


def _load_available_vibes() -> tuple[list[str], list[str]]:
    """Return (contexts, moods) present in track_vibes."""
    try:
        import json

        from backend.db import get_connection
        with get_connection() as conn:
            ctx_rows = conn.execute(
                "SELECT DISTINCT contexts FROM track_vibes WHERE contexts IS NOT NULL"
            ).fetchall()
            mood_rows = conn.execute(
                "SELECT DISTINCT moods FROM track_vibes WHERE moods IS NOT NULL"
            ).fetchall()
        all_ctx: set[str] = set()
        for row in ctx_rows:
            with contextlib.suppress(Exception):
                all_ctx.update(json.loads(row[0]))
        all_moods: set[str] = set()
        for row in mood_rows:
            with contextlib.suppress(Exception):
                all_moods.update(json.loads(row[0]))
        return sorted(all_ctx), sorted(all_moods)
    except Exception:
        return [], []


def _load_top_lastfm_tags(limit: int = 40) -> list[str]:
    """Return top Last.fm tags by frequency across the library."""
    try:
        import json
        from collections import Counter

        from backend.db import get_connection
        with get_connection() as conn:
            rows = conn.execute(
                "SELECT lastfm_tags FROM track_metadata_ext WHERE lastfm_tags IS NOT NULL"
            ).fetchall()
        counter: Counter = Counter()
        for row in rows:
            try:
                tags = json.loads(row[0])
                for tag in tags:
                    if isinstance(tag, str):
                        counter[tag.lower().strip()] += 1
            except Exception:
                pass
        return [tag for tag, _ in counter.most_common(limit)]
    except Exception:
        return []


def _load_available_moods() -> list[str]:
    """Return moods present in ``track_mood_tags``, else the default vocab."""
    try:
        from backend.audio_features.mood_tagger import DEFAULT_MOODS, get_mood_tag_counts
        from backend.db import get_connection
    except Exception:
        return []

    try:
        with get_connection() as conn:
            counts = get_mood_tag_counts(conn)
    except Exception:
        return list(DEFAULT_MOODS)

    if counts:
        return [c["mood"] for c in counts]
    return list(DEFAULT_MOODS)


async def analyze_track(track: Track) -> AnalyzeTrackResponse:
    """Analyze a seed track to extract musical dimensions.

    Args:
        track: Track to analyze

    Returns:
        AnalyzeTrackResponse with track and dimensions

    Raises:
        ValueError: If LLM response cannot be parsed
        RuntimeError: If LLM client is not initialized
    """
    llm_client = get_llm_client()

    if not llm_client:
        raise RuntimeError("LLM client not initialized")

    analysis_prompt = f"""Analyze this track:
Title: {track.title}
Artist: {track.artist}
Album: {track.album}
Year: {track.year or "Unknown"}
Genres: {", ".join(track.genres) if track.genres else "Unknown"}

Identify 5-7 specific musical dimensions that make this track distinctive."""

    # Call LLM (async)
    response = await llm_client.analyze(analysis_prompt, TRACK_ANALYSIS_SYSTEM)

    data = llm_client.parse_json_response(response)

    dimensions = [
        Dimension(
            id=d.get("id", f"dim_{i}"),
            label=d.get("label", "Unknown dimension"),
            description=d.get("description", ""),
        )
        for i, d in enumerate(data.get("dimensions", []))
    ]

    return AnalyzeTrackResponse(
        track=track,
        dimensions=dimensions,
        token_count=response.total_tokens,
        estimated_cost=response.estimated_cost(),
    )
