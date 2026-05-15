"""Playlist generation with library validation."""

import json
import logging
import random
from collections.abc import Generator
from datetime import datetime

from backend.llm_client import get_llm_client
from backend.models import GenerateResponse, Track
from backend.roon_client import RoonQueryError, get_roon_client
from backend import library_cache

logger = logging.getLogger(__name__)


def generate_narrative(
    track_selections: list[dict],
    llm_client,
    user_request: str = "",
    tracks_index: list | None = None,
) -> tuple[str, str]:
    """Generate a creative title and narrative for the playlist.

    Args:
        track_selections: List of dicts. Supports both number-based format
            {"number": N, "reason": "..."} and legacy {"artist": ..., "title": ..., "reason": ...}.
        llm_client: LLM client instance
        user_request: Original user prompt/request for context
        tracks_index: The filtered_tracks list used during generation, needed to map
            number-based selections back to artist/title for the narrative prompt.

    Returns:
        Tuple of (playlist_title with date, narrative)
        On failure, returns ("{Mon YYYY} Playlist", "")
    """
    # Build input for Query 2: track list with reasons
    narrative_lines = []
    for sel in track_selections[:15]:  # Limit to first 15 for context efficiency
        reason = sel.get("reason", "Selected for this playlist")
        track_num = sel.get("number")

        # Number-based format: map back to track data via index
        if track_num is not None and tracks_index is not None:
            try:
                track_num = int(track_num)
            except (TypeError, ValueError):
                track_num = None

        if track_num is not None and tracks_index is not None and 1 <= track_num <= len(tracks_index):
            t = tracks_index[track_num - 1]
            artist = getattr(t, "artist", None) or t.get("artist", "Unknown") if hasattr(t, "get") else getattr(t, "artist", "Unknown")
            title = getattr(t, "title", None) or t.get("title", "Unknown") if hasattr(t, "get") else getattr(t, "title", "Unknown")
        else:
            # Legacy / fallback: use artist/title directly from selection dict
            artist = sel.get("artist", "Unknown")
            title = sel.get("title", "Unknown")

        narrative_lines.append(f'- {artist} - "{title}": {reason}')

    tracks_with_reasons = "\n".join(narrative_lines)

    # Include user request for context
    if user_request:
        narrative_prompt = f"User's request: {user_request}\n\nSelected tracks:\n{tracks_with_reasons}"
    else:
        narrative_prompt = f"Selected tracks:\n{tracks_with_reasons}"

    # Get current month/year for title suffix
    date_suffix = datetime.now().strftime("%b %Y")
    fallback_title = f"{date_suffix} Playlist"

    try:
        # Use analysis model for better creative writing quality
        response = llm_client.analyze(narrative_prompt, NARRATIVE_SYSTEM)
        result = llm_client.parse_json_response(response)

        # Handle array-wrapped responses (some LLMs wrap in [])
        if isinstance(result, list) and len(result) > 0:
            result = result[0]

        if not isinstance(result, dict):
            logger.warning("Narrative response not a dict: %s", type(result).__name__)
            return fallback_title, ""

        raw_title = result.get("title", "").strip()

        # Try common alternate keys for narrative
        narrative = (
            result.get("narrative")
            or result.get("description")
            or result.get("text")
            or result.get("content")
            or ""
        ).strip()

        # Log if we got title but no narrative (helps debug)
        if raw_title and not narrative:
            logger.warning("Narrative missing from response. Keys: %s", list(result.keys()))

        # Append date to title
        if raw_title:
            playlist_title = f"{raw_title} - {date_suffix}"
        else:
            playlist_title = fallback_title

        return playlist_title, narrative

    except Exception as e:
        logger.warning("Narrative generation failed: %s", e)
        return fallback_title, ""


def _cached_track_to_model(cached: dict) -> Track:
    """Convert a cached track dict to a Track model."""
    return Track(
        rating_key=cached["rating_key"],
        title=cached["title"],
        artist=cached["artist"],
        album=cached["album"],
        duration_ms=cached.get("duration_ms") or 0,
        year=cached.get("year"),
        genres=cached.get("genres") or [],
        art_url=f"/api/art/{cached['rating_key']}",
    )


def _get_tracks_from_cache_or_roon(
    roon_client,
    genres: list[str] | None,
    decades: list[str] | None,
    exclude_live: bool,
    min_rating: int,
    max_tracks_to_ai: int,
) -> list[Track]:
    """Get tracks from cache if available, otherwise from Roon.

    Returns:
        List of Track objects
    """
    has_filters = genres or decades or min_rating > 0
    effective_limit = max_tracks_to_ai if max_tracks_to_ai > 0 else 2000

    # Try cache first
    if library_cache.has_cached_tracks():
        logger.info("Using cached tracks for generation")
        cached_tracks = library_cache.get_tracks_by_filters(
            genres=genres,
            decades=decades,
            min_rating=min_rating,
            exclude_live=exclude_live,
            limit=effective_limit,
        )
        return [_cached_track_to_model(t) for t in cached_tracks]

    # Fall back to Roon
    logger.info("Cache empty, fetching from Roon")
    if not has_filters:
        return roon_client.get_random_tracks(
            count=effective_limit,
            exclude_live=exclude_live,
        )
    else:
        return roon_client.get_tracks_by_filters(
            genres=genres,
            decades=decades,
            exclude_live=exclude_live,
            min_rating=min_rating,
            limit=effective_limit,
        )


