# Claude Desktop configuration - add to ~/Library/Application Support/Claude/claude_desktop_config.json:
# {
#   "mcpServers": {
#     "roonsage": {
#       "command": "python3",
#       "args": ["/FULL/PATH/TO/roonsage/mcp_server.py"]
#     }
#   }
# }

"""
RoonSage MCP Server

Wraps the RoonSage REST API as MCP tools for Claude Desktop.
Claude Desktop handles all reasoning; this server provides library data and Roon connectivity.

Requirements:
    pip install "mcp[cli]" httpx

Environment variables:
    ROONSAGE_URL  Base URL of the running RoonSage app (default: http://localhost:5765)
"""

import asyncio
import json
import os
from typing import AsyncGenerator, Optional

import httpx
from mcp.server.fastmcp import FastMCP

import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | MCP | %(levelname)s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("roonsage.mcp")

ROONSAGE_URL = os.environ.get("ROONSAGE_URL", "http://localhost:5765").rstrip("/")
TIMEOUT = 30.0
STREAM_TIMEOUT = 300.0  # 5 minutes for SSE streams
PLAYBACK_TIMEOUT = 180.0  # 3 minutes for curate_and_play (30+ tracks × 4 Roon Browse calls each)

mcp = FastMCP("roonsage")

# ---------------------------------------------------------------------------
# Persistent HTTP clients (reused across all tool calls)
# ---------------------------------------------------------------------------

_client = httpx.AsyncClient(timeout=TIMEOUT)
_stream_client = httpx.AsyncClient(timeout=STREAM_TIMEOUT)
_playback_client = httpx.AsyncClient(timeout=PLAYBACK_TIMEOUT)


def _unavailable_msg() -> str:
    return (
        f"RoonSage is not reachable at {ROONSAGE_URL}. "
        "Make sure the application is running (uvicorn backend.main:app --port 5765)."
    )


async def _api_call(method: str, path: str, **kwargs) -> dict | list | str:
    """Make an API call to RoonSage, handling errors uniformly."""
    try:
        logger.info("API %s %s", method, path)
        response = await _client.request(method, f"{ROONSAGE_URL}{path}", **kwargs)
        response.raise_for_status()
        data = response.json()
        if isinstance(data, list):
            logger.info("API %s %s -> %d items", method, path, len(data))
        elif isinstance(data, dict):
            logger.info("API %s %s -> keys: %s", method, path, list(data.keys()))
        return data
    except httpx.ConnectError:
        logger.error("API %s %s -> CONNECT ERROR", method, path)
        return _unavailable_msg()
    except httpx.HTTPStatusError as exc:
        logger.error("API %s %s -> HTTP %d: %s", method, path, exc.response.status_code, exc.response.text[:200])
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"


