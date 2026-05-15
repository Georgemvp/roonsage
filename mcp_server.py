# Claude Desktop configuration - add to ~/Library/Application Support/Claude/claude_desktop_config.json:
# {
#   "mcpServers": {
#     "roon-mediasage": {
#       "command": "python3",
#       "args": ["/FULL/PATH/TO/roon-mediasage/mcp_server.py"]
#     }
#   }
# }

"""
MediaSage MCP Server

Wraps the MediaSage REST API as MCP tools for Claude Desktop.
Claude Desktop handles all reasoning; this server provides library data and Roon connectivity.

Requirements:
    pip install "mcp[cli]" httpx

Environment variables:
    MEDIASAGE_URL  Base URL of the running MediaSage app (default: http://localhost:5765)
"""

import json
import os
from typing import Optional

import httpx
from mcp.server.fastmcp import FastMCP

MEDIASAGE_URL = os.environ.get("MEDIASAGE_URL", "http://localhost:5765").rstrip("/")
TIMEOUT = 30.0
STREAM_TIMEOUT = 300.0  # 5 minutes for SSE streams

mcp = FastMCP("roon-mediasage")


def _unavailable_msg() -> str:
    return (
        f"MediaSage is not reachable at {MEDIASAGE_URL}. "
        "Make sure the application is running (uvicorn backend.main:app --port 5765)."
    )


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------


@mcp.tool()
async def get_library_stats() -> str:
    """Return statistics about the user's Roon music library cached in MediaSage.

    Shows total track count, available genres, and available decades.
    Use this first to understand what music is in the library before filtering
    or generating playlists. No parameters required.
    """
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.get(f"{MEDIASAGE_URL}/api/library/stats/cached")
            response.raise_for_status()
            data = response.json()
            return json.dumps(data, ensure_ascii=False, indent=2)
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"


@mcp.tool()
async def search_library(query: str) -> str:
    """Search the Roon music library by track title, artist name, or album name.

    Returns matching tracks with their item_key (needed for play/queue operations),
    title, artist, and album. Use this when the user asks for specific artists,
    songs, or albums, or wants to find something particular in the library.

    Args:
        query: Search term — track title, artist name, or album name.
    """
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.get(
                f"{MEDIASAGE_URL}/api/library/search",
                params={"q": query},
            )
            response.raise_for_status()
            data = response.json()
            return json.dumps(data, ensure_ascii=False, indent=2)
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"


