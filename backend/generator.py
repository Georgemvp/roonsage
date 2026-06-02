"""Playlist generation with library validation."""

import json
import logging
import random
from collections.abc import AsyncGenerator
from datetime import datetime

from backend import library_cache, llm_cache
from backend.config import get_llm_cache_enabled, get_llm_cache_ttl_seconds
from backend.llm_client import get_llm_client
from backend.models import GenerateResponse, Track
from backend.roon_client import RoonQueryError, get_roon_client
from backend.taste_profile import build_profile_summary

logger = logging.getLogger(__name__)


async def generate_narrative(
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
        # Use analysis model for better creative writing quality (async)
        response = await llm_client.analyze(narrative_prompt, NARRATIVE_SYSTEM)
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
        playlist_title = f"{raw_title} - {date_suffix}" if raw_title else fallback_title

        return playlist_title, narrative

    except Exception as e:
        logger.warning("Narrative generation failed: %s", e)
        return fallback_title, ""


def _cached_track_to_model(cached: dict) -> Track:
    """Convert a cached track dict to a Track model."""
    return Track(
        item_key=cached["item_key"],
        title=cached["title"],
        artist=cached["artist"],
        album=cached["album"],
        duration_ms=cached.get("duration_ms") or 0,
        year=cached.get("year"),
        genres=cached.get("genres") or [],
        art_url=f"/api/art/{cached['item_key']}",
    )


def _get_tracks_from_cache_or_roon(
    roon_client,
    genres: list[str] | None,
    decades: list[str] | None,
    exclude_live: bool,
    max_tracks_to_ai: int,
    vibe_contexts: list[str] | None = None,
    vibe_moods: list[str] | None = None,
) -> list[Track]:
    """Get tracks from cache if available, otherwise from Roon.

    Returns:
        List of Track objects
    """
    has_filters = bool(genres or decades)
    effective_limit = max_tracks_to_ai if max_tracks_to_ai > 0 else 2000

    # Try cache first
    if library_cache.has_cached_tracks():
        logger.info("Using cached tracks for generation")
        cached_tracks = library_cache.get_tracks_by_filters(
            genres=genres,
            decades=decades,
            vibe_contexts=vibe_contexts,
            vibe_moods=vibe_moods,
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
            limit=effective_limit,
        )


def _build_profile_context() -> str:
    """Compact taste profile for the generation prompt.

    Uses mode="generate" — skips genre/decade fields already applied by the
    SQL filter, keeping only artist affinity, moods, and dislikes (~70-90 tokens).
    """
    return build_profile_summary(mode="generate")


async def generate_playlist_stream(
    prompt: str | None = None,
    seed_track: Track | None = None,
    selected_dimensions: list[str] | None = None,
    additional_notes: str | None = None,
    refinement_answers: list[str | None] | None = None,
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    vibe_contexts: list[str] | None = None,
    vibe_moods: list[str] | None = None,
    track_count: int = 25,
    exclude_live: bool = True,
    max_tracks_to_ai: int = 500,
    source_mode: str = "library",   # "library" | "hybrid" | "qobuz"
    qobuz_percentage: int = 30,     # % of Qobuz tracks in hybrid mode
    use_taste_profile: bool = True,
) -> AsyncGenerator[str, None]:
    """Generate a playlist with streaming progress updates (async generator).

    Yields SSE-formatted events with progress updates and final result.

    source_mode:
        "library"  — existing flow, 100% from Roon library cache
        "hybrid"   — library tracks + Qobuz discoveries (qobuz_percentage %)
        "qobuz"    — 100% Qobuz tracks discovered via LLM suggestions
    """
    def emit(event: str, data: dict) -> str:
        return f"event: {event}\ndata: {json.dumps(data)}\n\n"

    try:
        logger.info(
            "Starting playlist generation (streaming) source_mode=%s", source_mode
        )
        llm_client = get_llm_client()
        roon_client = get_roon_client()

        if not llm_client:
            yield emit("error", {"message": "LLM client not initialized"})
            return
        if not roon_client:
            yield emit("error", {"message": "Roon client not initialized"})
            return

        has_filters = bool(genres or decades)
        use_library = source_mode in ("library", "hybrid")
        use_qobuz = source_mode in ("hybrid", "qobuz")

        # Clamp qobuz_percentage to sensible range
        qobuz_percentage = max(10, min(70, qobuz_percentage))

        # Determine how many library vs qobuz tracks to target
        if source_mode == "library":
            library_target = track_count
            qobuz_target = 0
        elif source_mode == "qobuz":
            library_target = 0
            qobuz_target = track_count
        else:  # hybrid
            qobuz_target = max(1, round(track_count * qobuz_percentage / 100))
            library_target = track_count - qobuz_target

        # Step 1: Fetch tracks from cache or Roon (library modes only)
        filtered_tracks: list[Track] = []

        if use_library:
            using_cache = library_cache.has_cached_tracks()
            if using_cache:
                yield emit("progress", {"step": "fetching", "message": "Loading tracks from cache..."})
            elif not has_filters:
                yield emit("progress", {"step": "fetching", "message": "Sampling random tracks from library..."})
            else:
                yield emit("progress", {"step": "fetching", "message": "Fetching tracks from library..."})

            logger.info("Fetching tracks: genres=%s, decades=%s, using_cache=%s",
                        genres, decades, using_cache)
            try:
                filtered_tracks = _get_tracks_from_cache_or_roon(
                    roon_client=roon_client,
                    genres=genres,
                    decades=decades,
                    vibe_contexts=vibe_contexts,
                    vibe_moods=vibe_moods,
                    exclude_live=exclude_live,
                    max_tracks_to_ai=max_tracks_to_ai,
                )
            except RoonQueryError as e:
                yield emit("error", {"message": f"Roon server error: {e}"})
                return

            logger.info("Got %d library tracks", len(filtered_tracks))

            if not filtered_tracks and source_mode == "library":
                yield emit("error", {"message": "No tracks match the selected filters. Try broadening your selection."})
                return
        else:
            yield emit("progress", {"step": "fetching", "message": "Skipping library — Qobuz discovery mode..."})

        # Step 2: Report track count
        if use_library and filtered_tracks:
            if has_filters:
                yield emit("progress", {"step": "filtering", "message": f"Using {len(filtered_tracks)} tracks..."})
            else:
                yield emit("progress", {"step": "filtering", "message": f"Using {len(filtered_tracks)} random tracks..."})

        # Steps 3-6: Library-based LLM generation and track matching.
        # Pure Qobuz mode skips all of this — tracks come from _discover_qobuz_tracks() in step 6b.
        response = None
        track_selections: list = []
        matched_tracks: list[Track] = []
        used_keys: set[str] = set()
        track_reasons: dict[str, str] = {}

        if source_mode != "qobuz":
            # Step 3: Build track list
            yield emit("progress", {"step": "preparing", "message": f"Preparing {len(filtered_tracks)} tracks for AI..."})

            # Fetch enriched tags (MB + Last.fm) for better mood/style curation
            _keys = [t.item_key for t in filtered_tracks]
            try:
                _enriched_tags = library_cache.get_enriched_tags_for_keys(_keys)
            except Exception:
                _enriched_tags = {}
            _enrichment_coverage = len(_enriched_tags) / max(len(_keys), 1)
            if _enriched_tags:
                logger.info(
                    "Enriched tag coverage: %d/%d tracks (%.0f%%)",
                    len(_enriched_tags), len(_keys), _enrichment_coverage * 100,
                )

            # Mood tags from the CLAP K-Means tagger (v13.2). Independent of
            # MB/Last.fm enrichment, so we merge both sources into a single
            # tag list per track.
            try:
                from backend.audio_features.mood_tagger import get_mood_tags_for_keys
                from backend.db import get_connection
                with get_connection() as _mood_conn:
                    _mood_tags = get_mood_tags_for_keys(_mood_conn, _keys)
            except Exception:
                _mood_tags = {}
            if _mood_tags:
                logger.info(
                    "Mood tag coverage: %d/%d tracks (%.0f%%)",
                    len(_mood_tags), len(_keys),
                    len(_mood_tags) / max(len(_keys), 1) * 100,
                )

            # Vibe tags (contexts + moods) from the background AI tagger.
            try:
                from backend.db import get_connection
                from backend.tracks import get_vibe_tags_for_keys
                with get_connection() as _vibe_conn:
                    _vibe_tags = get_vibe_tags_for_keys(_vibe_conn, _keys)
            except Exception:
                _vibe_tags = {}
            if _vibe_tags:
                logger.info(
                    "Vibe tag coverage: %d/%d tracks (%.0f%%)",
                    len(_vibe_tags), len(_keys),
                    len(_vibe_tags) / max(len(_keys), 1) * 100,
                )

            def _fmt_track(i: int, t) -> str:  # type: ignore[no-untyped-def]
                base = f"{i+1}. {t.artist} - {t.title} ({t.album}, {t.year or 'Unknown year'})"
                tags: list[str] = list(_enriched_tags.get(t.item_key, []))
                for m in _mood_tags.get(t.item_key, []):
                    if m and m not in tags:
                        tags.append(m)
                vibe = _vibe_tags.get(t.item_key, {})
                for v in vibe.get("contexts", [])[:2] + vibe.get("moods", [])[:1]:
                    if v and v not in tags:
                        tags.append(v)
                if tags:
                    return f"{base} [{', '.join(tags)}]"
                return base

            track_list = "\n".join(_fmt_track(i, t) for i, t in enumerate(filtered_tracks))

            # Build the generation prompt
            generation_parts = []

            # Add time-of-day context for better mood matching
            now = datetime.now()
            day_names_nl = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"]
            day_name = day_names_nl[now.weekday()]
            hour = now.hour
            if 5 <= hour < 9:
                time_context = f"Het is {day_name}ochtend vroeg ({hour}:00)"
            elif 9 <= hour < 12:
                time_context = f"Het is {day_name}ochtend ({hour}:00)"
            elif 12 <= hour < 14 or 14 <= hour < 17:
                time_context = f"Het is {day_name}middag ({hour}:00)"
            elif 17 <= hour < 21:
                time_context = f"Het is {day_name}avond ({hour}:00)"
            elif 21 <= hour < 24:
                time_context = f"Het is late {day_name}avond ({hour}:00)"
            else:
                time_context = f"Het is {day_name}nacht ({hour}:00)"
            generation_parts.append(f"Context: {time_context}. Houd hier subtiel rekening mee bij de sfeer van de selectie.")

            # Inject taste profile context (gated by use_taste_profile flag)
            if use_taste_profile:
                profile_context = _build_profile_context()
                if profile_context:
                    generation_parts.append(profile_context)
                    logger.info("Taste profile injected into generation prompt (%d chars)", len(profile_context))
            else:
                logger.info("Taste profile skipped (use_taste_profile=False)")

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

            # Step 4: Call LLM (consult cache first to skip repeat requests)
            yield emit("progress", {"step": "ai_working", "message": "AI is curating your playlist..."})

            llm_cfg = llm_client.config
            generation_model = (
                llm_cfg.model_analysis
                if llm_cfg.smart_generation
                else llm_cfg.model_generation
            )
            cache_enabled = get_llm_cache_enabled()
            cache_ttl = get_llm_cache_ttl_seconds()
            cache_key = (
                llm_cache.make_cache_key(
                    generation_prompt, GENERATION_SYSTEM, generation_model
                )
                if cache_enabled
                else None
            )

            response = None
            if cache_key is not None:
                response = llm_cache.get_cached(cache_key, cache_ttl)
                if response is not None:
                    logger.info(
                        "LLM cache hit (playlist generation, key=%s…)",
                        cache_key[:12],
                    )

            if response is None:
                logger.info("Calling LLM with prompt length: %d chars", len(generation_prompt))
                response = await llm_client.generate(generation_prompt, GENERATION_SYSTEM)
                logger.info(
                    "LLM response received: %d input, %d output tokens",
                    response.input_tokens, response.output_tokens,
                )
                if cache_key is not None:
                    llm_cache.set_cached(cache_key, "playlist", response)

            # Step 5: Parse response
            yield emit("progress", {"step": "parsing", "message": "Parsing AI selections..."})

            track_selections = llm_client.parse_json_response(response)

            if not isinstance(track_selections, list):
                yield emit("error", {"message": "LLM returned invalid track selection format"})
                return

            # Step 6: Match tracks
            yield emit("progress", {"step": "matching", "message": f"Matching {len(track_selections)} selections to library..."})

            match_method_counts: dict[str, int] = {"number": 0, "fuzzy": 0, "miss": 0}
            artist_counts: dict[str, int] = {}
            MAX_PER_ARTIST = 2

            if seed_track:
                used_keys.add(seed_track.item_key)

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
                    if track.item_key not in used_keys:
                        artist_lower = track.artist.lower().strip()
                        if artist_counts.get(artist_lower, 0) >= MAX_PER_ARTIST:
                            continue
                        matched_tracks.append(track)
                        used_keys.add(track.item_key)
                        artist_counts[artist_lower] = artist_counts.get(artist_lower, 0) + 1
                        if reason:
                            track_reasons[track.item_key] = reason
                        match_method_counts["number"] += 1
                        continue

                # --- Fallback: fuzzy artist/title matching ---
                artist = selection.get("artist", "")
                title = selection.get("title", "")
                if artist or title:
                    fuzzy_matched = False
                    for track in filtered_tracks:
                        if track.item_key in used_keys:
                            continue
                        if _tracks_match(artist, title, track):
                            artist_lower = track.artist.lower().strip()
                            if artist_counts.get(artist_lower, 0) >= MAX_PER_ARTIST:
                                continue
                            matched_tracks.append(track)
                            used_keys.add(track.item_key)
                            artist_counts[artist_lower] = artist_counts.get(artist_lower, 0) + 1
                            if reason:
                                track_reasons[track.item_key] = reason
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

        # Step 6b: Qobuz discovery (hybrid / qobuz modes)
        qobuz_tracks: list[Track] = []
        if use_qobuz and qobuz_target > 0:
            yield emit("progress", {"step": "qobuz_search", "message": "Zoeken in Qobuz..."})
            user_request_text = prompt or (
                f"{seed_track.title} by {seed_track.artist}" if seed_track else ""
            )
            try:
                qobuz_tracks, qobuz_response = await _discover_qobuz_tracks(
                    llm_client=llm_client,
                    roon_client=roon_client,
                    user_request=user_request_text,
                    target_count=qobuz_target,
                    library_tracks=matched_tracks,
                )
                logger.info("Added %d Qobuz tracks to playlist", len(qobuz_tracks))
                # Use Qobuz LLM response for token counting when no library response exists
                if response is None and qobuz_response is not None:
                    response = qobuz_response
            except Exception as qe:
                logger.warning("Qobuz discovery failed (non-fatal): %s", qe)
                qobuz_tracks = []

            # For pure qobuz mode: replace matched_tracks entirely
            if source_mode == "qobuz":
                matched_tracks = qobuz_tracks
            else:
                # hybrid: append Qobuz tracks to library tracks
                matched_tracks = matched_tracks[:library_target] + qobuz_tracks

            # Re-shuffle so Qobuz tracks are interspersed
            random.shuffle(matched_tracks)

        # Step 7: Generate narrative
        yield emit("progress", {"step": "narrative", "message": "Writing playlist narrative..."})

        playlist_title, narrative = await generate_narrative(
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
                token_count=response.total_tokens if response else 0,
                estimated_cost=response.estimated_cost() if response else 0.0,
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
            first_art_key = matched_tracks[0].item_key if matched_tracks else None
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
                art_item_key=first_art_key,
                subtitle=result_subtitle,
                source_mode=source_mode,
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

        # Fire-and-forget notification (never blocks the SSE stream)
        try:
            from backend.notifications import EventType, event_bus  # noqa: PLC0415
            # Calculate total duration in ms from track durations
            total_ms = sum(
                t.duration_ms for t in result.tracks if t.duration_ms
            )
            event_bus.emit(
                EventType.PLAYLIST_GENERATED,
                {
                    "playlist_name": result.playlist_title,
                    "playlist_title": result.playlist_title,
                    "track_count": len(result.tracks),
                    "duration_ms": total_ms,
                    "prompt": prompt or "",
                },
            )
        except Exception:
            pass

        yield emit("complete", complete_data)
        logger.info("Complete event emitted successfully")

        # Trailing padding to push complete event through network buffers (iOS Safari fix)
        # SSE comments (lines starting with ':') are ignored by the parser but help flush buffers
        yield ": heartbeat\n\n"

    except Exception as e:
        logger.exception("Error during playlist generation")
        yield emit("error", {"message": str(e)})


GENERATION_SYSTEM = """You are a music curator. Select tracks from the numbered library list that best match the user's request.

Tags in square brackets (e.g. [jazz, melancholic, late night]) describe mood and style — use them for emotional or vague requests.

Rules:
- Max 1 track per artist, max 1 per album
- Alternate artists, eras and energy — never group consecutive tracks
- Exclude the seed track itself if one is provided
- If a listening profile is given: favor favorite artists, respect dislikes, avoid high-skip genres

Return ONLY a JSON array:
[{"number": 1, "reason": "one sentence"}, {"number": 42, "reason": "one sentence"}, ...]"""


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


QOBUZ_SUGGESTION_SYSTEM = """You are a music expert recommending tracks available on Qobuz.

Given a user request and optionally existing library tracks as context, suggest tracks that fit the request.
These tracks do NOT need to be in the user's library — recommend anything available commercially.

Return ONLY a JSON array:
[
  {"artist": "Artist Name", "title": "Track Title", "album": "Album Name", "reason": "Why this fits"},
  ...
]

Guidelines:
- Pick tracks that closely match the mood, genre, era, or style of the request
- Avoid picking tracks already in the library list (if provided)
- Be specific with artist and title for accurate search results
- No markdown formatting, no explanations — just the JSON array."""


async def _discover_qobuz_tracks(
    llm_client,
    roon_client,
    user_request: str,
    target_count: int,
    library_tracks: list[Track],
):
    """Ask LLM to suggest tracks and search for them in Qobuz via Roon Browse API.

    Args:
        llm_client: LLM client for suggestions
        roon_client: Roon client for Browse API search
        user_request: Original user prompt
        target_count: How many Qobuz tracks to find
        library_tracks: Already-selected library tracks (context for hybrid mode)

    Returns:
        Tuple of (list of Track objects with source="qobuz", llm_response | None)
    """
    from backend.qobuz_browser import search_qobuz_tracks_sync

    parts = [f"User request: {user_request}"]
    if library_tracks:
        lib_summary = "\n".join(
            f"- {t.artist} - {t.title} ({t.album})"
            for t in library_tracks[:30]
        )
        parts.append(
            f"Already selected from library (do NOT suggest these):\n{lib_summary}"
        )
    parts.append(f"Suggest {target_count} tracks for the request above.")
    suggestion_prompt = "\n\n".join(parts)

    llm_response = None
    try:
        llm_response = await llm_client.generate(suggestion_prompt, QOBUZ_SUGGESTION_SYSTEM)
        suggestions = llm_client.parse_json_response(llm_response)
    except Exception as e:
        logger.warning("Qobuz LLM suggestion call failed: %s", e)
        return [], None

    if not isinstance(suggestions, list):
        logger.warning("Qobuz suggestion response is not a list: %s", type(suggestions).__name__)
        return [], llm_response

    # Search each suggestion in Qobuz
    found_tracks: list[Track] = []
    seen_keys: set[str] = set()

    for suggestion in suggestions:
        if len(found_tracks) >= target_count:
            break

        artist = suggestion.get("artist", "")
        title = suggestion.get("title", "")
        if not artist and not title:
            continue

        search_query = f"{artist} {title}".strip()
        try:
            results = search_qobuz_tracks_sync(roon_client, search_query, limit=5)
        except Exception as e:
            logger.debug("Qobuz search error for '%s': %s", search_query, e)
            continue

        for result in results:
            item_key = result.get("item_key", "")
            if not item_key or item_key in seen_keys:
                continue
            seen_keys.add(item_key)

            track = Track(
                item_key=item_key,
                title=result.get("title") or title,
                artist=result.get("artist") or artist,
                album=result.get("album") or suggestion.get("album", ""),
                duration_ms=0,
                art_url=f"/api/art/{item_key}",
                source="qobuz",
            )
            found_tracks.append(track)
            break  # Take first match per suggestion

    logger.info(
        "Qobuz discovery: requested=%d, suggestions=%d, found=%d",
        target_count, len(suggestions), len(found_tracks),
    )
    return found_tracks, llm_response


def _tracks_match(llm_artist: str, llm_title: str, library_track: Track) -> bool:
    """Check if LLM selection matches a library track.

    Uses fuzzy matching to handle slight variations in naming.
    """
    from rapidfuzz import fuzz

    from backend.roon_client import FUZZ_THRESHOLD, normalize_artist, simplify_string

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