async def _parse_sse_events(response) -> AsyncGenerator[tuple[str, dict], None]:
    """Parse SSE stream, yielding (event_type, payload) tuples."""
    event_type = "message"
    async for line in response.aiter_lines():
        line = line.strip()
        if not line:
            event_type = "message"
            continue
        if line.startswith("event:"):
            event_type = line[6:].strip()
        elif line.startswith("data:"):
            raw = line[5:].strip()
            try:
                payload = json.loads(raw)
                yield event_type, payload
            except json.JSONDecodeError:
                continue


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_library_stats() -> str:
    """Return statistics about the user's Roon music library cached in RoonSage.

    Shows total track count, available genres, and available decades.
    Use this first to understand what music is in the library before filtering
    or generating playlists. No parameters required.
    """
    logger.info("GET_LIBRARY_STATS called")
    result = await _api_call("GET", "/api/library/stats/cached")
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def search_library(query: str) -> str:
    """Search the music library by track title, artist name, or album name.

    Searches the local SQLite cache first (67k+ tracks, instant, works offline),
    then falls back to the live Roon API if the cache returns no results.
    This means the tool reliably finds artists, albums, and tracks even when
    Roon is temporarily unreachable.

    Returns matching tracks with their item_key (needed for play/queue operations),
    title, artist, album, year, and genres. Use this when the user asks for
    specific artists, songs, or albums, or wants to find something particular
    in the library.

    Args:
        query: Search term — track title, artist name, or album name.
    """
    logger.info("SEARCH_LIBRARY: query='%s'", query)
    result = await _api_call("GET", "/api/library/search", params={"q": query})
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def filter_tracks(
    genres: Optional[list[str]] = None,
    decades: Optional[list[str]] = None,
    exclude_live: bool = True,
    max_tracks: int = 200,
    output_format: str = "json",
    artist_limit: int = 2,
    exclude_keywords: Optional[list[str]] = None,
) -> str:
    """Filter the Roon library by genre, decade, and/or live-version exclusion.

    Returns a list of tracks that match all specified criteria. Each track includes
    its item_key (required for play/queue), title, artist, and album.

    Use this to narrow the library before selecting tracks for a playlist.
    Call get_library_stats first to see which genres and decades are available.

    To avoid overloading Claude's context, only the first `max_tracks` results are
    returned; the response also reports the full total so you know how large the
    filtered pool is.

    OUTPUT FORMAT:
    - Use output_format='json' (default) for full JSON with all track metadata.
      Use this when you need detailed metadata for other operations.
    - Use output_format='compact' when you want to personally curate a playlist
      from the results. Returns a numbered text list (token-efficient) plus a
      session_id for playback via curate_and_play. Default max_tracks is 500.
    - Use output_format='ultra' for the most token-efficient format. Each line
      is only "nr. Artist — Title" — no album, year, or genres. Best for large
      libraries. Default max_tracks is 500.

    Args:
        genres:           List of genre strings to include, e.g. ["Jazz", "Blues"].
                          Pass None or omit to include all genres.
        decades:          List of decade strings to include, e.g. ["1990s", "2000s"].
                          Pass None or omit to include all decades.
        exclude_live:     When True (default), tracks with "live", "concert", or year
                          patterns in their title or album name are excluded.
        max_tracks:       Maximum number of tracks to return (default 200 for json,
                          500 for compact/ultra). The full total is always reported.
        output_format:    "json" (default) — full JSON per track.
                          "compact" — numbered text list + session_id, token-efficient.
                          "ultra" — only "nr. Artist — Title" per line, most efficient.
        artist_limit:     Max tracks per artist in stratified sampling (default 2).
                          Use 1 to force maximum artist diversity.
        exclude_keywords: Exclude tracks whose title or album contains any of these
                          words (case-insensitive). E.g. ["christmas", "live", "karaoke"].
    """
    logger.info("FILTER_TRACKS: genres=%s decades=%s format=%s max=%d", genres, decades, output_format, max_tracks)
    # Default max_tracks for compact/ultra modes
    if output_format in ("compact", "ultra") and max_tracks == 200:
        max_tracks = 500

    body: dict = {
        "exclude_live": exclude_live,
        "max_tracks": max_tracks,
        "artist_limit": artist_limit,
    }
    if genres:
        body["genres"] = genres
    if decades:
        body["decades"] = decades
    if exclude_keywords:
        body["exclude_keywords"] = exclude_keywords

    try:
        response = await _client.post(f"{ROONSAGE_URL}/api/library/filter", json=body)
        response.raise_for_status()
        data = response.json()
    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.HTTPStatusError as exc:
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"

    tracks = data.get("tracks", [])
    total = data.get("total_matching", 0)
    returned = data.get("returned", len(tracks))

    # -----------------------------------------------------------------------
    # Ultra-compact output: only "nr. Artist — Title" per line
    # -----------------------------------------------------------------------
    if output_format == "ultra":
        lines: list[str] = []
        key_map: dict[str, str] = {}
        for i, track in enumerate(tracks, start=1):
            item_key = track.get("rating_key") or track.get("item_key") or ""
            key_map[str(i)] = item_key
            lines.append(f"{i}. {track.get('artist', '?')} — {track.get('title', '?')}")

        session_id = ""
        try:
            store_resp = await _client.post(
                f"{ROONSAGE_URL}/api/library/filter/session",
                json={"key_map": key_map, "total_matching": total, "returned": returned},
            )
            store_resp.raise_for_status()
            session_id = store_resp.json().get("session_id", "")
        except Exception:
            pass

        result: dict = {
            "total_matching": total,
            "returned": returned,
            "tracks": "\n".join(lines),
            "session_id": session_id,
            "note": (
                "Ultra-compact formaat. Selecteer tracks op nummer. "
                "Gebruik session_id met curate_and_play."
            ),
        }
        if not session_id:
            result["key_map"] = key_map
        if total > returned:
            result["pool_note"] = (
                f"Library bevat {total} matching tracks; {returned} geretourneerd "
                "(stratified steekproef per artiest)."
            )
        return json.dumps(result, ensure_ascii=False, indent=2)

    # -----------------------------------------------------------------------
    # Compact output: numbered text list + server-side session for curation
    # -----------------------------------------------------------------------
    if output_format == "compact":
        lines: list[str] = []
        key_map: dict[str, str] = {}
        for i, track in enumerate(tracks, start=1):
            item_key = track.get("rating_key") or track.get("item_key") or ""
            key_map[str(i)] = item_key
            genres_str = ", ".join(track.get("genres") or [])
            year = track.get("year") or ""
            line = (
                f"{i}. {track.get('artist', '?')} — {track.get('title', '?')} "
                f"[{track.get('album', '?')}] ({year}) | {genres_str}"
            )
            lines.append(line)

        # Store key_map server-side — get a session_id back so it doesn't
        # need to travel through Claude's context window (~10-20k tokens saved).
        session_id = ""
        try:
            store_resp = await _client.post(
                f"{ROONSAGE_URL}/api/library/filter/session",
                json={"key_map": key_map, "total_matching": total, "returned": returned},
            )
            store_resp.raise_for_status()
            session_id = store_resp.json().get("session_id", "")
        except Exception:
            # Fallback: if server-side storage fails, include key_map directly
            # so curate_and_play can still work (it handles both paths).
            pass

        result: dict = {
            "total_matching": total,
            "returned": returned,
            "tracks": "\n".join(lines),
            "session_id": session_id,
            "note": (
                "Selecteer tracks op nummer. Gebruik session_id met curate_and_play "
                "om de selectie af te spelen. De key_map is server-side opgeslagen."
            ),
        }
        if not session_id:
            # Fallback: include key_map so curate_and_play can still work
            result["key_map"] = key_map
            result["note"] = (
                "Server-side sessie-opslag mislukt. key_map is meegestuurd als fallback. "
                "Gebruik curate_and_play met key_map in plaats van session_id."
            )
        if total > returned:
            result["pool_note"] = (
                f"Library bevat {total} matching tracks; {returned} geretourneerd "
                "(stratified steekproef per artiest)."
            )
        return json.dumps(result, ensure_ascii=False, indent=2)

    # -----------------------------------------------------------------------
    # JSON output (default): strip to essential fields
    # -----------------------------------------------------------------------
    _KEEP = {"item_key", "rating_key", "title", "artist", "album", "genres"}
    data["tracks"] = [
        {k: v for k, v in track.items() if k in _KEEP}
        for track in tracks
    ]

    # Add a note when results are capped so Claude knows the real pool size
    if total > returned:
        data["note"] = (
            f"Library contains {total} matching tracks; {returned} returned "
            "(random sample). Use the item_key / rating_key of each track for playback."
        )
    else:
        data["note"] = "Use the rating_key of each track as item_key for play_tracks / queue_tracks."

    return json.dumps(data, ensure_ascii=False, indent=2)


@mcp.tool()
async def list_zones() -> str:
    """List all active Roon playback zones available on the Roon Core.

    Returns each zone's zone_id and display_name. The zone_id is required
    for play_tracks and queue_tracks. Use this to let the user choose where
    music should play, or to find the right zone by name.
    """
    logger.info("LIST_ZONES called")
    result = await _api_call("GET", "/api/roon/zones")
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def play_tracks(item_keys: list[str], zone_id: str) -> str:
    """Send a list of tracks to a Roon zone for immediate playback.

    Replaces the current queue in the specified zone and starts playing
    from the first track. Use this when the user says "play", "start", or
    "put on" a playlist or set of tracks.

    Args:
        item_keys: List of track item_key strings from search_library or
                   filter_tracks. These are Roon's internal track identifiers.
        zone_id:   The Roon zone to play in — obtain via list_zones.
    """
    logger.info("PLAY_TRACKS: zone=%s keys=%d", zone_id, len(item_keys))
    try:
        response = await _playback_client.post(
            f"{ROONSAGE_URL}/api/queue",
            json={"item_keys": item_keys, "zone_id": zone_id},
        )
        response.raise_for_status()
        data = response.json()
        return json.dumps(data, ensure_ascii=False, indent=2)
    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.HTTPStatusError as exc:
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"