@mcp.tool()
async def filter_tracks(
    genres: Optional[list[str]] = None,
    decades: Optional[list[str]] = None,
    min_rating: Optional[int] = None,
    exclude_live: bool = True,
    max_tracks: int = 200,
) -> str:
    """Filter the Roon library by genre, decade, rating, and/or live-version exclusion.

    Returns a list of tracks that match all specified criteria. Each track includes
    its item_key (required for play/queue), title, artist, and album.

    Use this to narrow the library before selecting tracks for a playlist.
    Call get_library_stats first to see which genres and decades are available.

    To avoid overloading Claude's context, only the first `max_tracks` results are
    returned; the response also reports the full total so you know how large the
    filtered pool is.

    Note: min_rating filtering has no effect because Roon does not expose user
    ratings via the Extension API.

    Args:
        genres:       List of genre strings to include, e.g. ["Jazz", "Blues"].
                      Pass None or omit to include all genres.
        decades:      List of decade strings to include, e.g. ["1990s", "2000s"].
                      Pass None or omit to include all decades.
        min_rating:   Minimum star rating (1–5). Currently has no effect due to
                      Roon API limitations — all tracks are returned regardless.
        exclude_live: When True (default), tracks with "live", "concert", or year
                      patterns in their title or album name are excluded.
        max_tracks:   Maximum number of tracks to return (default 200). The full
                      total is always reported so you know the real pool size.
    """
    body: dict = {"exclude_live": exclude_live, "max_tracks": max_tracks}
    if genres:
        body["genres"] = genres
    if decades:
        body["decades"] = decades
    if min_rating is not None:
        body["min_rating"] = min_rating

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.post(
                f"{MEDIASAGE_URL}/api/library/filter",
                json=body,
            )
            response.raise_for_status()
            data = response.json()
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"

    # Strip each track to only the fields needed for playlist curation.
    # This keeps the response well under Claude Desktop's 1 MB tool-result limit.
    _KEEP = {"item_key", "rating_key", "title", "artist", "album", "genres"}
    if "tracks" in data:
        data["tracks"] = [
            {k: v for k, v in track.items() if k in _KEEP}
            for track in data["tracks"]
        ]

    # Response already has the right shape: total_matching, returned, tracks
    # Add a note when results are capped so Claude knows the real pool size
    total = data.get("total_matching", 0)
    returned = data.get("returned", 0)
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
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.get(f"{MEDIASAGE_URL}/api/roon/zones")
            response.raise_for_status()
            data = response.json()
            return json.dumps(data, ensure_ascii=False, indent=2)
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"


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
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.post(
                f"{MEDIASAGE_URL}/api/queue",
                json={"item_keys": item_keys, "zone_id": zone_id},
            )
            response.raise_for_status()
            data = response.json()
            return json.dumps(data, ensure_ascii=False, indent=2)
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"


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
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.post(
                f"{MEDIASAGE_URL}/api/queue/append",
                json={"item_keys": item_keys, "zone_id": zone_id},
            )
            response.raise_for_status()
            data = response.json()
            return json.dumps(data, ensure_ascii=False, indent=2)
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"


@mcp.tool()
async def sync_library() -> str:
    """Trigger a library sync to refresh the local cache from Roon.
    Use this when library stats show 0 tracks or when the user asks to refresh/sync their library.
    The sync runs in the background — it may take a minute for large libraries."""
    async with httpx.AsyncClient(timeout=30) as client:
        try:
            r = await client.post(f"{MEDIASAGE_URL}/api/library/sync")
            return r.text
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"


