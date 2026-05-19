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

import atexit
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

# Retry configuration for transient HTTP errors
RETRYABLE_STATUS = {502, 503, 504}
MAX_RETRIES = 2
RETRY_BACKOFF = [1.0, 3.0]  # seconds to wait before attempt 2 and 3

mcp = FastMCP("roonsage")

# ---------------------------------------------------------------------------
# HTTP clients — lazily created on first use, closed via atexit
# ---------------------------------------------------------------------------

_client: httpx.AsyncClient | None = None
_stream_client: httpx.AsyncClient | None = None
_playback_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=TIMEOUT)
    return _client


def _get_stream_client() -> httpx.AsyncClient:
    global _stream_client
    if _stream_client is None:
        _stream_client = httpx.AsyncClient(timeout=STREAM_TIMEOUT)
    return _stream_client


def _get_playback_client() -> httpx.AsyncClient:
    global _playback_client
    if _playback_client is None:
        _playback_client = httpx.AsyncClient(timeout=PLAYBACK_TIMEOUT)
    return _playback_client


async def _cleanup() -> None:
    """Close all open HTTP clients gracefully."""
    for client in [_client, _stream_client, _playback_client]:
        if client is not None:
            try:
                await client.aclose()
            except Exception:
                pass


def _sync_cleanup() -> None:
    """atexit handler: close clients synchronously."""
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            loop.create_task(_cleanup())
        else:
            loop.run_until_complete(_cleanup())
    except RuntimeError:
        pass


atexit.register(_sync_cleanup)


async def _startup_health_check() -> None:
    """Ping RoonSage at startup and log a warning if it is unreachable."""
    try:
        resp = await _get_client().get(f"{ROONSAGE_URL}/api/library/status", timeout=5.0)
        resp.raise_for_status()
        logger.info("RoonSage reachable at %s (startup check OK)", ROONSAGE_URL)
    except httpx.ConnectError:
        logger.warning(
            "RoonSage is NOT reachable at %s — make sure the app is running "
            "(uvicorn backend.main:app --port 5765). Tools will fail until it is.",
            ROONSAGE_URL,
        )
    except Exception as exc:
        logger.warning("RoonSage startup check returned an unexpected error: %s", exc)


def _unavailable_msg() -> str:
    return (
        f"RoonSage is not reachable at {ROONSAGE_URL}. "
        "Make sure the application is running (uvicorn backend.main:app --port 5765)."
    )


async def _api_call(method: str, path: str, *, retryable: bool = True, **kwargs) -> dict | list | str:
    """Make an API call to RoonSage, handling errors uniformly.

    Args:
        method:    HTTP method (GET, POST, …).
        path:      Path relative to ROONSAGE_URL (e.g. "/api/library/stats/cached").
        retryable: When True (default), ConnectErrors and 502/503/504 responses are
                   retried up to MAX_RETRIES times with exponential backoff.
                   Pass False for mutating operations (playback, transport, volume)
                   where a duplicate request would have unintended side-effects.
        **kwargs:  Passed directly to httpx AsyncClient.request().
    """
    attempts = MAX_RETRIES + 1 if retryable else 1
    last_error: str | None = None

    for attempt in range(attempts):
        if attempt > 0:
            wait = RETRY_BACKOFF[attempt - 1]
            logger.warning("API %s %s -> retrying in %.1fs (attempt %d/%d)", method, path, wait, attempt + 1, attempts)
            await asyncio.sleep(wait)

        try:
            logger.info("API %s %s", method, path)
            response = await _get_client().request(method, f"{ROONSAGE_URL}{path}", **kwargs)
            response.raise_for_status()
            data = response.json()
            if isinstance(data, list):
                logger.info("API %s %s -> %d items", method, path, len(data))
            elif isinstance(data, dict):
                logger.info("API %s %s -> keys: %s", method, path, list(data.keys()))
            return data
        except httpx.ConnectError:
            logger.error("API %s %s -> CONNECT ERROR (attempt %d)", method, path, attempt + 1)
            last_error = _unavailable_msg()
            if not retryable:
                break
        except httpx.HTTPStatusError as exc:
            logger.error("API %s %s -> HTTP %d: %s", method, path, exc.response.status_code, exc.response.text[:200])
            if retryable and exc.response.status_code in RETRYABLE_STATUS:
                last_error = f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"
            else:
                return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"

    return last_error or _unavailable_msg()


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


# ---------------------------------------------------------------------------
# filter_tracks helpers
# ---------------------------------------------------------------------------

def _build_key_map(tracks: list[dict]) -> dict[str, str]:
    """Build a 1-based track-number → item_key mapping from a track list."""
    return {str(i): track.get("item_key", "") for i, track in enumerate(tracks, start=1)}


async def _store_session(key_map: dict[str, str], total: int, returned: int) -> str:
    """Store key_map server-side and return a session_id, or '' on failure."""
    try:
        store_resp = await _get_client().post(
            f"{ROONSAGE_URL}/api/library/filter/session",
            json={"key_map": key_map, "total_matching": total, "returned": returned},
        )
        store_resp.raise_for_status()
        return store_resp.json().get("session_id", "")
    except Exception as exc:
        logger.warning("Session storage failed — key_map will be sent as fallback: %s", exc)
        return ""


def _format_compact_line(i: int, track: dict) -> str:
    """Format a track as 'nr. Artist — Title [Album] (Year) | Genres'."""
    genres_str = ", ".join(track.get("genres") or [])
    year = track.get("year") or ""
    return (
        f"{i}. {track.get('artist', '?')} — {track.get('title', '?')} "
        f"[{track.get('album', '?')}] ({year}) | {genres_str}"
    )