@mcp.tool()
async def queue_tracks(item_keys: list[str], zone_id: str) -> str:
    """Append tracks to the current Roon queue without interrupting playback.

    Adds the specified tracks to the end of the queue in the given zone.
    The currently playing track continues uninterrupted. Use this when the
    user says "add to queue", "queue up", or "play next/after".

    Args:
        item_keys: List of track item_key strings from search_library or
                   filter_tracks. These are Roon's internal track identifiers.
        zone_id:   The Roon zone to append to — obtain via list_zones.
    """
    logger.info("QUEUE_TRACKS: zone=%s keys=%d", zone_id, len(item_keys))
    try:
        response = await _playback_client.post(
            f"{ROONSAGE_URL}/api/queue/append",
            json={"item_keys": item_keys, "zone_id": zone_id},
        )
        response.raise_for_status()
        data = response.json()
        return json.dumps(data, ensure_ascii=False, indent=2)
    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.HTTPStatusError as exc:
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"


@mcp.tool()
async def curate_and_play(
    track_numbers: list[int],
    session_id: str,
    zone_id: str,
    playlist_name: str = "Claude Curated",
    append: bool = False,
) -> str:
    """Play a curated selection of tracks chosen by Claude from filter_tracks compact output.

    After calling filter_tracks with output_format='compact', select the best tracks
    by number and pass them here with the session_id from the filter response.
    The server translates track numbers to Roon item_keys using the stored key_map
    (which never needs to travel through Claude's context window).

    Curation guidelines to apply before calling this tool:
    - Aim for 15–50 tracks depending on the request.
    - Artiest diversity: max 1 track per artist; 2 only when exceptional.
    - Album diversity: max 2 tracks per album.
    - Flow: alternate tempo, decades, and styles.
    - No clustering: never place 2 tracks from the same artist consecutively.

    Args:
        track_numbers: List of track numbers from the compact list, in the desired
                       play order. E.g. [3, 17, 42, 8, ...].
        session_id:    The session_id returned by filter_tracks (compact mode).
                       The server uses this to look up the stored key_map.
        zone_id:       Roon zone ID to play in — obtain via list_zones.
        playlist_name: Optional label for the playlist (used in the response
                       summary only; Roon cannot save playlists via the API).
        append:        If True, append tracks to the current queue instead of
                       replacing it. Default False (replaces queue).
    """
    logger.info("CURATE_AND_PLAY: session=%s zone=%s tracks=%d playlist='%s' append=%s", session_id, zone_id, len(track_numbers), playlist_name, append)
    try:
        response = await _playback_client.post(
            f"{ROONSAGE_URL}/api/library/filter/curate",
            json={
                "session_id": session_id,
                "track_numbers": track_numbers,
                "zone_id": zone_id,
                "append": append,
            },
        )
        response.raise_for_status()
        data = response.json()
    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.HTTPStatusError as exc:
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"

    tracks_queued = data.get("tracks_queued", 0)
    tracks_skipped = data.get("tracks_skipped", 0)
    zone_name = data.get("zone_name", zone_id)

    result: dict = {
        "success": data.get("success", False),
        "playlist_name": playlist_name,
        "tracks_queued": tracks_queued,
        "tracks_skipped": tracks_skipped,
        "zone_name": zone_name,
        "action": "appended" if append else "replaced queue",
        "playback_started": tracks_queued > 0,
        "note": (
            f"Muziek speelt al op {zone_name}. "
            f"{tracks_queued} tracks gequeued"
            + (f", {tracks_skipped} overgeslagen" if tracks_skipped else "")
            + ". NIET opnieuw sturen."
        ) if tracks_queued > 0 else "Geen tracks gequeued. Controleer de sessie en zone.",
    }
    if data.get("missing_numbers"):
        result["warning"] = f"Track numbers not found (skipped): {data['missing_numbers']}"

    # Include resolved_tracks so Claude shows the actual queued tracklist,
    # never a hallucinated reconstruction from memory.
    if data.get("resolved_tracks"):
        result["resolved_tracks"] = data["resolved_tracks"]

    logger.info("CURATE_AND_PLAY RESULT: success=%s queued=%d skipped=%d zone='%s' missing=%s", result.get("success"), tracks_queued, tracks_skipped, zone_name, result.get("warning", "none"))
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def validate_playlist(
    session_id: str,
    track_numbers: list[int],
    max_per_artist: int = 2,
) -> str:
    """Validate a curated track selection for quality issues before playback.

    After curating track numbers from filter_tracks compact/ultra output, call this
    tool to detect common playlist mistakes:
    - Duplicates: same artist + title selected at two different positions
    - Clustering: same artist on consecutive positions (bad flow)
    - Overrepresentation: more than max_per_artist tracks from the same artist

    Returns {"valid": true/false, "warnings": [...]} where each warning has
    "type", "positions", "artist", and optionally "title", "count", "max".

    Fix warnings before calling curate_and_play:
    - For duplicates: remove the second occurrence
    - For clustering: swap or remove one of the consecutive tracks
    - For overrepresentation: remove excess tracks from the overrepresented artist

    Args:
        session_id:     Session ID from filter_tracks (compact or ultra format).
        track_numbers:  Ordered list of selected track numbers to validate.
        max_per_artist: Maximum acceptable tracks per artist (default 2).
    """
    logger.info("VALIDATE_PLAYLIST: session=%s tracks=%d", session_id, len(track_numbers))
    result = await _api_call(
        "POST",
        "/api/library/filter/validate",
        json={
            "session_id": session_id,
            "track_numbers": track_numbers,
            "max_per_artist": max_per_artist,
        },
    )
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def sync_library() -> str:
    """Trigger a library sync to refresh the local cache from Roon.
    Use this when library stats show 0 tracks or when the user asks to refresh/sync their library.
    The sync runs in the background — it may take a minute for large libraries."""
    logger.info("SYNC_LIBRARY called")
    result = await _api_call("POST", "/api/library/sync")
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