@mcp.tool()
async def generate_playlist(
    prompt: str,
    genres: Optional[list[str]] = None,
    decades: Optional[list[str]] = None,
    track_count: int = 25,
    exclude_live: bool = True,
) -> str:
    """Generate an AI-curated playlist from the Roon library using a natural language prompt.

    Calls the MediaSage streaming generation endpoint, collects all SSE events,
    and returns the final playlist with track list and metadata. This may take
    30–90 seconds for the AI to curate and match tracks.

    Use this when the user describes a mood, activity, genre, or occasion and
    wants a ready-made playlist. After generation, use play_tracks or queue_tracks
    with the returned item_keys to start playback.

    Args:
        prompt:       Natural language description, e.g. "upbeat 90s indie rock for a
                      road trip" or "calm jazz for late-night studying".
        genres:       Optional list of genre filters, e.g. ["Jazz", "Rock"].
                      Pass None to let the AI choose from the full library.
        decades:      Optional list of decade filters, e.g. ["1990s", "2000s"].
                      Pass None to include all decades.
        track_count:  Number of tracks to generate (default 25). Must be 15, 25, 50, or 100.
        exclude_live: When True (default), live and concert recordings are excluded.
    """
    body: dict = {
        "prompt": prompt,
        "track_count": track_count,
        "exclude_live": exclude_live,
    }
    if genres:
        body["genres"] = genres
    if decades:
        body["decades"] = decades

    tracks_batches: list[list[dict]] = []
    complete_data: dict = {}
    errors: list[str] = []

    try:
        async with httpx.AsyncClient(timeout=STREAM_TIMEOUT) as client:
            async with client.stream(
                "POST",
                f"{MEDIASAGE_URL}/api/generate/stream",
                json=body,
            ) as response:
                if response.status_code != 200:
                    await response.aread()
                    return f"MediaSage API error: {response.status_code} — {response.text}"

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
                        except json.JSONDecodeError:
                            continue

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
        return "Playlist generation timed out. The library may be very large or the LLM is slow. Try again."
    except httpx.HTTPStatusError as exc:
        return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"

    if errors:
        return f"Playlist generation failed: {'; '.join(errors)}"

    # Flatten all track batches
    all_tracks = [track for batch in tracks_batches for track in batch]

    if not all_tracks and not complete_data:
        return "Playlist generation produced no results. Try a different prompt or check that the library is synced."

    # Build a compact summary for Claude
    result: dict = {
        "playlist_title": complete_data.get("playlist_title", "Generated Playlist"),
        "narrative": complete_data.get("narrative", ""),
        "track_count": complete_data.get("track_count", len(all_tracks)),
        "token_count": complete_data.get("token_count", 0),
        "estimated_cost_usd": complete_data.get("estimated_cost", 0.0),
        "tracks": [
            {
                "item_key": t.get("rating_key", t.get("item_key", "")),
                "title": t.get("title", ""),
                "artist": t.get("artist", ""),
                "album": t.get("album", ""),
            }
            for t in all_tracks
        ],
    }
    if complete_data.get("result_id"):
        result["result_id"] = complete_data["result_id"]

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
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.get(f"{MEDIASAGE_URL}/api/roon/zones")
            response.raise_for_status()
            zones = response.json()
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"

    if not zones:
        return json.dumps({"zones": [], "note": "No Roon zones found. Check that Roon Core is running and MediaSage is authorized."})

    # Filter to active (non-stopped) zones and annotate
    active = [z for z in zones if z.get("state") != "stopped"]
    result = {
        "zones": zones,
        "active_zones": active,
        "note": (
            f"{len(active)} of {len(zones)} zone(s) currently playing. "
            "Use zone_id from this list with play_tracks or queue_tracks."
        ),
    }
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def recommend_album(
    prompt: str,
    mode: str = "library",
) -> str:
    """Get an AI album recommendation based on a mood or moment description.

    Runs the full MediaSage recommendation pipeline: generates clarifying questions
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
    # Step 1: Create a session via the questions endpoint (required to get a session_id)
    questions_body = {"prompt": prompt}
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            q_resp = await client.post(
                f"{MEDIASAGE_URL}/api/recommend/questions",
                json=questions_body,
            )
            q_resp.raise_for_status()
            q_data = q_resp.json()
    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.HTTPStatusError as exc:
        return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"

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
        async with httpx.AsyncClient(timeout=STREAM_TIMEOUT) as client:
            async with client.stream(
                "POST",
                f"{MEDIASAGE_URL}/api/recommend/generate",
                json=generate_body,
            ) as response:
                if response.status_code != 200:
                    await response.aread()
                    return f"MediaSage API error: {response.status_code} — {response.text}"

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
                        except json.JSONDecodeError:
                            continue

                        if event_type == "result":
                            result_payload = payload
                        elif event_type == "error":
                            errors.append(payload.get("message", "Unknown error"))

    except httpx.ConnectError:
        return _unavailable_msg()
    except httpx.ReadTimeout:
        return "Album recommendation timed out. The library may be large or the LLM is slow. Try again."
    except httpx.HTTPStatusError as exc:
        return f"MediaSage API error: {exc.response.status_code} — {exc.response.text}"

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
        }

    secondaries = [r for r in recommendations if r.get("rank") == "secondary"]
    for sec in secondaries:
        summary["additional_picks"].append({
            "album": sec.get("album", ""),
            "artist": sec.get("artist", ""),
            "year": sec.get("year"),
            "rating_key": sec.get("rating_key", ""),
            "track_rating_keys": sec.get("track_rating_keys", []),
        })

    if result_payload.get("result_id"):
        summary["result_id"] = result_payload["result_id"]

    return json.dumps(summary, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run(transport="stdio")
