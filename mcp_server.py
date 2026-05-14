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

mcp = FastMCP("roon-mediasage")


def _unavailable_msg() -> str:
    return (
        f"MediaSage is niet bereikbaar op {MEDIASAGE_URL}. "
        "Zorg dat de applicatie draait (uvicorn backend.main:app --port 5765)."
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
            return f"Fout van MediaSage API: {exc.response.status_code} — {exc.response.text}"


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
            return f"Fout van MediaSage API: {exc.response.status_code} — {exc.response.text}"


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
    body: dict = {"exclude_live": exclude_live}
    if genres:
        body["genres"] = genres
    if decades:
        body["decades"] = decades
    if min_rating is not None:
        body["min_rating"] = min_rating

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        try:
            response = await client.post(
                f"{MEDIASAGE_URL}/api/filter/preview",
                json=body,
            )
            response.raise_for_status()
            data = response.json()
        except httpx.ConnectError:
            return _unavailable_msg()
        except httpx.HTTPStatusError as exc:
            return f"Fout van MediaSage API: {exc.response.status_code} — {exc.response.text}"

    # Truncate to max_tracks to protect Claude's context window
    tracks = data if isinstance(data, list) else data.get("tracks", data)
    total = len(tracks)
    truncated = tracks[:max_tracks]

    result = {
        "total_matching": total,
        "returned": len(truncated),
        "truncated": total > max_tracks,
        "tracks": truncated,
    }
    if total > max_tracks:
        result["note"] = (
            f"Resultaat bevat {total} tracks; alleen de eerste {max_tracks} worden "
            "teruggegeven om de context beheersbaar te houden."
        )

    return json.dumps(result, ensure_ascii=False, indent=2)


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
            return f"Fout van MediaSage API: {exc.response.status_code} — {exc.response.text}"


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
            return f"Fout van MediaSage API: {exc.response.status_code} — {exc.response.text}"


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
            return f"Fout van MediaSage API: {exc.response.status_code} — {exc.response.text}"


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
            return f"Fout van MediaSage API: {exc.response.status_code} — {exc.response.text}"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run(transport="stdio")