def _build_playlist_result(
    all_tracks: list[dict],
    complete_data: dict,
    track_count: int,
    exclude_live: bool,
) -> dict:
    """Build a compact playlist result dict with genre breakdown and live-exclusion note.

    Trims to exactly `track_count` tracks. Adds genre_breakdown summary.
    """
    # Trim to exact requested count
    tracks = all_tracks[:track_count]

    # Build genre breakdown
    genre_counts: dict[str, int] = {}
    for t in tracks:
        for g in (t.get("genres") or []):
            genre_counts[g] = genre_counts.get(g, 0) + 1

    genre_breakdown = " | ".join(
        f"{g}: {c}" for g, c in sorted(genre_counts.items(), key=lambda x: -x[1])
    ) if genre_counts else ""

    extra_tracks = all_tracks[track_count:]

    result: dict = {
        "playlist_title": complete_data.get("playlist_title", "Generated Playlist"),
        "narrative": complete_data.get("narrative", ""),
        "track_count": len(tracks),
        "token_count": complete_data.get("token_count", 0),
        "estimated_cost_usd": complete_data.get("estimated_cost", 0.0),
        "live_excluded": exclude_live,
        "tracks": [
            {
                "item_key": t.get("rating_key", t.get("item_key", "")),
                "title": t.get("title", ""),
                "artist": t.get("artist", ""),
                "album": t.get("album", "") or "Unknown Album",
                "year": t.get("year"),
            }
            for t in tracks
        ],
    }

    if genre_breakdown:
        result["genre_breakdown"] = genre_breakdown

    if exclude_live:
        result["note_live"] = "Live versies uitgesloten (exclude_live=true)"

    # If more tracks were generated than requested, offer to queue the rest
    if extra_tracks:
        extra_keys = [t.get("rating_key", t.get("item_key", "")) for t in extra_tracks if t.get("rating_key") or t.get("item_key")]
        result["extra_tracks_available"] = len(extra_tracks)
        result["extra_item_keys"] = extra_keys[:50]  # cap to 50 extras
        result["note_extra"] = (
            f"{len(extra_tracks)} extra track(s) were generated but not included. "
            "Use queue_tracks with extra_item_keys to add them to the queue."
        )

    if complete_data.get("result_id"):
        result["result_id"] = complete_data["result_id"]

    return result


async def _stream_generate(body: dict) -> tuple[list[dict], dict, list[str]]:
    """Stream from /api/generate/stream and return (all_tracks, complete_data, errors)."""
    tracks_batches: list[list[dict]] = []
    complete_data: dict = {}
    errors: list[str] = []

    async with _stream_client.stream(
        "POST",
        f"{ROONSAGE_URL}/api/generate/stream",
        json=body,
    ) as response:
        if response.status_code != 200:
            await response.aread()
            errors.append(f"RoonSage API error: {response.status_code} — {response.text}")
            return [], {}, errors

        async for event_type, payload in _parse_sse_events(response):
            if event_type == "tracks":
                batch = payload.get("batch", [])
                if batch:
                    tracks_batches.append(batch)
            elif event_type == "complete":
                complete_data = payload
            elif event_type == "error":
                errors.append(payload.get("message", "Unknown error"))

    all_tracks = [track for batch in tracks_batches for track in batch]
    return all_tracks, complete_data, errors


@mcp.tool()
async def generate_playlist(
    prompt: str,
    genres: Optional[list[str]] = None,
    decades: Optional[list[str]] = None,
    track_count: int = 25,
    exclude_live: bool = True,
    source_mode: str = "library",
    qobuz_percentage: int = 30,
) -> str:
    """Generate an AI-curated playlist from the Roon library using a natural language prompt.

    IMPORTANT — choosing the right tool:
    - If the user mentions a SPECIFIC SONG/TRACK as the starting point (e.g. "maak een playlist
      gebaseerd op Moondance van Van Morrison", "more like this song", "in the style of ..."),
      FIRST use search_library to find that track, then use seed_track_playlist instead.
    - Use generate_playlist for mood/occasion/genre requests without a specific seed track.

    Calls the RoonSage streaming generation endpoint and returns the final playlist with
    track list, album info, year, genre breakdown, and live-exclusion status.
    This may take 30–90 seconds for the AI to curate and match tracks.

    After generation, use play_tracks or queue_tracks with the returned item_keys to start
    playback. If extra tracks were generated (extra_item_keys field), use queue_tracks to
    add them.

    Args:
        prompt:           Natural language description, e.g. "upbeat 90s indie rock for a
                          road trip" or "calm jazz for late-night studying".
        genres:           Optional genre filters, e.g. ["Jazz", "Rock"].
                          Pass None to let the AI choose from the full library.
        decades:          Optional decade filters, e.g. ["1990s", "2000s"].
                          Pass None to include all decades.
        track_count:      Exact number of tracks to generate (default 25). Any positive integer.
        exclude_live:     When True (default), live and concert recordings are excluded.
                          Pass False to include live versions.
        source_mode:      "library" (default) — only tracks from the Roon library.
                          "hybrid" — mix of library tracks + Qobuz discoveries.
                          "qobuz" — only new music from Qobuz streaming.
        qobuz_percentage: For hybrid mode, percentage of tracks sourced from Qobuz (default 30).
                          Ignored when source_mode is "library" or "qobuz".
    """
    logger.info("GENERATE_PLAYLIST: prompt='%s' source=%s tracks=%d", prompt[:80], source_mode, track_count)
    body: dict = {
        "prompt": prompt,
        "track_count": track_count,
        "exclude_live": exclude_live,
        "source_mode": source_mode,
        "qobuz_percentage": qobuz_percentage,
    }
    if genres:
        body["genres"] = genres
    if decades:
        body["decades"] = decades

    try:
        all_tracks, complete_data, errors = await _stream_generate(body)
    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.ReadTimeout:
        return "Playlist generation timed out. The library may be very large or the LLM is slow. Try again."
    except httpx.HTTPStatusError as exc:
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"

    if errors:
        return f"Playlist generation failed: {'; '.join(errors)}"

    if not all_tracks and not complete_data:
        return "Playlist generation produced no results. Try a different prompt or check that the library is synced."

    result = _build_playlist_result(all_tracks, complete_data, track_count, exclude_live)
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def get_now_playing() -> str:
    """Return the currently playing track info for each active Roon zone.

    Calls the Roon zones endpoint and returns all zones with their playback
    state. Use this for context-aware requests like "more like what's playing
    now" — first call this tool to find out what's currently playing, then
    use that info to craft a prompt for generate_playlist.

    Note: The Roon Extension API exposes zone state (playing/paused/stopped)
    but not the currently playing track title or artist directly. Use
    search_library to find a specific track if needed.
    """
    logger.info("GET_NOW_PLAYING called")
    result = await _api_call("GET", "/api/roon/zones")
    if isinstance(result, str):
        return result

    zones = result
    if not zones:
        return json.dumps({"zones": [], "note": "No Roon zones found. Check that Roon Core is running and RoonSage is authorized."})

    # Filter to active (non-stopped) zones and annotate
    active = [z for z in zones if z.get("state") != "stopped"]
    summary = {
        "zones": zones,
        "active_zones": active,
        "note": (
            f"{len(active)} of {len(zones)} zone(s) currently playing. "
            "Use zone_id from this list with play_tracks or queue_tracks."
        ),
    }
    return json.dumps(summary, ensure_ascii=False, indent=2)


