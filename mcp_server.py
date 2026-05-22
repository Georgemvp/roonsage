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
import atexit
import contextlib
import json
import logging
import os
from collections.abc import AsyncGenerator

import httpx
from mcp.server.fastmcp import FastMCP

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
            with contextlib.suppress(Exception):
                await client.aclose()


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def get_discovery_sections() -> str:
    """Return all 4 Cache-Powered Discovery sections for the user's library.

    Zero LLM calls, zero external APIs — pure SQL queries against the local
    SQLite library cache. Use this to surface hidden gems and forgotten music.

    Sections returned:
    - undiscovered_albums  Albums by the user's most-played artists with zero plays.
                           Great for "I know this artist well — what else do they have?"
    - deep_cuts            Under-played tracks from the top-20 most-listened artists.
                           These are the tracks on side B the user keeps skipping.
    - forgotten_favorites  Tracks with 5+ total plays but no play in the last 60 days.
                           Use for "Rediscover" playlists or gentle nudges.
    - genre_explorer       All library genres with artist_count and track_count,
                           sorted by artist diversity. Use to surface niche genres
                           or understand the depth of the collection.

    Suggested uses:
    - "What albums of mine haven't I played?" → undiscovered_albums
    - "Play something I haven't heard in a while" → forgotten_favorites (pick 15–20 tracks)
    - "I want to go deeper into [artist]" → deep_cuts filtered by artist
    - "What genres do I have?" → genre_explorer
    - "Surprise me" → combine all sections, pick diverse selection
    """
    logger.info("GET_DISCOVERY_SECTIONS called")
    result = await _api_call("GET", "/api/discovery/sections")
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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


async def _fetch_taste_hint() -> str:
    """Fetch the compact taste profile summary from the backend.

    Returns an empty string when the backend is unreachable or has no profile —
    so the caller can simply skip the hint without error handling.
    """
    try:
        response = await _get_client().get(
            f"{ROONSAGE_URL}/api/intelligence/taste-profile/summary"
        )
        response.raise_for_status()
        return (response.json() or {}).get("summary", "") or ""
    except Exception as exc:
        logger.debug("taste-profile summary fetch failed: %s", exc)
        return ""