def generate_playlist_stream(
    prompt: str | None = None,
    seed_track: Track | None = None,
    selected_dimensions: list[str] | None = None,
    additional_notes: str | None = None,
    refinement_answers: list[str | None] | None = None,
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    track_count: int = 25,
    exclude_live: bool = True,
    min_rating: int = 0,
    max_tracks_to_ai: int = 500,
) -> Generator[str, None, None]:
    """Generate a playlist with streaming progress updates.

    Yields SSE-formatted events with progress updates and final result.
    """
    def emit(event: str, data: dict) -> str:
        return f"event: {event}\ndata: {json.dumps(data)}\n\n"

    try:
        logger.info("Starting playlist generation (streaming)")
        llm_client = get_llm_client()
        roon_client = get_roon_client()

        if not llm_client:
            yield emit("error", {"message": "LLM client not initialized"})
            return
        if not roon_client:
            yield emit("error", {"message": "Roon client not initialized"})
            return

        has_filters = genres or decades or min_rating > 0

        # Step 1: Fetch tracks from cache or Roon
        using_cache = library_cache.has_cached_tracks()
        if using_cache:
            yield emit("progress", {"step": "fetching", "message": "Loading tracks from cache..."})
        elif not has_filters:
            yield emit("progress", {"step": "fetching", "message": "Sampling random tracks from library..."})
        else:
            yield emit("progress", {"step": "fetching", "message": "Fetching tracks from library..."})

        logger.info("Fetching tracks: genres=%s, decades=%s, min_rating=%s, using_cache=%s",
                    genres, decades, min_rating, using_cache)
        try:
            filtered_tracks = _get_tracks_from_cache_or_roon(
                roon_client=roon_client,
                genres=genres,
                decades=decades,
                exclude_live=exclude_live,
                min_rating=min_rating,
                max_tracks_to_ai=max_tracks_to_ai,
            )
        except RoonQueryError as e:
            yield emit("error", {"message": f"Roon server error: {e}"})
            return

        logger.info("Got %d tracks", len(filtered_tracks))

        if not filtered_tracks:
            yield emit("error", {"message": "No tracks match the selected filters. Try broadening your selection."})
            return

        # Step 2: Report track count (sampling already done server-side)
        if has_filters:
            yield emit("progress", {"step": "filtering", "message": f"Using {len(filtered_tracks)} tracks..."})
        else:
            yield emit("progress", {"step": "filtering", "message": f"Using {len(filtered_tracks)} random tracks..."})

        # Step 3: Build track list
        yield emit("progress", {"step": "preparing", "message": f"Preparing {len(filtered_tracks)} tracks for AI..."})

        track_list = "\n".join(
            f"{i+1}. {t.artist} - {t.title} ({t.album}, {t.year or 'Unknown year'})"
            for i, t in enumerate(filtered_tracks)
        )

        # Build the generation prompt
        generation_parts = []

        if prompt:
            generation_parts.append(f"User's request: {prompt}")

        if seed_track:
            generation_parts.append(
                f"Seed track: {seed_track.title} by {seed_track.artist} "
                f"(from {seed_track.album}, {seed_track.year or 'Unknown year'})"
            )
            if selected_dimensions:
                generation_parts.append(f"Explore these dimensions: {', '.join(selected_dimensions)}")

        if additional_notes:
            generation_parts.append(f"Additional notes: {additional_notes}")

        if refinement_answers:
            answered = [a for a in refinement_answers if a]
            if answered:
                generation_parts.append(f"User preferences: {', '.join(answered)}")

        generation_parts.append(f"\nSelect {track_count} tracks from this library:\n{track_list}")

        generation_prompt = "\n\n".join(generation_parts)

        # Step 4: Call LLM
        yield emit("progress", {"step": "ai_working", "message": "AI is curating your playlist..."})

        logger.info("Calling LLM with prompt length: %d chars", len(generation_prompt))
        response = llm_client.generate(generation_prompt, GENERATION_SYSTEM)
        logger.info("LLM response received: %d input, %d output tokens", response.input_tokens, response.output_tokens)

        # Step 5: Parse response
        yield emit("progress", {"step": "parsing", "message": "Parsing AI selections..."})

        track_selections = llm_client.parse_json_response(response)

        if not isinstance(track_selections, list):
            yield emit("error", {"message": "LLM returned invalid track selection format"})
            return

        # Step 6: Match tracks
        yield emit("progress", {"step": "matching", "message": f"Matching {len(track_selections)} selections to library..."})

        matched_tracks: list[Track] = []
        used_keys: set[str] = set()
        track_reasons: dict[str, str] = {}
        match_method_counts: dict[str, int] = {"number": 0, "fuzzy": 0, "miss": 0}
        artist_counts: dict[str, int] = {}
        MAX_PER_ARTIST = 2

        if seed_track:
            used_keys.add(seed_track.rating_key)

        for selection in track_selections:
            if len(matched_tracks) >= track_count:
                break

            reason = selection.get("reason", "")

            # --- Primary: direct index lookup by number ---
            track_num = selection.get("number")
            if track_num is not None:
                try:
                    track_num = int(track_num)
                except (TypeError, ValueError):
                    track_num = None

            if track_num is not None and 1 <= track_num <= len(filtered_tracks):
                track = filtered_tracks[track_num - 1]
                if track.rating_key not in used_keys:
                    artist_lower = track.artist.lower().strip()
                    if artist_counts.get(artist_lower, 0) >= MAX_PER_ARTIST:
                        continue
                    matched_tracks.append(track)
                    used_keys.add(track.rating_key)
                    artist_counts[artist_lower] = artist_counts.get(artist_lower, 0) + 1
                    if reason:
                        track_reasons[track.rating_key] = reason
                    match_method_counts["number"] += 1
                    continue

            # --- Fallback: fuzzy artist/title matching ---
            artist = selection.get("artist", "")
            title = selection.get("title", "")
            if artist or title:
                fuzzy_matched = False
                for track in filtered_tracks:
                    if track.rating_key in used_keys:
                        continue
                    if _tracks_match(artist, title, track):
                        artist_lower = track.artist.lower().strip()
                        if artist_counts.get(artist_lower, 0) >= MAX_PER_ARTIST:
                            continue
                        matched_tracks.append(track)
                        used_keys.add(track.rating_key)
                        artist_counts[artist_lower] = artist_counts.get(artist_lower, 0) + 1
                        if reason:
                            track_reasons[track.rating_key] = reason
                        match_method_counts["fuzzy"] += 1
                        fuzzy_matched = True
                        break
                if not fuzzy_matched:
                    match_method_counts["miss"] += 1
            else:
                match_method_counts["miss"] += 1

        total_selections = len(track_selections)
        match_rate = len(matched_tracks) / total_selections if total_selections else 0
        logger.info(
            "Track matching complete — method breakdown: number=%d fuzzy=%d miss=%d | "
            "match_rate=%.0f%% (%d/%d)",
            match_method_counts["number"],
            match_method_counts["fuzzy"],
            match_method_counts["miss"],
            match_rate * 100,
            len(matched_tracks),
            total_selections,
        )

        # Shuffle to break any artist/genre clustering from the LLM output order
        random.shuffle(matched_tracks)

        # Step 7: Generate narrative
        yield emit("progress", {"step": "narrative", "message": "Writing playlist narrative..."})

        playlist_title, narrative = generate_narrative(
            track_selections, llm_client, prompt or "", tracks_index=filtered_tracks
        )
        logger.info("Generated narrative: title='%s', narrative_len=%d", playlist_title, len(narrative))

        # Emit narrative event for frontend
        yield emit("narrative", {
            "playlist_title": playlist_title,
            "narrative": narrative,
            "track_reasons": track_reasons,
            "user_request": prompt or "",
        })

        # Step 8: Complete
        logger.info("Track matching complete. Matched %d tracks", len(matched_tracks))
        logger.info("Emitting 'Playlist ready!' progress event")
        yield emit("progress", {"step": "complete", "message": "Playlist ready!"})

        logger.info("Building GenerateResponse: tokens=%s, cost=%s",
                    getattr(response, 'total_tokens', 'N/A'),
                    response.estimated_cost() if response else 'N/A')

        try:
            result = GenerateResponse(
                tracks=matched_tracks,
                token_count=response.total_tokens,
                estimated_cost=response.estimated_cost(),
                playlist_title=playlist_title,
                narrative=narrative,
                track_reasons=track_reasons,
            )
            logger.info("GenerateResponse built successfully with %d tracks", len(result.tracks))
        except Exception as e:
            logger.exception("Failed to build GenerateResponse: %s", e)
            yield emit("error", {"message": f"Failed to build response: {e}"})
            return

        # Send tracks in batches to work around iOS Safari dropping large SSE events.
        # Safari Mobile has undocumented buffering limits that can cause large events
        # to be silently dropped. Batching keeps each event small (~2KB).
        tracks_data = [t.model_dump(mode="json") for t in result.tracks]
        batch_size = 5
        for i in range(0, len(tracks_data), batch_size):
            batch = tracks_data[i:i + batch_size]
            logger.info("Emitting track batch %d-%d", i, i + len(batch))
            yield emit("tracks", {"batch": batch, "index": i})

        # Save result to history before emitting the final event
        result_id = None
        try:
            result_type = "seed_playlist" if seed_track else "prompt_playlist"
            # Title: always use the LLM-generated playlist title
            result_title = playlist_title
            # Use first track's rating key for card thumbnail
            first_art_key = matched_tracks[0].rating_key if matched_tracks else None
            # Subtitle: seed playlists show origin track, prompt playlists show prompt + count
            if seed_track:
                result_subtitle = f"From: {seed_track.title} by {seed_track.artist} \u00b7 {len(matched_tracks)} tracks"
            elif prompt:
                result_subtitle = f"{prompt} \u00b7 {len(matched_tracks)} tracks"
            else:
                result_subtitle = f"{len(matched_tracks)} tracks"
            result_id = library_cache.save_result(
                result_type=result_type,
                title=result_title,
                prompt=prompt or "",
                snapshot=result.model_dump(mode="json"),
                track_count=len(matched_tracks),
                art_rating_key=first_art_key,
                subtitle=result_subtitle,
            )
        except Exception as e:
            logger.warning("Failed to save result: %s", e)

        # Emit small complete event with just metadata
        logger.info("Emitting complete event")
        complete_data = {
            "track_count": len(result.tracks),
            "token_count": result.token_count,
            "estimated_cost": result.estimated_cost,
            "playlist_title": result.playlist_title,
            "narrative": result.narrative,
            "track_reasons": result.track_reasons,
        }
        if result_id:
            complete_data["result_id"] = result_id
        yield emit("complete", complete_data)
        logger.info("Complete event emitted successfully")

        # Trailing padding to push complete event through network buffers (iOS Safari fix)
        # SSE comments (lines starting with ':') are ignored by the parser but help flush buffers
        yield ": heartbeat\n\n"

    except Exception as e:
        logger.exception("Error during playlist generation")
        yield emit("error", {"message": str(e)})