@mcp.tool()
async def recommend_album(
    prompt: str,
    mode: str = "library",
) -> str:
    """Get an AI album recommendation based on a mood or moment description.

    Runs the full RoonSage recommendation pipeline: generates clarifying questions
    (skipped for MCP simplicity), then selects and pitches an album. For library mode
    the recommendation comes from the user's own Roon library; for discovery mode it
    suggests albums the user may not have.

    This may take 60–120 seconds as it involves multiple LLM calls and optional
    MusicBrainz research.

    Args:
        prompt: Mood, occasion, or taste description, e.g. "something warm and
                melancholic for a rainy Sunday evening" or "energetic album to
                kick off a workout".
        mode:   "library" (default) — recommend from the user's Roon library.
                "discovery" — suggest albums the user probably doesn't own yet.
    """
    logger.info("RECOMMEND_ALBUM: prompt='%s' mode=%s", prompt[:80], mode)
    # Step 1: Create a session via the questions endpoint (required to get a session_id)
    q_data = await _api_call("POST", "/api/recommend/questions", json={"prompt": prompt})
    if isinstance(q_data, str):
        return q_data

    session_id = q_data.get("session_id")
    if not session_id:
        return "Failed to create recommendation session — no session_id returned."

    # Step 2: Generate recommendation with empty answers (skip Q&A for MCP simplicity)
    generate_body = {
        "session_id": session_id,
        "answers": [],
        "answer_texts": [],
        "mode": mode,
        "familiarity_pref": "any",
        "max_albums": 2500,
    }

    result_payload: dict = {}
    errors: list[str] = []

    try:
        async with _stream_client.stream(
            "POST",
            f"{ROONSAGE_URL}/api/recommend/generate",
            json=generate_body,
        ) as response:
            if response.status_code != 200:
                await response.aread()
                return f"RoonSage API error: {response.status_code} — {response.text}"

            async for event_type, payload in _parse_sse_events(response):
                if event_type == "result":
                    result_payload = payload
                elif event_type == "error":
                    errors.append(payload.get("message", "Unknown error"))

    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.ReadTimeout:
        return "Album recommendation timed out. The library may be large or the LLM is slow. Try again."
    except httpx.HTTPStatusError as exc:
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"

    if errors:
        return f"Album recommendation failed: {'; '.join(errors)}"

    if not result_payload:
        return "No recommendation was returned. Try a different prompt or check that the library is synced."

    # Extract the primary recommendation for a compact summary
    recommendations = result_payload.get("recommendations", [])
    primary = next((r for r in recommendations if r.get("rank") == "primary"), None)
    if not primary and recommendations:
        primary = recommendations[0]

    summary: dict = {
        "mode": mode,
        "token_count": result_payload.get("token_count", 0),
        "estimated_cost_usd": result_payload.get("estimated_cost", 0.0),
        "research_warning": result_payload.get("research_warning"),
        "primary_recommendation": None,
        "additional_picks": [],
    }

    if primary:
        pitch = primary.get("pitch") or {}
        summary["primary_recommendation"] = {
            "album": primary.get("album", ""),
            "artist": primary.get("artist", ""),
            "year": primary.get("year"),
            "genres": primary.get("genres", []),
            "rating_key": primary.get("rating_key", ""),
            "track_rating_keys": primary.get("track_rating_keys", []),
            "hook": pitch.get("hook", ""),
            "body": pitch.get("body", ""),
            "reason": primary.get("reason", ""),
            "playable": primary.get("playable", True),
            "source": primary.get("source", "library"),
        }

    secondaries = [r for r in recommendations if r.get("rank") == "secondary"]
    for sec in secondaries:
        summary["additional_picks"].append({
            "album": sec.get("album", ""),
            "artist": sec.get("artist", ""),
            "year": sec.get("year"),
            "rating_key": sec.get("rating_key", ""),
            "track_rating_keys": sec.get("track_rating_keys", []),
            "playable": sec.get("playable", True),
            "source": sec.get("source", "library"),
        })

    if result_payload.get("result_id"):
        summary["result_id"] = result_payload["result_id"]

    return json.dumps(summary, ensure_ascii=False, indent=2)