@mcp.tool()
async def filter_tracks(
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    exclude_live: bool = True,
    max_tracks: int = 200,
    output_format: str = "json",
    artist_limit: int = 2,
    exclude_keywords: list[str] | None = None,
    include_taste_profile: bool = True,
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
        include_taste_profile: When True (default), the response includes a
                          `taste_hint` field with a compact summary of the user's
                          listening profile (top genres/artists, recent activity,
                          dislikes, skip signals). USE THIS as the primary curation
                          signal — it removes the need for a separate
                          get_taste_profile call. Set to False for raw filtering
                          without taste bias.
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

    taste_hint = await _fetch_taste_hint() if include_taste_profile else ""

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
        if taste_hint:
            result["taste_hint"] = taste_hint
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
        if taste_hint:
            result["taste_hint"] = taste_hint
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

    if taste_hint:
        data["taste_hint"] = taste_hint

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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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

    # Report complete failure when all tracks were skipped
    if tracks_queued == 0 and tracks_skipped > 0:
        return (
            f"PLAYBACK FAILED: 0 tracks played, {tracks_skipped} skipped. "
            f"All item keys appear to be stale. Run sync_library first to refresh "
            f"the library cache, then retry the playlist. "
            f"If this persists, Roon search may be unavailable — check Roon Core connection."
        )
    # Report partial skip even on success
    if tracks_skipped > 0:
        return (
            f"Playing {tracks_queued} tracks. "
            f"Warning: {tracks_skipped} tracks were skipped (not found in Roon)."
        )

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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def sync_library() -> str:
    """Trigger a library sync to refresh the local cache from Roon.
    Use this when library stats show 0 tracks or when the user asks to refresh/sync their library.
    The sync runs in the background — it may take a minute for large libraries."""
    logger.info("SYNC_LIBRARY called")
    result = await _api_call("POST", "/api/library/sync")
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    genres: list[str] | None = None,
    decades: list[str] | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def seed_track_playlist(
    item_key: str,
    dimensions: list[str],
    track_count: int = 25,
    decades: list[str] | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def recommend_album_interactive(
    prompt: str,
    answers: list[str] | None = None,
    session_id: str | None = None,
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
    value: str | None = None,
    position_seconds: int | None = None,
    seek_offset: int | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def get_result_history(
    type: str | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def volume_control(
    zone_name: str,
    action: str,
    value: int | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def zone_grouping(
    action: str,
    zones: list[str] | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def browse_playlists(
    action: str,
    playlist_name: str | None = None,
    zone_id: str | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    add_tracks: list[str] | None = None,
    remove_indices: list[int] | None = None,
    new_name: str | None = None,
    new_description: str | None = None,
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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


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
    return json.dumps(result, ensure_ascii=False, indent=2) if isinstance(result, dict | list) else result


@mcp.tool()
async def browse_qobuz_new_releases(
    genre: str | None = None,
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
    session_id: str | None = None,
    track_numbers: list[int] | None = None,
    item_keys: list[str] | None = None,
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
    """Full taste profile including:
    - genres, decades, artists, moods (0-1 scores, time-weighted)
    - recently_active (top genres/artists from last 7 days)
    - artist_streaks (artists with ≥5 plays this week)
    - listening_patterns (genre preferences by time of day and weekday/weekend)
    - skip_signals (genres/artists with >50% skip rate — avoid these)
    - top_albums (most-played albums)
    - dislikes, notes (explicit user preferences)
    - lb_* keys (ListenBrainz data, if configured)

    Call this at the START of every session. Use recently_active.top_genres as the
    primary filter signal (current taste). Use skip_signals to avoid disliked content.
    Use listening_patterns for time-aware curation without ListenBrainz.

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
    # New enriched keys — pass through as-is (already compact from compute)
    for key in ("recently_active", "listening_patterns", "skip_signals", "artist_streaks", "top_albums"):
        val = result.get(key)
        if val:
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
    genre_preferences: dict | None = None,
    artist_preferences: dict | None = None,
    decade_preferences: dict | None = None,
    mood_preferences: dict | None = None,
    dislikes: list[str] | None = None,
    notes: list[str] | None = None,
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
    feedback: str | None = None,
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
async def get_zone_history(
    zone: str,
    days: int = 30,
    limit: int = 30,
) -> str:
    """Get listening history and stats for a specific Roon zone.

    Use this when the user asks what has been playing in a particular room,
    wants zone-specific recommendations, or asks about listening habits per zone.

    Args:
        zone:  Exact zone name as shown in Roon (e.g. "Woonkamer", "Slaapkamer").
        days:  How many days back to look (default 30).
        limit: Maximum history entries to return (default 30).
    """
    logger.info("GET_ZONE_HISTORY: zone='%s' days=%d limit=%d", zone, days, limit)

    history, stats = await asyncio.gather(
        _api_call("GET", "/api/listening/history", params={"zone": zone, "days": days, "limit": limit}),
        _api_call("GET", "/api/listening/stats", params={"zone": zone, "days": days}),
        return_exceptions=True,
    )

    lines = [f"Zone: {zone} (last {days} days)"]

    if isinstance(stats, dict) and not isinstance(stats, Exception):
        lines.append(
            f"Plays: {stats.get('total_tracks', 0)} tracks · "
            f"{stats.get('total_minutes', 0)} min · "
            f"skip rate {stats.get('skip_rate_pct', 0)}%"
        )
        artists = stats.get("top_artists", [])
        if artists:
            lines.append("Top artists: " + ", ".join(
                f"{a['artist']} ({a['plays']})" for a in artists[:5]
            ))
        genres = stats.get("top_genres", [])
        if genres:
            lines.append("Top genres: " + ", ".join(
                f"{g['genre']} ({g['plays']})" for g in genres[:5]
            ))

    if isinstance(history, list) and history:
        lines.append(f"\nRecent tracks ({len(history)}):")
        for entry in history:
            skipped = " [SKIPPED]" if entry.get("skipped") else ""
            lines.append(
                f"  {str(entry.get('timestamp', ''))[:16]}  "
                f"{entry.get('artist', '?')} — {entry.get('track_title', '?')}{skipped}"
            )
    elif not (isinstance(history, list) and history):
        lines.append("No history found for this zone.")

    return "\n".join(lines)


@mcp.tool()
async def save_playlist(
    name: str,
    prompt: str,
    session_id: str,
    track_numbers: list[int],
    source_mode: str = "library",
    tags: list[str] | None = None,
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
async def list_saved_playlists(tag: str | None = None, limit: int = 20) -> str:
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
    remove_numbers: list[int] | None = None,
    add_numbers: list[int] | None = None,
    swap: list[list[int]] | None = None,
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
    recording_msid: str | None = None,
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
# Playlist Templates
# ---------------------------------------------------------------------------


@mcp.tool()
async def list_playlist_templates() -> str:
    """List all available playlist templates (built-in and user-created).

    Returns each template's id, name, description, icon, track count, filter
    presets, and whether it is built-in or user-created.

    Use this to show the user which one-click templates are available before
    calling generate_from_template.  No parameters required.
    """
    logger.info("LIST_PLAYLIST_TEMPLATES called")
    result = await _api_call("GET", "/api/templates")
    if isinstance(result, str):
        return result

    lines = ["Available playlist templates:\n"]
    for t in result:
        builtin_tag = "(built-in)" if t.get("is_builtin") else "(custom)"
        filters = t.get("filters", {})
        genres_hint = ", ".join(filters.get("genres", [])) or "any genre"
        decades_hint = ", ".join(filters.get("decades", [])) or "any decade"
        lines.append(
            f"{t.get('icon', '🎵')} [{t['id']}] {t['name']} {builtin_tag}\n"
            f"   {t.get('description', '')}\n"
            f"   Tracks: {t.get('track_count', 25)} | "
            f"Genres: {genres_hint} | Decades: {decades_hint}"
        )
    return "\n\n".join(lines)


@mcp.tool()
async def generate_from_template(
    template_id: str,
    zone_id: str,
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    track_count: int | None = None,
    exclude_live: bool | None = None,
) -> str:
    """Generate a playlist from a pre-defined template and start playback.

    Loads the template by ID (use list_playlist_templates to browse available
    templates), generates a playlist using the template's prompt and filter
    presets, then immediately plays it in the specified zone.

    Optional parameters override the template's defaults — for example, you
    can restrict to a specific decade or adjust the track count.

    Args:
        template_id:  Template slug, e.g. "friday-night-chill", "late-night-jazz".
                      Call list_playlist_templates first to get the full list.
        zone_id:      Roon zone ID (or zone name substring) to play in.
                      Call list_zones to find available zones.
        genres:       Optional genre override, e.g. ["Jazz", "Blues"].
                      Pass None to use the template's genre presets.
        decades:      Optional decade override, e.g. ["1980s", "1990s"].
                      Pass None to use the template's decade presets.
        track_count:  Override the number of tracks (default: template's value).
        exclude_live: Override live-track exclusion (default: template's setting).
    """
    logger.info(
        "GENERATE_FROM_TEMPLATE: id=%s zone=%s", template_id, zone_id
    )

    # Build override body (only include fields that are explicitly overridden)
    override_body: dict = {}
    if genres is not None:
        override_body["genres"] = genres
    if decades is not None:
        override_body["decades"] = decades
    if track_count is not None:
        override_body["track_count"] = track_count
    if exclude_live is not None:
        override_body["exclude_live"] = exclude_live

    # Stream the template generate endpoint
    tracks_batches: list[list[dict]] = []
    complete_data: dict = {}
    errors: list[str] = []

    try:
        async with _get_stream_client().stream(
            "POST",
            f"{ROONSAGE_URL}/api/templates/{template_id}/generate",
            json=override_body if override_body else None,
        ) as response:
            if response.status_code == 404:
                await response.aread()
                return f"Template '{template_id}' not found. Use list_playlist_templates to see available templates."
            if response.status_code != 200:
                await response.aread()
                return f"RoonSage API error: {response.status_code} — {response.text}"

            async for event_type, payload in _parse_sse_events(response):
                if event_type == "tracks":
                    batch = payload.get("batch", [])
                    if batch:
                        tracks_batches.append(batch)
                elif event_type == "complete":
                    complete_data = payload
                elif event_type == "error":
                    errors.append(payload.get("message", "Unknown error"))

    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.ReadTimeout:
        return "Template generation timed out. Try again."
    except httpx.HTTPStatusError as exc:
        return f"RoonSage API error: {exc.response.status_code} — {exc.response.text}"

    if errors:
        return f"Template generation failed: {'; '.join(errors)}"

    all_tracks = [t for batch in tracks_batches for t in batch]
    if not all_tracks and not complete_data:
        return "Template generation produced no results. Check that the library is synced."

    # Build result
    requested_count = track_count or complete_data.get("track_count", 25)
    result = _build_playlist_result(all_tracks, complete_data, requested_count, exclude_live or True)

    # Start playback
    item_keys = [t.get("item_key", "") for t in all_tracks[:requested_count] if t.get("item_key")]
    if not item_keys:
        return f"Playlist generated but no playable tracks found.\n{json.dumps(result, ensure_ascii=False, indent=2)}"

    play_resp = await _api_call(
        "POST", "/api/queue",
        json={"item_keys": item_keys, "zone_id": zone_id},
        retryable=False,
    )
    if isinstance(play_resp, str):
        # Playback failed — still return the playlist
        return (
            f"Playlist generated but playback failed: {play_resp}\n\n"
            f"Tracks:\n{json.dumps(result, ensure_ascii=False, indent=2)}"
        )

    playlist_title = result.get("playlist_title") or f"Template: {template_id}"
    track_list = "\n".join(
        f"  {i+1}. {t.get('artist', '?')} — {t.get('title', '?')}"
        for i, t in enumerate(result.get("tracks", []))
    )
    return (
        f"▶ Now playing: {playlist_title}\n\n"
        f"{track_list}\n\n"
        f"Genre breakdown: {result.get('genre_breakdown', 'N/A')}"
    )


# ---------------------------------------------------------------------------
# Watchlist tools
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_watchlist() -> str:
    """Return all artists currently on the watchlist with their status.

    Each entry shows: artist name, last time Qobuz was checked, last new release
    found, and count of unread/unnotified releases.  Use this to see which artists
    you are monitoring and whether any new releases are waiting.
    """
    logger.info("GET_WATCHLIST called")
    result = await _api_call("GET", "/api/watchlist")
    if isinstance(result, str):
        return result
    artists = result if isinstance(result, list) else result.get("items", [])
    if not artists:
        return "Watchlist is empty. Use add_to_watchlist to start monitoring artists."
    lines = ["## Artist Watchlist\n"]
    for a in artists:
        unread = a.get("unnotified_count", 0)
        checked = a.get("last_checked") or "never"
        badge = f" 🆕 {unread} new" if unread else ""
        flags = []
        if a.get("monitor_albums"):
            flags.append("albums")
        if a.get("monitor_eps"):
            flags.append("EPs")
        if a.get("monitor_singles"):
            flags.append("singles")
        flag_str = ", ".join(flags) if flags else "nothing"
        auto = " (auto-added)" if a.get("auto_added") else ""
        lines.append(
            f"- **{a['artist_name']}**{badge}{auto} — monitoring: {flag_str} — last checked: {checked}"
        )
    return "\n".join(lines)


@mcp.tool()
async def add_to_watchlist(
    artist_name: str,
    monitor_albums: bool = True,
    monitor_eps: bool = True,
    monitor_singles: bool = False,
) -> str:
    """Add an artist to the watchlist so RoonSage monitors them for new Qobuz releases.

    Args:
        artist_name:     Name of the artist to monitor.
        monitor_albums:  Notify on new full-length albums (default True).
        monitor_eps:     Notify on new EPs (default True).
        monitor_singles: Notify on new singles (default False).
    """
    logger.info("ADD_TO_WATCHLIST called: %s", artist_name)
    result = await _api_call(
        "POST",
        "/api/watchlist",
        json={
            "artist_name": artist_name,
            "monitor_albums": monitor_albums,
            "monitor_eps": monitor_eps,
            "monitor_singles": monitor_singles,
        },
        retryable=False,
    )
    if isinstance(result, str):
        return result
    return f"✅ Added **{artist_name}** to watchlist."


@mcp.tool()
async def scan_watchlist() -> str:
    """Trigger an immediate scan of all watched artists for new Qobuz releases.

    This queries Qobuz for each watched artist and compares the results against
    the previously cached releases.  Any releases not seen before are recorded
    and returned.  The scan respects per-artist monitor flags (albums/EPs/singles).

    Returns a summary of all new releases found, or a message if nothing is new.
    May take up to a minute for large watchlists due to Qobuz rate limiting.
    """
    logger.info("SCAN_WATCHLIST called")
    result = await _api_call(
        "POST",
        "/api/watchlist/scan",
        retryable=False,
        timeout=120.0,
    )
    if isinstance(result, str):
        return result
    releases = result.get("releases", [])
    found = result.get("new_releases_found", 0)
    if not releases:
        return "Scan complete. No new releases found."

    lines = [f"## 🆕 {found} New Release(s) Found\n"]
    for r in releases:
        date_str = f" ({r['release_date']})" if r.get("release_date") else ""
        lines.append(
            f"- **{r['artist_name']}** — {r['album_title']}{date_str} [{r.get('release_type', 'album')}]"
        )
    lines.append(
        "\nUse `play_new_release` to start playback of any of these, "
        "or `get_watchlist` to see the full list."
    )
    return "\n".join(lines)


@mcp.tool()
async def play_new_release(
    artist_name: str,
    album_title: str,
    zone_id: str | None = None,
) -> str:
    """Play a new release found by the watchlist scanner.

    This searches Qobuz for the specific album and starts playback in the
    given zone (or the first active zone if none is specified).

    Args:
        artist_name:  Artist name exactly as shown in the watchlist.
        album_title:  Album title exactly as shown in the new-releases list.
        zone_id:      Optional Roon zone ID or name. Uses first active zone if omitted.
    """
    logger.info("PLAY_NEW_RELEASE called: %s — %s", artist_name, album_title)

    # Look up the item_key from the releases cache
    releases_resp = await _api_call("GET", "/api/watchlist/new-releases?include_dismissed=true")
    if isinstance(releases_resp, str):
        return releases_resp

    releases = releases_resp if isinstance(releases_resp, list) else []
    match = next(
        (
            r for r in releases
            if r.get("artist_name", "").lower() == artist_name.lower()
            and r.get("album_title", "").lower() == album_title.lower()
        ),
        None,
    )

    if not match:
        return (
            f"Release '{album_title}' by {artist_name} not found in the watchlist cache. "
            "Run scan_watchlist first, or use search_qobuz to find and play it manually."
        )

    item_key = match.get("item_key")
    if not item_key:
        # Fallback: search Qobuz live
        qobuz_resp = await _api_call(
            "POST",
            "/api/roon/qobuz-search",
            json={"query": f"{artist_name} {album_title}", "limit": 5},
            retryable=False,
        )
        if isinstance(qobuz_resp, str):
            return qobuz_resp
        tracks = qobuz_resp.get("tracks", []) if isinstance(qobuz_resp, dict) else []
        if not tracks:
            return (
                f"Could not find '{album_title}' by {artist_name} on Qobuz. "
                "It may not be available in your region."
            )
        item_key = tracks[0].get("item_key")

    if not item_key:
        return f"No playable item key found for '{album_title}' by {artist_name}."

    # Resolve zone_id if a name was given
    if not zone_id:
        zones_resp = await _api_call("GET", "/api/roon/zones")
        if isinstance(zones_resp, list) and zones_resp:
            zone_id = zones_resp[0].get("zone_id", "")

    play_resp = await _api_call(
        "POST",
        "/api/queue",
        json={"item_keys": [item_key], "zone_id": zone_id or ""},
        retryable=False,
    )
    if isinstance(play_resp, str):
        return f"Playback failed: {play_resp}"

    # Mark as dismissed/notified
    release_id = match.get("id")
    if release_id:
        await _api_call(
            "POST",
            f"/api/watchlist/new-releases/{release_id}/dismiss",
            retryable=False,
        )

    return f"▶ Now playing: **{album_title}** by {artist_name}"


# ---------------------------------------------------------------------------
# Scheduled Playlist tools
# ---------------------------------------------------------------------------


@mcp.tool()
async def list_scheduled_playlists() -> str:
    """List all scheduled playlists with their current status.

    Returns every schedule with name, prompt, cron expression, last run time,
    last status (success/failed), enabled state, and optional Qobuz playlist ID.

    Use this to review what is configured and check whether recent runs succeeded.
    No parameters required.
    """
    logger.info("LIST_SCHEDULED_PLAYLISTS called")
    result = await _api_call("GET", "/api/schedules")
    if isinstance(result, str):
        return result
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def create_scheduled_playlist(
    name: str,
    prompt: str,
    schedule: str,
    track_count: int = 25,
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    exclude_live: bool = True,
    zone_name: str | None = None,
    save_to_qobuz: bool = True,
) -> str:
    """Create a new scheduled playlist that auto-regenerates on a cron schedule.

    Translate the user's natural-language timing into a cron expression:
      - "every morning at 7"        → "0 7 * * *"
      - "weekdays at 7am"           → "0 7 * * 1-5"
      - "every Friday evening at 6" → "0 18 * * 5"
      - "every Sunday at 10"        → "0 10 * * 0"
      - "every day at noon"         → "0 12 * * *"

    Cron format: "minute hour day-of-month month day-of-week"
      - day-of-week: 0=Sunday, 1=Monday, …, 6=Saturday

    When save_to_qobuz=True the playlist is saved (or refreshed) in the user's
    Qobuz account automatically after each generation. Requires Qobuz credentials
    to be configured in RoonSage.

    When zone_name is set the freshly generated playlist is queued into that Roon
    zone immediately after generation.

    Args:
        name:         Short display name for the schedule (e.g. "Morning Commute").
        prompt:       Natural-language description of the desired playlist.
        schedule:     Cron expression (5 fields).
        track_count:  Number of tracks to generate (default 25).
        genres:       Optional genre filter list.
        decades:      Optional decade filter list (e.g. ["1970s", "1980s"]).
        exclude_live: Exclude live recordings (default True).
        zone_name:    Optional Roon zone name to auto-play in after generation.
        save_to_qobuz: Save/refresh the playlist in Qobuz after each run (default True).
    """
    logger.info(
        "CREATE_SCHEDULED_PLAYLIST: name=%r schedule=%r prompt=%r", name, schedule, prompt
    )
    filters = {
        "genres": genres or [],
        "decades": decades or [],
        "exclude_live": exclude_live,
    }
    payload = {
        "name": name,
        "prompt": prompt,
        "schedule": schedule,
        "track_count": track_count,
        "filters": filters,
        "zone_name": zone_name,
        "save_to_qobuz": save_to_qobuz,
        "enabled": True,
    }
    result = await _api_call("POST", "/api/schedules", json=payload, retryable=False)
    if isinstance(result, str):
        return result
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def run_scheduled_playlist(schedule_id: int) -> str:
    """Trigger an immediate run of a scheduled playlist, ignoring its cron timing.

    Useful for testing a new schedule or regenerating a playlist on demand.
    The run happens in the background; check list_scheduled_playlists afterwards
    to see the last_status and last_run fields.

    Args:
        schedule_id: Numeric ID from list_scheduled_playlists.
    """
    logger.info("RUN_SCHEDULED_PLAYLIST: id=%d", schedule_id)
    result = await _api_call(
        "POST", f"/api/schedules/{schedule_id}/run", retryable=False
    )
    if isinstance(result, str):
        return result
    return json.dumps(result, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# Metadata Enrichment tools (v10.0)
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_enrichment_status() -> str:
    """Show the status of the background metadata enrichment pipeline.

    The enrichment pipeline fetches MusicBrainz tags (e.g. "cool jazz",
    "modal") and Last.fm tags (e.g. "melancholic", "late night") for every
    track in the library.  These enriched tags improve mood-based playlist
    curation — the LLM sees far more context than just the Roon genre.

    Returns:
      - Counts: pending / processing / complete / failed items in the queue
      - enriched_total: how many tracks have been enriched so far
      - mb_matches: MusicBrainz hits
      - lastfm_matches: Last.fm hits
      - Worker state: running / paused

    No parameters required.
    """
    logger.info("GET_ENRICHMENT_STATUS called")
    result = await _api_call("GET", "/api/enrichment/status")
    if isinstance(result, str):
        return result

    pending = result.get("pending", 0)
    complete = result.get("complete", 0)
    failed = result.get("failed", 0)
    total = result.get("enriched_total", 0)
    mb = result.get("mb_matches", 0)
    lf = result.get("lastfm_matches", 0)
    running = result.get("worker_running", False)
    paused = result.get("worker_paused", False)

    state = "paused" if paused else ("running" if running else "stopped")
    lines = [
        f"Metadata Enrichment Pipeline — worker: {state}",
        f"  Enriched: {total} tracks  (MusicBrainz: {mb}, Last.fm: {lf})",
        f"  Queue:    pending={pending}  complete={complete}  failed={failed}",
    ]
    if pending > 0:
        lines.append(f"  → {pending} tracks still to enrich. Call start_enrichment to process them.")
    elif pending == 0 and running:
        lines.append("  ✓ All tracks enriched. Worker is idle.")
    return "\n".join(lines)


@mcp.tool()
async def start_enrichment() -> str:
    """Start (or resume) the background metadata enrichment pipeline.

    Scans the library for un-enriched tracks, adds them to the queue, and
    starts the background worker.  The worker fetches MusicBrainz and Last.fm
    tags for each track at ~1 track/second (MusicBrainz rate limit).

    This is a background process — you don't need to wait for it to finish.
    A library of 10,000 tracks takes ~3 hours to fully enrich.

    Use get_enrichment_status to monitor progress.

    No parameters required.
    """
    logger.info("START_ENRICHMENT called")
    result = await _api_call("POST", "/api/enrichment/start", retryable=False)
    if isinstance(result, str):
        return result

    queued = result.get("queued", 0)
    message = result.get("message", "")
    return f"✓ {message}\n{queued} new tracks added to enrichment queue."


# ---------------------------------------------------------------------------
# Automation Engine tools (v11.0)
# ---------------------------------------------------------------------------


@mcp.tool()
async def list_automations() -> str:
    """List all automations with their current status, last run time, and run count.

    Automations are trigger-action pairs that run workflows automatically.
    Triggers include: schedule (cron), track_played, zone_started, library_synced,
    lb_synced, and watchlist_match.
    Actions include: generate_playlist, play_template, sync_library,
    sync_listenbrainz, scan_watchlist, send_notification, run_maintenance, volume_set.

    No parameters required.
    """
    logger.info("LIST_AUTOMATIONS called")
    result = await _api_call("GET", "/api/automations")
    if isinstance(result, str):
        return result

    if not result:
        return "No automations configured yet. Use create_automation to add one."

    lines = [f"Automations ({len(result)} total):"]
    for a in result:
        status_icon = "✓" if a.get("last_status") == "success" else ("✗" if a.get("last_status") == "failed" else "—")
        enabled_icon = "🟢" if a.get("enabled") else "⭕"
        trigger = a.get("trigger_type", "?")
        trigger_cfg = a.get("trigger_config") or {}
        if trigger == "schedule":
            trigger_desc = f"schedule({trigger_cfg.get('cron', '?')})"
        else:
            trigger_desc = trigger
        lines.append(
            f"  {enabled_icon} [{a['id']}] {a['name']}  "
            f"trigger={trigger_desc}  action={a.get('action_type', '?')}  "
            f"runs={a.get('run_count', 0)}  last={a.get('last_triggered', 'never')[:16] if a.get('last_triggered') else 'never'}  {status_icon}"
        )
    return "\n".join(lines)


@mcp.tool()
async def create_automation(
    name: str,
    trigger_type: str,
    action_type: str,
    trigger_config: str = "{}",
    action_config: str = "{}",
    cooldown_seconds: int = 300,
) -> str:
    """Create a new automation from a natural language description.

    Claude picks the right trigger_type, action_type, and config values.

    Valid trigger_type values:
      - "schedule"        — cron expression in trigger_config: {"cron": "0 7 * * 1-5"}
      - "track_played"    — fires when any track finishes in any zone (no config needed)
      - "zone_started"    — fires when a zone starts playing (no config needed)
      - "library_synced"  — fires after a library sync completes (no config needed)
      - "lb_synced"       — fires after ListenBrainz sync completes (no config needed)
      - "watchlist_match" — fires when a watched artist has a new release (no config needed)

    Valid action_type values:
      - "generate_playlist"  — config: {"prompt": "...", "track_count": 20, "zone_name": "Living Room"}
      - "play_template"      — config: {"template_id": 1, "zone_name": "Kitchen"}
      - "sync_library"       — no config needed
      - "sync_listenbrainz"  — no config needed
      - "scan_watchlist"     — no config needed
      - "send_notification"  — config: {"message": "...", "event_type": "automation"}
      - "run_maintenance"    — no config needed
      - "volume_set"         — config: {"zone_name": "Living Room", "level": 40}

    Args:
        name:             Human-readable name for the automation.
        trigger_type:     One of the valid trigger_type values above.
        action_type:      One of the valid action_type values above.
        trigger_config:   JSON string with trigger parameters (see above).
        action_config:    JSON string with action parameters (see above).
        cooldown_seconds: Minimum seconds between consecutive runs (default 300).
    """
    logger.info("CREATE_AUTOMATION: name=%r trigger=%s action=%s", name, trigger_type, action_type)
    try:
        tc = json.loads(trigger_config) if trigger_config else {}
        ac = json.loads(action_config) if action_config else {}
    except json.JSONDecodeError as exc:
        return f"Error: invalid JSON in trigger_config or action_config: {exc}"

    payload = {
        "name": name,
        "trigger_type": trigger_type,
        "trigger_config": tc,
        "action_type": action_type,
        "action_config": ac,
        "cooldown_seconds": cooldown_seconds,
    }
    result = await _api_call("POST", "/api/automations", json_body=payload, retryable=False)
    if isinstance(result, str):
        return result

    return (
        f"✓ Automation created: [{result['id']}] {result['name']}\n"
        f"  Trigger: {result['trigger_type']}  Action: {result['action_type']}\n"
        f"  Enabled: {result['enabled']}  Cooldown: {result.get('cooldown_seconds')}s"
    )


@mcp.tool()
async def toggle_automation(automation_id: int) -> str:
    """Enable or disable an automation by its numeric ID.

    Toggles the current state — if enabled, it becomes disabled and vice versa.
    Use list_automations first to find the ID you want.

    Args:
        automation_id: Numeric ID of the automation (from list_automations).
    """
    logger.info("TOGGLE_AUTOMATION: id=%d", automation_id)
    result = await _api_call(
        "PATCH", f"/api/automations/{automation_id}/toggle", retryable=False
    )
    if isinstance(result, str):
        return result

    state = "enabled" if result.get("enabled") else "disabled"
    return f"✓ Automation [{automation_id}] {result.get('name', '')} is now {state}."


# ---------------------------------------------------------------------------
# AcoustID verification tool
# ---------------------------------------------------------------------------


@mcp.tool()
async def verify_track_match(
    expected_artist: str,
    expected_title: str,
    candidate_artist: str,
    candidate_title: str,
    candidate_duration: int = 0,
    expected_duration: int = 0,
) -> str:
    """Verify whether a Qobuz search result actually matches the intended track.

    Catches wrong versions — live recordings mistaken for studio, remixes
    instead of originals, acoustic versions, demos, radio edits, etc.  Uses
    fuzzy string matching plus version-marker detection.  No audio fingerprint
    is required; the check runs server-side in milliseconds.

    When AcoustID is disabled or unavailable the verification still runs using
    the local heuristics (fuzzy match + version markers) — it just won't
    include AcoustID fingerprint data.

    **When to use:**
    - After search_qobuz when the user asked for a specific version
      (e.g. "the original, not the live version")
    - Before curate_and_play when track accuracy is important
    - When the user reports that the wrong version is playing

    **Interpreting results:**
    - confidence > 0.85 → safe to play
    - confidence 0.60–0.85 → possible match; show the result to the user for confirmation
    - confidence < 0.60 → likely wrong track; search for a better match
    - version_flags → specific markers found (e.g. ["live", "remix"])

    Args:
        expected_artist:    The artist you were searching for.
        expected_title:     The exact title you were searching for.
        candidate_artist:   Artist name returned by Qobuz / search_qobuz.
        candidate_title:    Title returned by Qobuz / search_qobuz.
        candidate_duration: Duration of the Qobuz result in seconds (0 = unknown).
        expected_duration:  Duration of the original track in seconds (0 = unknown).
    """
    logger.info(
        "VERIFY_TRACK_MATCH: expected='%s — %s' candidate='%s — %s'",
        expected_artist, expected_title, candidate_artist, candidate_title,
    )
    result = await _api_call(
        "POST",
        "/api/verify/track",
        json={
            "expected_artist": expected_artist,
            "expected_title": expected_title,
            "candidate_artist": candidate_artist,
            "candidate_title": candidate_title,
            "candidate_duration": candidate_duration,
            "expected_duration": expected_duration,
        },
    )
    if isinstance(result, str):
        return result

    match = result.get("match", True)
    confidence = result.get("confidence", 0.5)
    reason = result.get("reason", "")
    flags = result.get("version_flags", [])
    acoustid_on = result.get("acoustid_enabled", False)

    status = "✅ MATCH" if match else "⚠️  MISMATCH"
    confidence_pct = f"{confidence:.0%}"
    flags_str = f"  Version flags: {', '.join(flags)}" if flags else ""
    acoustid_str = " (AcoustID enabled)" if acoustid_on else " (heuristic only)"

    return (
        f"{status}  confidence={confidence_pct}{acoustid_str}\n"
        f"  {reason}{flags_str}\n\n"
        f"  Expected:  {expected_artist} — {expected_title}"
        + (f" (~{expected_duration}s)" if expected_duration else "") + "\n"
        f"  Candidate: {candidate_artist} — {candidate_title}"
        + (f" (~{candidate_duration}s)" if candidate_duration else "")
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    asyncio.run(_startup_health_check())
    mcp.run(transport="stdio")