GENERATION_SYSTEM = """You are a music curator creating a playlist from a user's music library.

You will be given:
1. A description of what the user wants (prompt, seed track dimensions, or both)
2. A numbered list of tracks that are available in their library

Your task is to select tracks that best match the user's request. For each track, include a brief reason (1 sentence) explaining why it fits.

Guidelines:
- Select tracks that fit the mood, era, style, and other aspects of the request
- STRICT: Pick at most 1 track per artist. Only pick a 2nd track from the same artist when fewer unique artists are available than the requested track count
- STRICT: Do not pick more than 1 track from the same album
- Shuffle your output order — never group consecutive tracks by the same artist, decade, or genre. Alternate between different artists, eras, and energy levels for a varied listening flow
- If using a seed track, don't include the seed track itself in the results

Return ONLY a JSON array using the track NUMBER from the list, like:
[
  {"number": 1, "reason": "Brief explanation of why this track fits."},
  {"number": 42, "reason": "Brief explanation of why this track fits."},
  ...
]

No markdown formatting, no explanations - just the JSON array."""


NARRATIVE_SYSTEM = """You are a music connoisseur writing a brief liner note for a playlist.

Given the user's original request and the track selections (with reasons), create:
1. A creative playlist title (2-5 words, evocative, do NOT include any date)
2. A brief narrative (3 sentences, under 400 characters) that:
   - Reflects the mood or theme the user asked for
   - Mentions 3-4 specific songs by name (use single quotes around song names, e.g. 'Skinny Love')

Sound like a passionate music lover. Be concise.

Return ONLY valid JSON:
{"title": "Creative Title Here", "narrative": "Your brief narrative with 'song names' in single quotes..."}

No markdown formatting, no explanations - just the JSON object."""


def _tracks_match(llm_artist: str, llm_title: str, library_track: Track) -> bool:
    """Check if LLM selection matches a library track.

    Uses fuzzy matching to handle slight variations in naming.
    """
    from rapidfuzz import fuzz
    from backend.roon_client import simplify_string, normalize_artist, FUZZ_THRESHOLD

    # Compare titles
    simplified_llm_title = simplify_string(llm_title)
    simplified_lib_title = simplify_string(library_track.title)

    if fuzz.ratio(simplified_llm_title, simplified_lib_title) < FUZZ_THRESHOLD:
        return False

    # Compare artists (with variations)
    for artist_variant in normalize_artist(llm_artist):
        simplified_artist = simplify_string(artist_variant)
        simplified_lib_artist = simplify_string(library_track.artist)
        if fuzz.ratio(simplified_artist, simplified_lib_artist) >= FUZZ_THRESHOLD:
            return True

    return False