@mcp.tool()
async def get_library_status() -> str:
    """Check if the RoonSage library cache is up-to-date.

    Returns track_count, synced_at timestamp, whether a sync is currently
    running, and a `needs_resync` flag (True when cache is older than 24 hours).
    Call this proactively at the start of a conversation to decide whether to
    suggest a sync. If needs_resync is True, call sync_library.
    """
    logger.info("GET_LIBRARY_STATUS called")
    result = await _api_call("GET", "/api/library/status")
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def get_artist_albums(artist: str, max_albums: int = 50) -> str:
    """Return all albums in the Roon library by a given artist.

    Uses the local SQLite cache for instant results. Useful for deep-diving
    into an artist's catalogue, finding hidden gems, or recommending albums
    the user may have forgotten they own.

    Args:
        artist:     Artist name to search for (partial, case-insensitive).
        max_albums: Maximum number of albums to return (default 50).
    """
    logger.info("GET_ARTIST_ALBUMS: artist='%s' max=%d", artist, max_albums)
    result = await _api_call("GET", "/api/library/artist-albums", params={"artist": artist, "max_albums": max_albums})
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def seed_track_playlist(
    item_key: str,
    dimensions: list[str],
    track_count: int = 25,
    decades: Optional[list[str]] = None,
    exclude_live: bool = True,
    source_mode: str = "library",
    qobuz_percentage: int = 30,
) -> str:
    """Generate a "more like this" playlist seeded from a specific track.

    Use this tool when the user mentions a specific song/track as the starting point,
    e.g. "maak een playlist gebaseerd op Moondance van Van Morrison", "more like this",
    "a playlist in the style of [song]", or "iets als [artiest] - [nummer]".

    Workflow:
    1. Use search_library to find the seed track and get its item_key and year.
    2. Call this tool with the item_key. If the track has a year, suggest decades
       spanning ±15 years (e.g. year=1970 → suggest ["1960s", "1970s", "1980s"]).
    3. After generation, use play_tracks or queue_tracks with the returned item_keys.

    The output includes track title, artist, album, year, genre breakdown, and a note
    about live-track exclusion.

    Args:
        item_key:         The rating_key / item_key of the seed track (from search_library).
        dimensions:       Musical dimensions to match. Choose from:
                          "mood", "era", "genre", "production", "tempo", "energy".
                          Recommended: ["mood", "genre"] for most requests.
        track_count:      Exact number of tracks to generate (default 25). Any positive integer.
        decades:          Optional decade filters derived from the seed track's year,
                          e.g. ["1960s", "1970s", "1980s"]. Pass None to include all decades.
        exclude_live:     When True (default), live and concert recordings are excluded.
                          Pass False to include live versions.
        source_mode:      "library" (default) — only tracks from the Roon library.
                          "hybrid" — mix of library tracks + Qobuz discoveries.
                          "qobuz" — only new music from Qobuz streaming.
        qobuz_percentage: For hybrid mode, percentage of tracks sourced from Qobuz (default 30).
                          Ignored when source_mode is "library" or "qobuz".
    """
    logger.info("SEED_TRACK_PLAYLIST: key=%s dimensions=%s source=%s tracks=%d", item_key, dimensions, source_mode, track_count)
    body: dict = {
        "prompt": None,
        "seed_track": {
            "rating_key": item_key,
            "selected_dimensions": dimensions,
        },
        "genres": [],
        "decades": decades or [],
        "track_count": track_count,
        "exclude_live": exclude_live,
        "source_mode": source_mode,
        "qobuz_percentage": qobuz_percentage,
    }

    max_retries = 2
    all_tracks: list[dict] = []
    complete_data: dict = {}
    errors: list[str] = []

    for attempt in range(max_retries):
        try:
            async with _stream_client.stream(
                "POST",
                f"{ROONSAGE_URL}/api/generate/stream",
                json=body,
            ) as response:
                if response.status_code == 503 and attempt < max_retries - 1:
                    await response.aread()
                    await asyncio.sleep(3)
                    continue
                if response.status_code != 200:
                    await response.aread()
                    return f"RoonSage API error: {response.status_code} — {response.text}"

                all_tracks, complete_data, errors = [], {}, []
                async for event_type, payload in _parse_sse_events(response):
                    if event_type == "tracks":
                        batch = payload.get("batch", [])
                        if batch:
                            all_tracks.extend(batch)
                    elif event_type == "complete":
                        complete_data = payload
                    elif event_type == "error":
                        errors.append(payload.get("message", "Unknown error"))
            break  # Success, exit retry loop

        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.ReadTimeout:
            return "Seed playlist generation timed out. Try again."
        except httpx.HTTPStatusError as exc:
            return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"

    if errors:
        return f"Seed playlist generation failed: {'; '.join(errors)}"

    if not all_tracks and not complete_data:
        return "No results returned. Check that the library is synced and the item_key is valid."

    result = _build_playlist_result(all_tracks, complete_data, track_count, exclude_live)
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def analyze_prompt(prompt: str) -> str:
    """Show how RoonSage would translate a natural-language prompt into filters.

    Returns suggested genres, decades, mood tags, and tempo based on the prompt.
    Use this for transparency — show the user what filters the AI will apply
    before running a full generate_playlist call. Also useful for debugging
    unexpected playlist results.

    Args:
        prompt: Natural language description, e.g. "melancholic rainy Sunday jazz".
    """
    logger.info("ANALYZE_PROMPT: prompt='%s'", prompt[:80])
    result = await _api_call("POST", "/api/analyze/prompt", json={"prompt": prompt})
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def recommend_album_interactive(
    prompt: str,
    answers: Optional[list[str]] = None,
    mode: str = "library",
    familiarity_pref: str = "any",
) -> str:
    """Interactive album recommendation with clarifying questions.

    Two-step flow:
    - Step 1 (answers=None): Returns a session_id and clarifying questions.
      Present these questions to the user.
    - Step 2 (answers=[...]): Pass the session_id in the prompt field
      (format: "SESSION:<session_id>|<original prompt>") along with the user's
      answers to generate a precise recommendation.

    This produces much more personalized picks than recommend_album.

    Args:
        prompt:          Mood/occasion description. In step 2, prefix with
                         "SESSION:<session_id>|" to reuse the session.
        answers:         List of answer strings (one per clarifying question).
                         Pass None or omit for step 1.
        mode:            "library" (user's collection) or "discovery" (new albums).
        familiarity_pref: "comfort", "hidden_gem", "rediscovery", or "any".
    """
    logger.info("RECOMMEND_ALBUM_INTERACTIVE: mode=%s step=%s", mode, "2" if answers is not None else "1")
    # Step 2: answers provided — extract session_id from prompt prefix
    if answers is not None:
        session_id = None
        original_prompt = prompt
        if prompt.startswith("SESSION:"):
            parts = prompt[8:].split("|", 1)
            session_id = parts[0]
            original_prompt = parts[1] if len(parts) > 1 else prompt

        if not session_id:
            return "Error: session_id missing. Run step 1 first (call without answers)."

        generate_body = {
            "session_id": session_id,
            "answers": answers,
            "answer_texts": answers,
            "mode": mode,
            "familiarity_pref": familiarity_pref,
            "max_albums": 2500,
        }

        result_payload: dict = {}
        errors: list[str] = []

        try:
            async with _stream_client.stream(
                "POST",
                f"{ROONSAGE_URL}/api/recommend/generate",
                json=generate_body,
            ) as response:
                if response.status_code != 200:
                    await response.aread()
                    return f"RoonSage API error: {response.status_code} — {response.text}"
                async for event_type, payload in _parse_sse_events(response):
                    if event_type == "result":
                        result_payload = payload
                    elif event_type == "error":
                        errors.append(payload.get("message", "Unknown error"))
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.ReadTimeout:
            return "Album recommendation timed out. Try again."

        if errors:
            return f"Album recommendation failed: {'; '.join(errors)}"
        if not result_payload:
            return "No recommendation returned. Try a different prompt."

        recommendations = result_payload.get("recommendations", [])
        primary = next((r for r in recommendations if r.get("rank") == "primary"), None)
        if not primary and recommendations:
            primary = recommendations[0]

        summary: dict = {"mode": mode, "primary_recommendation": None, "additional_picks": []}
        if primary:
            pitch = primary.get("pitch") or {}
            summary["primary_recommendation"] = {
                "album": primary.get("album", ""),
                "artist": primary.get("artist", ""),
                "year": primary.get("year"),
                "genres": primary.get("genres", []),
                "rating_key": primary.get("rating_key", ""),
                "track_rating_keys": primary.get("track_rating_keys", []),
                "hook": pitch.get("hook", ""),
                "body": pitch.get("body", ""),
                "reason": primary.get("reason", ""),
                "playable": primary.get("playable", True),
                "source": primary.get("source", "library"),
            }
        secondaries = [r for r in recommendations if r.get("rank") == "secondary"]
        for sec in secondaries:
            summary["additional_picks"].append({
                "album": sec.get("album", ""),
                "artist": sec.get("artist", ""),
                "year": sec.get("year"),
                "rating_key": sec.get("rating_key", ""),
                "track_rating_keys": sec.get("track_rating_keys", []),
                "playable": sec.get("playable", True),
                "source": sec.get("source", "library"),
            })
        return json.dumps(summary, ensure_ascii=False, indent=2)

    # Step 1: get clarifying questions
    q_data = await _api_call("POST", "/api/recommend/questions", json={"prompt": prompt})
    if isinstance(q_data, str):
        return q_data

    session_id = q_data.get("session_id", "")
    questions = q_data.get("questions", [])

    result = {
        "step": 1,
        "instructions": (
            "Present these questions to the user. Then call recommend_album_interactive again "
            f"with prompt='SESSION:{session_id}|{prompt}' and answers=[...their answers...]."
        ),
        "session_id": session_id,
        "questions": questions,
    }
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def play_album(query: str, zone_id: str) -> str:
    """Search for an album by name and play it in full in a Roon zone.

    Combines search_library + play_tracks in one step. Use this when the user
    says "play [album name]" or "put on [album] by [artist]".

    Args:
        query:   Album or artist name to search for, e.g. "Kind of Blue" or
                 "Miles Davis Kind of Blue".
        zone_id: Roon zone ID to play in — obtain via list_zones.
    """
    logger.info("PLAY_ALBUM: query='%s' zone=%s", query, zone_id)
    # Search for the album tracks
    tracks = await _api_call("GET", "/api/library/search", params={"q": query})
    if isinstance(tracks, str):
        return tracks

    if not tracks:
        return json.dumps({
            "success": False,
            "error": f"No tracks found for '{query}'. Try a different search term.",
        })

    # Group tracks by album and pick the best-matching album
    albums: dict[str, list[dict]] = {}
    for t in tracks:
        album_key = f"{t.get('artist', '')} — {t.get('album', '')}"
        albums.setdefault(album_key, []).append(t)

    # Pick the album with the most matched tracks (most complete match)
    best_album_key = max(albums, key=lambda k: len(albums[k]))
    album_tracks = albums[best_album_key]
    item_keys = [t.get("rating_key", t.get("item_key", "")) for t in album_tracks if t.get("rating_key") or t.get("item_key")]

    # Play the tracks
    play_data = await _api_call("POST", "/api/queue", json={"item_keys": item_keys, "zone_id": zone_id})
    if isinstance(play_data, str):
        return play_data

    result = {
        "success": play_data.get("success", False),
        "album": album_tracks[0].get("album", ""),
        "artist": album_tracks[0].get("artist", ""),
        "tracks_queued": play_data.get("tracks_queued", len(item_keys)),
        "zone_name": play_data.get("zone_name", zone_id),
    }
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def transport_control(
    zone_id: str,
    action: str,
    value: Optional[str] = None,
    position_seconds: Optional[int] = None,
    seek_offset: Optional[int] = None,
) -> str:
    """Send a transport or playback-mode command to a Roon zone.

    Supported actions:
    - "play" / "pause" / "stop" / "next" / "previous" — standard transport.
    - "shuffle" — toggle or set shuffle. value="true"/"false"/"toggle" (default: toggle).
    - "repeat"  — set repeat mode. value="disabled"/"loop"/"loop_one"/"cycle"
                  (default: cycle through modes).
    - "seek"    — jump to a position. Use position_seconds for absolute seek (e.g. 90),
                  or seek_offset for relative seek (e.g. +30 or -15).

    No confirmation needed — execute immediately and confirm briefly.

    Args:
        zone_id:          Roon zone ID — obtain via list_zones.
        action:           One of the actions listed above.
        value:            For shuffle/repeat: control value (see above).
        position_seconds: For seek: absolute position in seconds.
        seek_offset:      For seek: relative offset in seconds (can be negative).
    """
    logger.info("TRANSPORT_CONTROL: zone=%s action=%s value=%s", zone_id, action, value)
    body: dict = {"zone_id": zone_id, "action": action}
    if value is not None:
        body["value"] = value
    if position_seconds is not None:
        body["position_seconds"] = position_seconds
    if seek_offset is not None:
        body["seek_offset"] = seek_offset

    result = await _api_call("POST", "/api/roon/transport", json=body)
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def get_result_history(
    type: Optional[str] = None,
    limit: int = 20,
) -> str:
    """Return previously generated playlists and album recommendations.

    Use this when the user asks to replay a past playlist, recall a previous
    recommendation, or review what was generated in earlier sessions.

    Args:
        type:  Filter by type. One of: "prompt_playlist", "seed_playlist",
               "album_recommendation". Pass None to return all types.
        limit: Maximum results to return (default 20, max 100).
    """
    logger.info("GET_RESULT_HISTORY: type=%s limit=%d", type, limit)
    params: dict = {"limit": limit}
    if type:
        params["type"] = type

    result = await _api_call("GET", "/api/results", params=params)
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def volume_control(
    zone_name: str,
    action: str,
    value: Optional[int] = None,
) -> str:
    """Control volume for a Roon zone by display name.

    Use this when the user says "zet het volume op ...", "volume omhoog", "dempen", etc.
    Resolves zone name to the correct output internally. For grouped zones,
    all outputs in the group are adjusted.

    Actions:
    - "set"         — Set volume to an absolute percentage (0–100). Requires value.
    - "adjust"      — Change volume relatively (+N or -N). Requires value (e.g. 10 for +10, -5 for -5).
    - "get"         — Return current volume and mute state (no change made).
    - "mute"        — Mute the zone.
    - "unmute"      — Unmute the zone.
    - "toggle_mute" — Toggle mute/unmute.

    Args:
        zone_name: Zone display name (e.g. "Woonkamer"). Use list_zones to see available names.
        action:    One of: set, adjust, get, mute, unmute, toggle_mute.
        value:     Integer value for "set" (0–100) or "adjust" (relative, can be negative).
    """
    logger.info("VOLUME_CONTROL: zone='%s' action=%s value=%s", zone_name, action, value)
    body: dict = {"zone_name": zone_name, "action": action}
    if value is not None:
        body["value"] = value

    result = await _api_call("POST", "/api/roon/volume", json=body)
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def transfer_zone(from_zone: str, to_zone: str) -> str:
    """Transfer the current playback queue from one Roon zone to another.

    Use this when the user moves from one room to another and wants music to
    follow them. The playback continues uninterrupted on the new zone.

    Args:
        from_zone: Source zone display name (e.g. "Woonkamer").
        to_zone:   Target zone display name (e.g. "Slaapkamer").
    """
    logger.info("TRANSFER_ZONE: from='%s' to='%s'", from_zone, to_zone)
    result = await _api_call("POST", "/api/roon/transfer", json={"from_zone": from_zone, "to_zone": to_zone})
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def zone_grouping(
    action: str,
    zones: Optional[list[str]] = None,
) -> str:
    """Group, ungroup, or list Roon zone groups.

    Use this to combine multiple rooms/speakers into one synchronized playback group,
    or to split them apart again.

    Actions:
    - "group"        — Group two or more zones together. Requires zones list (≥2 names).
                       Compatibility is checked first; an error is returned if zones
                       cannot be grouped.
    - "ungroup"      — Separate grouped zones. Requires zones list.
    - "list_groups"  — Show all current grouped zones. No zones argument needed.

    Args:
        action: One of: group, ungroup, list_groups.
        zones:  List of zone display names for group/ungroup (e.g. ["Woonkamer", "Keuken"]).
    """
    logger.info("ZONE_GROUPING: action=%s zones=%s", action, zones)
    result = await _api_call("POST", "/api/roon/group", json={"action": action, "zones": zones or []})
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def play_radio(station: str, zone_id: str) -> str:
    """Play an internet radio station in a Roon zone.

    Browses the "My Live Radio" list in Roon and starts the best-matching station.
    Uses fuzzy matching so partial names work (e.g. "BBC 4" matches "BBC Radio 4").

    Requirements: The zone must be configured in Roon and the station must appear
    in your "My Live Radio" list in the Roon app.

    Args:
        station: Station name to search for, e.g. "BBC Radio 4", "KQED", "NPO Radio 1".
        zone_id: Roon zone ID to play in — obtain via list_zones.
    """
    logger.info("PLAY_RADIO: station='%s' zone=%s", station, zone_id)
    result = await _api_call("POST", "/api/roon/radio", json={"station": station, "zone_id": zone_id})
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def browse_playlists(
    action: str,
    playlist_name: Optional[str] = None,
    zone_id: Optional[str] = None,
) -> str:
    """Browse or play Roon playlists (all playlists, not only RoonSage-generated ones).

    This differs from get_result_history which only shows RoonSage-generated results.
    This tool accesses ALL playlists in Roon: imported playlists, TIDAL/Qobuz playlists,
    and any playlists you've saved in Roon.

    Actions:
    - "list" — Show all available Roon playlists (no zone needed).
    - "play" — Play a playlist in a zone. Requires playlist_name and zone_id.
               Uses fuzzy matching so partial names work.

    Args:
        action:        One of: list, play.
        playlist_name: Playlist name to play (for "play" action). Partial name is fine.
        zone_id:       Roon zone ID to play in (for "play" action) — obtain via list_zones.
    """
    logger.info("BROWSE_PLAYLISTS: action=%s playlist='%s' zone=%s", action, playlist_name, zone_id)
    body: dict = {
        "action": action,
        "playlist_name": playlist_name or "",
        "zone_id": zone_id or "",
    }

    result = await _api_call("POST", "/api/roon/playlists", json=body)
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def search_qobuz(query: str, limit: int = 10) -> str:
    """Search for tracks on Qobuz via Roon's streaming integration.

    Requires Qobuz to be configured in Roon. Returns tracks with item_keys
    that can be used directly with play_tracks / queue_tracks.

    Use this when the user wants to discover new music, play something they
    don't own, or when a library search returns no results and you want to
    check if it's available on Qobuz.

    Args:
        query: Search string, e.g. "Miles Davis So What" or "Radiohead"
        limit: Max results (default 10)
    """
    logger.info("SEARCH_QOBUZ: query='%s' limit=%d", query, limit)
    result = await _api_call("POST", "/api/roon/qobuz-search", json={"query": query, "limit": limit})
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def save_to_qobuz(
    playlist_name: str,
    tracks: list[dict],
    description: str = "",
) -> str:
    """Save a curated playlist to the user's Qobuz account.

    After curating a playlist (from library, hybrid, or Qobuz sources),
    call this tool to save it as a Qobuz playlist. Each track is resolved
    by searching the Qobuz catalog for artist + title.

    The tool creates a new Qobuz playlist and adds all matched tracks.
    Tracks not found on Qobuz are reported in the response.

    Requires QOBUZ_APP_ID, QOBUZ_EMAIL, and QOBUZ_PASSWORD to be
    configured in RoonSage.

    Args:
        playlist_name: Name for the new Qobuz playlist.
        tracks:        List of track dicts, each with "artist" and "title"
                       keys. E.g. [{"artist": "Radiohead", "title": "Karma Police"}, ...]
        description:   Optional playlist description text.
    """
    logger.info("SAVE_TO_QOBUZ: name='%s' tracks=%d", playlist_name, len(tracks))
    result = await _api_call(
        "POST",
        "/api/qobuz/playlist/save",
        json={
            "name": playlist_name,
            "tracks": tracks,
            "description": description,
        },
    )
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run(transport="stdio")