def _format_ultra_line(i: int, track: dict) -> str:
    """Format a track as 'nr. Artist — Title'."""
    return f"{i}. {track.get('artist', '?')} — {track.get('title', '?')}"


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
        response = await _get_client().post(f"{ROONSAGE_URL}/api/library/filter", json=body)
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
        key_map = _build_key_map(tracks)
        lines = [_format_ultra_line(i, t) for i, t in enumerate(tracks, start=1)]
        session_id = await _store_session(key_map, total, returned)

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
        key_map = _build_key_map(tracks)
        lines = [_format_compact_line(i, t) for i, t in enumerate(tracks, start=1)]
        # Store key_map server-side — get a session_id back so it doesn't
        # need to travel through Claude's context window (~10-20k tokens saved).
        session_id = await _store_session(key_map, total, returned)

        result: dict = {
            "total_matching": total,
            "returned": returned,
            "tracks": "\n".join(lines),
            "session_id": session_id,
        }
        if session_id:
            result["note"] = (
                "Selecteer tracks op nummer. Gebruik session_id met curate_and_play "
                "om de selectie af te spelen. De key_map is server-side opgeslagen."
            )
        else:
            # Fallback: if server-side storage fails, include key_map directly
            # so curate_and_play can still work (it handles both paths).
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
    _KEEP = {"item_key", "title", "artist", "album", "genres"}
    data["tracks"] = [
        {k: v for k, v in track.items() if k in _KEEP}
        for track in tracks
    ]

    # Add a note when results are capped so Claude knows the real pool size
    if total > returned:
        data["note"] = (
            f"Library contains {total} matching tracks; {returned} returned "
            "(random sample). Use the item_key of each track for playback."
        )
    else:
        data["note"] = "Use the item_key of each track as item_key for play_tracks / queue_tracks."

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
        response = await _get_playback_client().post(
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
        response = await _get_playback_client().post(
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
        response = await _get_playback_client().post(
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
                "item_key": t.get("item_key", ""),
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
        extra_keys = [t.get("item_key", "") for t in extra_tracks if t.get("item_key")]
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

    async with _get_stream_client().stream(
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
        async with _get_stream_client().stream(
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
            "item_key": primary.get("item_key", ""),
            "track_item_keys": primary.get("track_item_keys", []),
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
            "item_key": sec.get("item_key", ""),
            "track_item_keys": sec.get("track_item_keys", []),
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
        item_key:         The item_key of the seed track (from search_library).
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
            "item_key": item_key,
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
            async with _get_stream_client().stream(
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
    session_id: Optional[str] = None,
    mode: str = "library",
    familiarity_pref: str = "any",
) -> str:
    """Interactive album recommendation with clarifying questions.

    Two-step flow:
    - Step 1 (answers=None, session_id=None): Returns a session_id and
      clarifying questions. Present these questions to the user.
    - Step 2 (answers=[...], session_id="<from step 1>"): Pass the session_id
      returned from step 1 as the session_id parameter, keep the original
      prompt unchanged, and include the user's answers to generate a precise
      recommendation.

    This produces much more personalized picks than recommend_album.

    Args:
        prompt:          Mood/occasion description. Pass the same value in
                         both step 1 and step 2.
        answers:         List of answer strings (one per clarifying question).
                         Pass None or omit for step 1.
        session_id:      Session ID returned by step 1. Required in step 2;
                         omit (or pass None) for step 1.
        mode:            "library" (user's collection) or "discovery" (new albums).
        familiarity_pref: "comfort", "hidden_gem", "rediscovery", or "any".
    """
    logger.info("RECOMMEND_ALBUM_INTERACTIVE: mode=%s step=%s", mode, "2" if answers is not None else "1")
    # Step 2: answers provided — use session_id directly
    if answers is not None:
        if not session_id:
            return "Error: session_id missing. Call this tool first without answers to get a session_id."

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
            async with _get_stream_client().stream(
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
                "item_key": primary.get("item_key", ""),
                "track_item_keys": primary.get("track_item_keys", []),
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
                "item_key": sec.get("item_key", ""),
                "track_item_keys": sec.get("track_item_keys", []),
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
            f"with session_id='{session_id}', prompt='{prompt}', and answers=[...their answers...]."
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
    item_keys = [t.get("item_key", "") for t in album_tracks if t.get("item_key")]

    # Play the tracks
    play_data = await _api_call("POST", "/api/queue", retryable=False, json={"item_keys": item_keys, "zone_id": zone_id})
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

    result = await _api_call("POST", "/api/roon/transport", retryable=False, json=body)
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

    result = await _api_call("POST", "/api/roon/volume", retryable=False, json=body)
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

    Requires QOBUZ_EMAIL and QOBUZ_PASSWORD to be configured in RoonSage.

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


@mcp.tool()
async def add_to_qobuz_favorites(
    item_type: str,
    names: list[str],
) -> str:
    """Add albums, tracks, or artists to Qobuz favorites.

    Items added to Qobuz favorites automatically appear in Roon Arc.
    For albums and tracks, each name is searched on Qobuz and resolved
    to a Qobuz ID before being favorited.
    For artists, the artist is searched by name and favorited directly.

    Use this when recommending a new album to the user so they can also
    hear it on the go via Roon Arc.

    Args:
        item_type: "album", "track", or "artist"
        names:     List of search queries, e.g. ["Radiohead - OK Computer",
                   "Portishead - Dummy"] for albums, or ["Miles Davis"] for artists.
    """
    logger.info("ADD_TO_QOBUZ_FAVORITES: type=%s names=%s", item_type, names)

    if item_type not in ("album", "track", "artist"):
        return "Error: item_type must be 'album', 'track', or 'artist'."
    if not names:
        return "Error: names list is empty."

    # Resolve names to Qobuz IDs via search
    resolved_ids: list[str] = []
    not_found: list[str] = []

    for name in names:
        if item_type == "artist":
            # Search for artist
            result = await _api_call("GET", "/api/library/search", params={"q": name})
            if isinstance(result, list) and result:
                # Try to find the artist on Qobuz via Qobuz search
                qobuz_result = await _api_call("POST", "/api/roon/qobuz-search", json={"query": name, "limit": 5})
                if isinstance(qobuz_result, dict) and qobuz_result.get("tracks"):
                    # Get artist from first result — we'd need Qobuz direct API for artist ID
                    # Fall through to direct Qobuz API call for artist search
                    pass
            # For artists, we use the direct Qobuz API endpoint
            await _api_call("POST", "/api/qobuz/favorite/add", json={"type": "artist", "ids": []})
            # Artists require a direct Qobuz artist search — delegate to the backend
            not_found.append(f"{name} (artist search requires direct Qobuz lookup)")
        else:
            # For tracks and albums, search via Qobuz
            qobuz_result = await _api_call("POST", "/api/roon/qobuz-search", json={"query": name, "limit": 3})
            if isinstance(qobuz_result, dict) and qobuz_result.get("tracks"):
                tracks = qobuz_result["tracks"]
                if tracks:
                    first = tracks[0]
                    if item_type == "track":
                        # item_key contains Qobuz track ID for Qobuz tracks
                        item_key = first.get("item_key", "")
                        # item_keys from qobuz search are Roon item_keys, not Qobuz IDs
                        # We add via the backend favorite endpoint using the search result
                        resolved_ids.append(item_key)
                    elif item_type == "album":
                        resolved_ids.append(first.get("item_key", ""))
            else:
                not_found.append(name)

    # Call the backend favorites endpoint
    # Note: for Qobuz-via-Roon item_keys, we use the track item_keys directly
    # The backend will handle ID resolution
    if resolved_ids:
        add_result = await _api_call("POST", "/api/qobuz/favorite/add", json={
            "type": item_type,
            "ids": resolved_ids,
        })
    else:
        add_result = {"success": False, "error": "No items resolved"}

    summary = {
        "favorited": len(resolved_ids),
        "not_found": not_found,
        "result": add_result if isinstance(add_result, dict) else str(add_result),
    }
    return json.dumps(summary, ensure_ascii=False, indent=2)


@mcp.tool()
async def list_qobuz_playlists() -> str:
    """List all Qobuz playlists in the user's account.

    Shows name, track count, and creation date for each playlist.
    Use this when the user asks about their saved playlists, wants to
    play a specific Qobuz playlist, or wants to clean up old ones.

    Requires QOBUZ_EMAIL and QOBUZ_PASSWORD to be configured in RoonSage.
    """
    logger.info("LIST_QOBUZ_PLAYLISTS called")
    result = await _api_call("GET", "/api/qobuz/playlists")
    if isinstance(result, str):
        return result

    playlists = result.get("playlists", [])
    if not playlists:
        return "No Qobuz playlists found. Create one with save_to_qobuz or prepare_for_arc."

    lines = [f"Found {len(playlists)} Qobuz playlist(s):\n"]
    for p in playlists:
        created = p.get("created_at", "")[:10] if p.get("created_at") else "unknown"
        lines.append(
            f"- [{p['id']}] {p['name']}  "
            f"({p.get('tracks_count', 0)} tracks, created {created})"
        )
    return "\n".join(lines)


@mcp.tool()
async def update_qobuz_playlist(
    playlist_id: str,
    add_tracks: Optional[list[str]] = None,
    remove_indices: Optional[list[int]] = None,
    new_name: Optional[str] = None,
    new_description: Optional[str] = None,
) -> str:
    """Update an existing Qobuz playlist — rename, add or remove tracks.

    Use this to refine a saved playlist: add new discoveries, clean out
    tracks that no longer fit, or rename it.

    Args:
        playlist_id:     Qobuz playlist ID (from list_qobuz_playlists).
        add_tracks:      Qobuz track IDs to add (as strings), e.g. ["123456", "789012"].
                         Use search_qobuz to find track IDs.
        remove_indices:  Playlist-internal track position IDs to remove.
                         Get these from get_playlist details (playlist_track_id field).
        new_name:        New playlist name (optional).
        new_description: New playlist description (optional).
    """
    logger.info(
        "UPDATE_QOBUZ_PLAYLIST: id=%s name=%s add=%s remove=%s",
        playlist_id, new_name, add_tracks, remove_indices,
    )
    body: dict = {"playlist_id": playlist_id}
    if new_name is not None:
        body["name"] = new_name
    if new_description is not None:
        body["description"] = new_description
    if add_tracks:
        body["add_track_ids"] = add_tracks
    if remove_indices:
        body["remove_playlist_track_ids"] = [str(i) for i in remove_indices]

    result = await _api_call("PUT", f"/api/qobuz/playlist/{playlist_id}", json=body)
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def delete_qobuz_playlist(playlist_id: str) -> str:
    """Delete a Qobuz playlist permanently.

    Use with caution — deletion is irreversible. Use list_qobuz_playlists
    to confirm the playlist ID before deleting.

    Args:
        playlist_id: The Qobuz playlist ID (from list_qobuz_playlists).
    """
    logger.info("DELETE_QOBUZ_PLAYLIST: id=%s", playlist_id)
    result = await _api_call("DELETE", f"/api/qobuz/playlist/{playlist_id}", retryable=False)
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, (dict, list)) else result


@mcp.tool()
async def browse_qobuz_new_releases(
    genre: Optional[str] = None,
    limit: int = 20,
) -> str:
    """Browse new album releases on Qobuz, optionally filtered by genre.

    Great for music discovery — shows what's freshly released this week.
    Returns album titles, artists, release dates, and genres.

    Common Qobuz genre IDs:
    - Jazz: 6, Electronic: 64, Classical: 113, Pop/Rock: 76, Hip-Hop: 34,
      Soul/R&B: 56, Folk: 68, Blues: 178, World: 98

    After browsing, use search_qobuz to get playable item_keys for an album,
    then play_tracks to start listening.

    Args:
        genre: Optional genre name as hint (e.g. "jazz", "electronic").
               If provided, the backend tries to match to a Qobuz genre ID.
               Leave None for all genres.
        limit: Number of releases to show (default 20, max 50).
    """
    logger.info("BROWSE_QOBUZ_NEW_RELEASES: genre=%s limit=%d", genre, limit)

    # Map common genre names to Qobuz genre IDs
    GENRE_ID_MAP = {
        "jazz": "6",
        "electronic": "64",
        "electronica": "64",
        "classical": "113",
        "pop": "76",
        "rock": "76",
        "pop/rock": "76",
        "hip-hop": "34",
        "hiphop": "34",
        "hip hop": "34",
        "rap": "34",
        "soul": "56",
        "r&b": "56",
        "rnb": "56",
        "folk": "68",
        "blues": "178",
        "world": "98",
        "world music": "98",
        "latin": "148",
        "metal": "174",
        "country": "133",
    }

    params: dict = {"limit": min(limit, 50)}
    if genre:
        genre_id = GENRE_ID_MAP.get(genre.lower().strip())
        if genre_id:
            params["genre_id"] = genre_id
        else:
            logger.info("Unknown genre '%s' — fetching all genres", genre)

    result = await _api_call("GET", "/api/qobuz/new-releases", params=params)
    if isinstance(result, str):
        return result

    albums = result.get("albums", [])
    if not albums:
        return f"No new releases found{f' for genre {genre}' if genre else ''}."

    lines = [f"🆕 {len(albums)} new releases on Qobuz{f' — {genre}' if genre else ''}:\n"]
    for a in albums:
        released = a.get("release_date", "")[:10] if a.get("release_date") else ""
        genre_str = f" [{a['genre']}]" if a.get("genre") else ""
        lines.append(
            f"• {a['artist']} — {a['title']}"
            + (f" ({released})" if released else "")
            + genre_str
            + f"  [{a.get('tracks_count', '?')} tracks, id={a['id']}]"
        )
    lines.append(
        "\nUse search_qobuz(\"Artist Album\") to get playable item_keys, "
        "then play_tracks to listen."
    )
    return "\n".join(lines)


@mcp.tool()
async def prepare_for_arc(
    playlist_name: str,
    session_id: Optional[str] = None,
    track_numbers: Optional[list[int]] = None,
    item_keys: Optional[list[str]] = None,
    add_albums_to_favorites: bool = True,
) -> str:
    """Save a curated playlist to Qobuz for listening in Roon Arc on the go.

    This is the bridge between home curation and mobile listening:
    1. Resolves all tracks to Qobuz equivalents by title + artist search.
    2. Creates a Qobuz playlist named "RoonSage · {name} · {date}".
    3. Optionally adds the discovered albums to Qobuz favorites.

    Everything added to Qobuz (playlists + favorites) automatically
    appears in Roon Arc — no extra setup needed.

    Use EITHER session_id + track_numbers (from a filter_tracks session)
    OR item_keys (from play_tracks / search results). Not both.

    Args:
        playlist_name:         Descriptive name, e.g. "Late Night Jazz".
        session_id:            Session ID from a filter_tracks call.
        track_numbers:         Track numbers from that session.
        item_keys:             Direct Roon item_keys (alternative to session_id).
        add_albums_to_favorites: Add unique albums to Qobuz favorites (default True).
    """
    logger.info(
        "PREPARE_FOR_ARC: name='%s' session=%s tracks=%s keys=%s fav=%s",
        playlist_name, session_id, track_numbers, item_keys, add_albums_to_favorites,
    )

    # Resolve track metadata so we have artist + title for Qobuz search
    track_items: list[dict] = []

    if session_id and track_numbers:
        # Fetch the resolved tracks from the session via curate_and_play dry-run
        # We call the curate endpoint in dry-run / lookup mode to get track metadata
        curate_resp = await _api_call(
            "POST",
            "/api/library/filter/curate",
            retryable=False,
            json={
                "session_id": session_id,
                "track_numbers": track_numbers,
                "zone_id": "__dry_run__",  # Signal backend to skip playback
                "dry_run": True,
            },
        )
        if isinstance(curate_resp, dict):
            resolved = curate_resp.get("resolved_tracks", [])
            track_items = [{"title": t.get("title", ""), "artist": t.get("artist", "")} for t in resolved]
        if not track_items:
            return (
                "Could not resolve track metadata from session. "
                "Try using item_keys instead, or provide tracks directly via save_to_qobuz."
            )
    elif item_keys:
        # Search for each item_key to get metadata
        for key in item_keys[:100]:  # Cap at 100 to avoid rate limiting
            search_result = await _api_call("GET", "/api/library/search", params={"q": key})
            if isinstance(search_result, list) and search_result:
                t = search_result[0]
                track_items.append({"title": t.get("title", ""), "artist": t.get("artist", "")})
    else:
        return "Error: provide either (session_id + track_numbers) or item_keys."

    if not track_items:
        return "No track metadata could be resolved. Check that the session_id or item_keys are valid."

    # Call the prepare-for-arc backend endpoint
    body = {
        "playlist_name": playlist_name,
        "track_items": track_items,
        "add_to_favorites": add_albums_to_favorites,
    }
    result = await _api_call("POST", "/api/qobuz/prepare-for-arc", retryable=False, json=body)
    if isinstance(result, str):
        return result

    if not result.get("success"):
        return f"Prepare for Arc failed: {result.get('error', 'Unknown error')}"

    lines = [
        "✅ Playlist saved to Qobuz for Roon Arc!",
        "",
        f"📋 **{result.get('playlist_name')}**",
        f"🔗 {result.get('playlist_url', '')}",
        "",
        f"✓ {result.get('tracks_resolved', 0)} tracks saved to Qobuz playlist",
    ]
    if result.get("tracks_skipped", 0):
        lines.append(f"✗ {result['tracks_skipped']} tracks not found on Qobuz")
    if result.get("albums_favorited", 0):
        lines.append(f"❤️  {result['albums_favorited']} albums added to Qobuz favorites")
    lines.append("")
    lines.append("The playlist will appear in Roon Arc within a few minutes.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Intelligence layer tools (MCP v5.0)
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_taste_profile() -> str:
    """Get the user's musical taste profile built from listening history and feedback.

    Call this at the START of every session to understand the user's preferences.
    The profile contains genre preferences, favorite artists, preferred decades,
    mood patterns, and explicit dislikes. Use this to inform all curation decisions:
    - Boost genres/artists with high scores in filter_tracks calls
    - Avoid anything in the dislikes list
    - Take notes into account when selecting tracks

    No parameters required.
    """
    logger.info("GET_TASTE_PROFILE called")
    result = await _api_call("GET", "/api/intelligence/taste-profile/detailed")
    if isinstance(result, str):
        return result
    # Compact the profile for token efficiency
    compact: dict = {}
    for key in ("genres", "decades", "artists", "moods", "dislikes", "notes", "stats"):
        val = result.get(key)
        if val:
            if isinstance(val, dict):
                compact[key] = dict(sorted(val.items(), key=lambda x: -x[1])[:20]) if val else {}
            else:
                compact[key] = val
    # Include LB summary
    lb_keys = [k for k in result if k.startswith("lb_") and result[k]]
    if lb_keys:
        compact["listenbrainz_available"] = lb_keys
        if result.get("lb_last_synced"):
            compact["lb_last_synced"] = result["lb_last_synced"]
        if result.get("lb_loved_recordings"):
            compact["lb_loved"] = [
                f"{r.get('track_metadata', {}).get('artist_name', '?')} — "
                f"{r.get('track_metadata', {}).get('track_name', '?')}"
                for r in result["lb_loved_recordings"][:10]
            ]
    return json.dumps(compact, ensure_ascii=False, indent=2)


@mcp.tool()
async def update_taste_profile(
    genre_preferences: Optional[dict] = None,
    artist_preferences: Optional[dict] = None,
    decade_preferences: Optional[dict] = None,
    mood_preferences: Optional[dict] = None,
    dislikes: Optional[list[str]] = None,
    notes: Optional[list[str]] = None,
) -> str:
    """Update the user's taste profile based on this session's interactions.

    Call this AFTER a successful playlist that the user enjoyed, or when the user
    gives explicit feedback about their preferences. Scores are 0.0-1.0 where
    1.0 = strong preference. Only include items clearly indicated by this session.

    Examples:
    - User loved a jazz session -> genre_preferences={"Jazz": 0.85}
    - User said "more Radiohead" -> artist_preferences={"Radiohead": 0.9}
    - User said "never Christmas music" -> dislikes=["christmas"]

    Args:
        genre_preferences:  e.g. {"Jazz": 0.8, "Electronic": 0.6}
        artist_preferences: e.g. {"Radiohead": 0.9, "Miles Davis": 0.85}
        decade_preferences: e.g. {"1990s": 0.7, "1980s": 0.6}
        mood_preferences:   e.g. {"melancholic": 0.7, "energetic": 0.4}
        dislikes:           Explicit dislikes, e.g. ["christmas music", "karaoke"]
        notes:              Behavioral notes, e.g. ["prefers vinyl-era production"]
    """
    logger.info("UPDATE_TASTE_PROFILE called")
    updates: dict = {}
    if genre_preferences:
        updates["genres"] = genre_preferences
    if artist_preferences:
        updates["artists"] = artist_preferences
    if decade_preferences:
        updates["decades"] = decade_preferences
    if mood_preferences:
        updates["moods"] = mood_preferences
    if dislikes:
        updates["dislikes"] = dislikes
    if notes:
        updates["notes"] = notes

    if not updates:
        return "No updates provided — nothing changed."

    result = await _api_call("POST", "/api/taste/profile", json={"updates": updates}, retryable=False)
    if isinstance(result, str):
        return result

    genres = result.get("genres", {})
    top_genres = sorted(genres.items(), key=lambda x: -x[1])[:5]
    return (
        "Taste profile updated.\n"
        "Top genres now: " + ", ".join(f"{g} ({s:.2f})" for g, s in top_genres) + "\n"
        "Dislikes: " + str(result.get("dislikes", [])) + "\n"
        "Notes: " + str(result.get("notes", []))
    )


@mcp.tool()
async def rate_playlist(
    playlist_name: str,
    rating: int,
    feedback: Optional[str] = None,
) -> str:
    """Rate a recently generated playlist and provide optional feedback.

    This logs the rating as a taste event so future recommendations improve.
    After rating, consider also calling update_taste_profile with session insights.

    Args:
        playlist_name: Name or description of the playlist being rated.
        rating:        1-5 score (1=poor, 3=okay, 5=excellent).
        feedback:      Optional text, e.g. "too much jazz, needed more variety".
    """
    logger.info("RATE_PLAYLIST: '%s' rating=%d", playlist_name, rating)
    if not 1 <= rating <= 5:
        return "Rating must be between 1 and 5."

    event_data: dict = {"playlist_name": playlist_name, "rating": rating}
    if feedback:
        event_data["feedback"] = feedback

    result = await _api_call(
        "POST", "/api/taste/event",
        json={"event_type": "playlist_rated", "data": event_data},
        retryable=False,
    )
    if isinstance(result, str):
        return result

    msg = f"Rating {rating}/5 logged for '{playlist_name}'."
    if feedback:
        msg += f" Feedback: \"{feedback}\""
    if rating >= 4:
        msg += "\n✓ Good rating! Consider calling update_taste_profile with the genres/artists from this session."
    elif rating <= 2:
        msg += "\n✗ Low rating noted. Consider calling update_taste_profile with notes about what didn't work."
    return msg


@mcp.tool()
async def get_listening_history(days: int = 7, limit: int = 30) -> str:
    """Get recent listening history recorded passively from Roon zones.

    Shows what the user has actually been playing, including skip patterns.
    Use this at session start to understand the current mood and avoid
    suggesting tracks that were recently skipped.

    Args:
        days:  How many days back to look (default 7, max 90).
        limit: Maximum entries to return (default 30).
    """
    logger.info("GET_LISTENING_HISTORY: days=%d limit=%d", days, limit)
    result = await _api_call("GET", "/api/listening/history", params={"days": days, "limit": limit})
    if isinstance(result, str):
        return result
    if not result:
        return f"No listening history recorded in the last {days} days."

    lines = [f"Listening history (last {days} days, {len(result)} entries):"]
    for entry in result:
        skipped = " [SKIPPED]" if entry.get("skipped") else ""
        played = entry.get("played_seconds", 0)
        lines.append(
            f"  {str(entry.get('timestamp', ''))[:16]}  "
            f"{entry.get('artist', '?')} — {entry.get('track_title', '?')} ({played}s{skipped})"
        )
    return "\n".join(lines)


@mcp.tool()
async def save_playlist(
    name: str,
    prompt: str,
    session_id: str,
    track_numbers: list[int],
    source_mode: str = "library",
    tags: Optional[list[str]] = None,
) -> str:
    """Save a curated playlist to the local library for future replay.

    Call this after a successful curate_and_play when the user is happy.
    The playlist is stored in SQLite and can be replayed with replay_saved_playlist.

    Args:
        name:          Descriptive playlist name, e.g. "Zondagochtend Jazz".
        prompt:        The original prompt that generated this playlist.
        session_id:    The filter_tracks session_id used for curation.
        track_numbers: The selected track numbers from the session.
        source_mode:   "library", "hybrid", or "qobuz".
        tags:          Optional tags, e.g. ["avond", "werk", "roadtrip"].
    """
    logger.info("SAVE_PLAYLIST: name='%s' session=%s tracks=%d", name, session_id, len(track_numbers))
    result = await _api_call(
        "POST", "/api/playlists/saved/from-session",
        json={
            "name": name, "prompt": prompt, "session_id": session_id,
            "track_numbers": track_numbers, "source_mode": source_mode,
            "tags": tags or [],
        },
        retryable=False,
    )
    if isinstance(result, str):
        return result

    pid = result.get("playlist_id")
    tc = result.get("track_count", 0)
    return (
        f"Playlist '{name}' saved (id={pid}, {tc} tracks).\n"
        f"Replay later: replay_saved_playlist(playlist_id={pid}, zone_id=...)\n"
        "Export to Qobuz: save_to_qobuz"
    )


@mcp.tool()
async def list_saved_playlists(tag: Optional[str] = None, limit: int = 20) -> str:
    """List previously saved playlists from the local library.

    Use when the user asks "play that playlist from last week",
    "show me my saved playlists", or "wat heb ik eerder opgeslagen?".

    Args:
        tag:   Optional tag filter, e.g. "avond" or "roadtrip".
        limit: Maximum playlists to return (default 20).
    """
    logger.info("LIST_SAVED_PLAYLISTS: tag=%s limit=%d", tag, limit)
    params: dict = {"limit": limit}
    if tag:
        params["tag"] = tag
    result = await _api_call("GET", "/api/playlists/saved", params=params)
    if isinstance(result, str):
        return result
    if not result:
        return "No saved playlists found."

    lines = [f"Saved playlists ({len(result)}):"]
    for p in result:
        tags_str = ", ".join(p.get("tags", [])) or "—"
        rating = p.get("rating")
        rating_str = f" ★{rating}" if rating else ""
        lines.append(
            f"  [{p['id']}] {p['name']} — {p['track_count']} tracks"
            f" | {str(p.get('created_at', ''))[:10]} | {p.get('source_mode', 'library')}"
            f" | tags: {tags_str}{rating_str}"
        )
        if p.get("prompt"):
            lines.append(f"       Prompt: \"{str(p['prompt'])[:80]}\"")
    return "\n".join(lines)


@mcp.tool()
async def replay_saved_playlist(playlist_id: int, zone_id: str) -> str:
    """Replay a previously saved playlist on a Roon zone.

    Fetches the saved track item_keys and sends them to the zone immediately.
    Use list_saved_playlists first to find the playlist_id.

    Args:
        playlist_id: ID from list_saved_playlists.
        zone_id:     Roon zone to play in (from list_zones).
    """
    logger.info("REPLAY_SAVED_PLAYLIST: id=%d zone=%s", playlist_id, zone_id)
    playlist = await _api_call("GET", f"/api/playlists/saved/{playlist_id}/tracks")
    if isinstance(playlist, str):
        return playlist

    tracks = playlist.get("tracks", [])
    if not tracks:
        return f"Playlist {playlist_id} has no tracks stored."

    item_keys = [t.get("item_key") for t in tracks if t.get("item_key")]
    if not item_keys:
        return "No playable item_keys found in this saved playlist."

    try:
        response = await _get_playback_client().post(
            f"{ROONSAGE_URL}/api/queue",
            json={"item_keys": item_keys, "zone_id": zone_id},
        )
        response.raise_for_status()
        data = response.json()
    except Exception as exc:
        return f"Playback failed: {exc}"

    name = playlist.get("name", f"Playlist {playlist_id}")
    return f"Playing '{name}' ({len(item_keys)} tracks) on zone {zone_id}. {data.get('message', 'started')}"


@mcp.tool()
async def browse_tags() -> str:
    """Browse the user's Roon tags (user-created collections like "Chill", "Workout").

    Tags are custom groupings created in Roon. Use them as additional curation context:
    if the user has a "Road Trip" tag, those tracks are marked as suitable for driving.

    Returns tag names and item_keys. No parameters required.
    """
    logger.info("BROWSE_TAGS called")
    result = await _api_call("GET", "/api/roon/tags")
    if isinstance(result, str):
        return result
    if not result:
        return (
            "No Roon tags found. The user may not have created any tags, "
            "or the Tags section is unavailable in this Roon version."
        )

    lines = [f"Roon tags ({len(result)}):"]
    for tag in result:
        lines.append(f"  {tag.get('title', '?')}  [key: {str(tag.get('item_key', '?'))[:20]}...]")
    return "\n".join(lines)


@mcp.tool()
async def modify_playlist(
    session_id: str,
    remove_numbers: Optional[list[int]] = None,
    add_numbers: Optional[list[int]] = None,
    swap: Optional[list[list[int]]] = None,
) -> str:
    """Modify a curated playlist without starting over.

    Works on an active filter_tracks session. Returns the updated track list.
    Use the returned track_numbers with curate_and_play.

    Args:
        session_id:     Active session ID from a filter_tracks call.
        remove_numbers: Track numbers to remove, e.g. [7, 12].
        add_numbers:    Track numbers to add from the pool, e.g. [42, 88].
        swap:           Pairs to swap in order, e.g. [[3, 15]] swaps positions of 3 and 15.
    """
    logger.info("MODIFY_PLAYLIST: session=%s remove=%s add=%s swap=%s",
                session_id, remove_numbers, add_numbers, swap)
    body: dict = {"session_id": session_id}
    if remove_numbers:
        body["remove_numbers"] = remove_numbers
    if add_numbers:
        body["add_numbers"] = add_numbers
    if swap:
        body["swap"] = swap

    result = await _api_call("POST", "/api/playlists/modify", json=body, retryable=False)
    if isinstance(result, str):
        return result

    track_numbers = result.get("track_numbers", [])
    tracks = result.get("tracks", [])

    lines = [
        f"Playlist modified: {result.get('track_count', 0)} tracks.",
        f"Removed: {result.get('removed', [])}  Added: {result.get('added', [])}  Swapped: {result.get('swapped', [])}",
        "",
        "Updated order (first 30):",
    ]
    for t in tracks[:30]:
        lines.append(f"  {t['number']}. {t.get('artist', '?')} — {t.get('title', '?')} ")
    lines.append("")
    lines.append(f"Call curate_and_play with track_numbers={track_numbers}, session_id='{session_id}'")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# ListenBrainz tools (MCP v6.0)
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_listening_stats(days: int = 30) -> str:
    """Get combined local + ListenBrainz listening statistics.

    Provides a rich overview of the user's music listening patterns:
    - Local stats: top artists, genres, decades, hour heatmap
    - ListenBrainz stats (when configured): genre by hour, era distribution,
      artist map by country, daily activity heatmap, similar users

    Use this to inform time-aware curation decisions (e.g. ambient in the evening).

    Args:
        days: Number of days to look back for local stats (default 30).
    """
    logger.info("GET_LISTENING_STATS: days=%d", days)
    result = await _api_call("GET", "/api/intelligence/listening-stats", params={"days": days})
    if isinstance(result, str):
        return result

    local = result.get("local", {})
    lb = result.get("listenbrainz", {})

    lines = [
        f"📊 Listening stats (last {days} days):",
        f"  Total tracks: {local.get('total_tracks', 0)}",
        f"  Total minutes: {local.get('total_minutes', 0)}",
        f"  Skip rate: {local.get('skip_rate_pct', 0)}%",
        "",
    ]

    if local.get("top_artists"):
        lines.append("Top artists:")
        for a in local["top_artists"][:10]:
            lines.append(f"  {a['artist']} ({a['plays']} plays)")
        lines.append("")

    if local.get("top_genres"):
        lines.append("Top genres:")
        for g in local["top_genres"][:8]:
            lines.append(f"  {g['genre']} ({g['plays']} plays)")
        lines.append("")

    if local.get("decades"):
        lines.append("Decades:")
        for d in local["decades"]:
            lines.append(f"  {d['decade']}: {d['plays']} plays")
        lines.append("")

    if lb:
        lines.append("── ListenBrainz data ──")
        if lb.get("last_synced"):
            lines.append(f"  Last synced: {str(lb['last_synced'])[:16]}")
        if lb.get("artist_map"):
            countries = lb["artist_map"][:5]
            lines.append(f"  Artist countries: {', '.join(c.get('country', '') for c in countries)}")
        if lb.get("similar_users"):
            similar = lb["similar_users"][:3]
            lines.append(f"  Similar users: {', '.join(u.get('user_name', '') for u in similar)}")

    return "\n".join(lines)


@mcp.tool()
async def get_listenbrainz_recommendations() -> str:
    """Get ListenBrainz 'Created for You' playlist recommendations.

    ListenBrainz analyses your listening history and creates personalised
    playlist suggestions. This tool fetches those recommendations so you can
    search the tracks in Roon or Qobuz and play them.

    Requires LISTENBRAINZ_TOKEN and LISTENBRAINZ_USERNAME to be configured.
    """
    logger.info("GET_LISTENBRAINZ_RECOMMENDATIONS called")
    result = await _api_call("GET", "/api/intelligence/listenbrainz/recommendations")
    if isinstance(result, str):
        return result
    if not result:
        return (
            "No ListenBrainz recommendations available. "
            "Make sure LISTENBRAINZ_TOKEN is configured and you have enough listening history."
        )

    lines = [f"🎵 ListenBrainz has {len(result)} recommendation playlist(s) for you:\n"]
    for playlist in result[:5]:
        title = playlist.get("playlist", {}).get("title", "Untitled")
        description = playlist.get("playlist", {}).get("annotation", "")[:80]
        track_count = len(playlist.get("playlist", {}).get("track", []))
        lines.append(f"• **{title}** ({track_count} tracks)")
        if description:
            lines.append(f"  {description}")
        lines.append("")

    lines.append(
        "To play a recommendation: note the track titles/artists from the playlist data "
        "and use search_library or search_qobuz to find playable versions."
    )
    return "\n".join(lines)


@mcp.tool()
async def submit_listen_feedback(
    artist: str,
    title: str,
    score: int,
    recording_msid: Optional[str] = None,
) -> str:
    """Submit love (+1) or hate (-1) feedback for a track to ListenBrainz.

    This both updates the taste profile (dislikes list for -1, positive signal
    for +1) and sends the feedback to ListenBrainz so future recommendations
    are improved.

    Use this when:
    - The user explicitly says they love or hate a track
    - After a playlist, offer "Want to mark any tracks as loved or hated?"
    - When the user skips a track multiple times

    Args:
        artist:         Track artist name.
        title:          Track title.
        score:          +1 (love) or -1 (hate).
        recording_msid: Optional ListenBrainz MessyBrainz ID. If not provided,
                        feedback is only applied to the taste profile, not sent to LB.
    """
    logger.info("SUBMIT_LISTEN_FEEDBACK: '%s — %s' score=%d", artist, title, score)
    if score not in (1, -1):
        return "Score must be +1 (love) or -1 (hate)."

    msgs = []

    # 1. Update taste profile
    if score == -1:
        updates = {"dislikes": [f"{artist} — {title}"]}
        await _api_call("POST", "/api/taste/profile", json={"updates": updates}, retryable=False)
        msgs.append(f"Added '{artist} — {title}' to your dislikes list.")
    else:
        # Boost artist preference slightly
        updates = {"artists": {artist: 0.9}}
        await _api_call("POST", "/api/taste/profile", json={"updates": updates}, retryable=False)
        msgs.append(f"Boosted artist preference for {artist}.")

    # 2. Log taste event
    await _api_call(
        "POST", "/api/taste/event",
        json={
            "event_type": "feedback",
            "data": {"artist": artist, "title": title, "score": score},
        },
        retryable=False,
    )

    # 3. Send to ListenBrainz (only if recording_msid is provided)
    if recording_msid:
        lb_result = await _api_call(
            "POST", "/api/intelligence/listenbrainz/feedback",
            json={"artist": artist, "title": title, "recording_msid": recording_msid, "score": score},
            retryable=False,
        )
        if isinstance(lb_result, dict) and lb_result.get("success"):
            msgs.append(f"Feedback sent to ListenBrainz ({'❤️ loved' if score == 1 else '👎 hated'}).")

    emoji = "❤️" if score == 1 else "👎"
    return f"{emoji} {' '.join(msgs)}"


@mcp.tool()
async def sync_listenbrainz() -> str:
    """Manually trigger a ListenBrainz stats synchronisation.

    Pulls fresh genre activity, daily patterns, era distribution, artist map,
    top artists/recordings/releases, and feedback from ListenBrainz.
    Caches results for 6 hours (auto-sync runs every 6 hours in the background).

    Use this when:
    - The user asks for fresh ListenBrainz data
    - After connecting ListenBrainz for the first time
    - To get up-to-date recommendations

    No parameters required. Requires ListenBrainz to be configured.
    """
    logger.info("SYNC_LISTENBRAINZ called")
    result = await _api_call("POST", "/api/intelligence/listenbrainz/sync", retryable=False)
    if isinstance(result, str):
        return result

    summary = result.get("summary", {})
    synced = [k for k, v in summary.items() if v == "synced"]
    cached = [k for k, v in summary.items() if v == "cached"]
    failed = [k for k, v in summary.items() if v == "failed"]

    lines = ["✅ ListenBrainz sync complete!"]
    if synced:
        lines.append(f"  Fresh data: {', '.join(synced)}")
    if cached:
        lines.append(f"  Still fresh (cached): {len(cached)} stat types")
    if failed:
        lines.append(f"  ⚠️ Failed: {', '.join(failed)}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    asyncio.run(_startup_health_check())
    mcp.run(transport="stdio")
