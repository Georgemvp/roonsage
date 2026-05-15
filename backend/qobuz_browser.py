"""Qobuz search via Roon Browse API.

Navigates the Roon Browse hierarchy to reach the Qobuz service and perform
searches. All browse calls are serialized via the client's _browse_lock to
avoid corrupting the single-session Browse API state.

If Qobuz is not configured in Roon (or not logged in), all functions return
empty results / False gracefully — no exceptions propagate to callers.
"""

import asyncio
import logging
import time
from typing import Any

logger = logging.getLogger(__name__)

# Simple TTL cache for qobuz_available so the setup status endpoint doesn't
# hammer the Browse API on every poll.  60-second TTL.
_qobuz_available_cache: tuple[bool, float] | None = None
_QOBUZ_CACHE_TTL = 60.0

# Titles that indicate a Qobuz section in the Roon browse root.
_QOBUZ_TITLE_HINTS = {"qobuz", "my qobuz"}
# Titles that indicate a search entry point within a service.
_SEARCH_TITLE_HINTS = {"search", "zoeken", "suche", "rechercher"}


def _find_item_by_title(items: list[dict[str, Any]], hints: set[str]) -> dict[str, Any] | None:
    """Return the first item whose lowercased title matches any hint."""
    for item in items:
        title_lower = (item.get("title") or "").lower().strip()
        if title_lower in hints:
            return item
    # Fuzzy: title *contains* a hint
    for item in items:
        title_lower = (item.get("title") or "").lower().strip()
        if any(h in title_lower for h in hints):
            return item
    return None


def _browse_root_items(roon) -> list[dict[str, Any]]:
    """Navigate to browse root and return its items. Must hold _browse_lock."""
    roon._api.browse_browse({"hierarchy": "browse", "pop_all": True})
    root_page = roon._api.browse_load({"hierarchy": "browse", "count": 100})
    return root_page.get("items", []) if root_page else []


def search_qobuz_tracks_sync(roon, query: str, limit: int = 10) -> list[dict[str, Any]]:
    """Synchronous implementation — must be called from a thread (not the event loop).

    Navigates: Root → Qobuz/My Qobuz → Search → query → results.

    Returns a list of dicts:
        {item_key, title, subtitle, artist, album, source="qobuz"}
    """
    try:
        with roon._browse_lock:
            # Step 1 — Navigate to root and find the Qobuz entry
            root_items = _browse_root_items(roon)
            logger.debug(
                "Qobuz browse: root has %d items: %s",
                len(root_items),
                [i.get("title") for i in root_items],
            )

            qobuz_item = _find_item_by_title(root_items, _QOBUZ_TITLE_HINTS)
            if not qobuz_item or not qobuz_item.get("item_key"):
                logger.debug("Qobuz not found in Roon browse root (not configured or not logged in)")
                return []

            # Step 2 — Navigate into Qobuz
            roon._api.browse_browse({
                "hierarchy": "browse",
                "item_key": qobuz_item["item_key"],
            })
            qobuz_page = roon._api.browse_load({"hierarchy": "browse", "count": 100})
            qobuz_items = qobuz_page.get("items", []) if qobuz_page else []

            logger.debug(
                "Qobuz sub-items: %s",
                [(i.get("title"), i.get("hint")) for i in qobuz_items],
            )

            # Step 3 — Find Search entry point
            # Roon marks search entry points with hint="input_prompt" or a title matching search hints.
            search_item = next(
                (i for i in qobuz_items if i.get("hint") == "input_prompt" and i.get("item_key")),
                None,
            ) or _find_item_by_title(qobuz_items, _SEARCH_TITLE_HINTS)

            if not search_item or not search_item.get("item_key"):
                logger.debug(
                    "No search entry point found in Qobuz. Items: %s",
                    [(i.get("title"), i.get("hint")) for i in qobuz_items[:10]],
                )
                return []

            # Step 4 — Navigate to search with query input
            roon._api.browse_browse({
                "hierarchy": "browse",
                "item_key": search_item["item_key"],
                "input": query,
            })
            results_page = roon._api.browse_load({
                "hierarchy": "browse",
                "count": min(limit * 3, 100),  # Fetch extra to allow filtering
            })
            result_items = results_page.get("items", []) if results_page else []

            logger.debug(
                "Qobuz search '%s' returned %d raw items", query, len(result_items)
            )

            # Step 5 — Parse results. Tracks have hint="action" or "action_list".
            # Some Roon versions return category items (Tracks / Albums / Artists);
            # if so, navigate into the Tracks section.
            tracks: list[dict[str, Any]] = []

            # Check if items are direct tracks
            direct_tracks = [
                i for i in result_items
                if i.get("hint") in ("action", "action_list") and i.get("item_key")
            ]

            if direct_tracks:
                tracks = direct_tracks[:limit]
            else:
                # Try navigating into "Tracks" sub-category
                tracks_section = _find_item_by_title(
                    result_items, {"tracks", "songs", "nummers", "titres", "titel"}
                )
                if tracks_section and tracks_section.get("item_key"):
                    roon._api.browse_browse({
                        "hierarchy": "browse",
                        "item_key": tracks_section["item_key"],
                    })
                    tracks_page = roon._api.browse_load({
                        "hierarchy": "browse",
                        "count": min(limit * 2, 100),
                    })
                    sub_items = tracks_page.get("items", []) if tracks_page else []
                    tracks = [
                        i for i in sub_items
                        if i.get("hint") in ("action", "action_list") and i.get("item_key")
                    ][:limit]

            # Step 6 — Convert to dicts
            output = []
            for item in tracks:
                subtitle = item.get("subtitle") or ""
                parts = [p.strip() for p in subtitle.split("•")]
                artist = parts[0] if parts else ""
                album = parts[1] if len(parts) > 1 else ""
                output.append({
                    "item_key": item["item_key"],
                    "title": item.get("title", "Unknown Track"),
                    "subtitle": subtitle,
                    "artist": artist,
                    "album": album,
                    "source": "qobuz",
                })

            logger.info(
                "Qobuz search '%s' → %d tracks", query, len(output)
            )
            return output

    except Exception as exc:
        logger.warning("Qobuz search failed for query='%s': %s", query, exc)
        return []


async def search_qobuz_tracks(query: str, limit: int = 10) -> list[dict[str, Any]]:
    """Search Qobuz for tracks via Roon's Browse API.

    Navigates: Root → My Qobuz / Qobuz → Search → query

    Args:
        query: Search string (e.g. "Miles Davis So What")
        limit: Max results to return

    Returns:
        List of dicts with item_key, title, artist, album, source="qobuz".
        Empty list if Qobuz is not configured or search fails.
    """
    from backend.roon_client import get_roon_client

    roon = get_roon_client()
    if not roon or not roon.is_connected():
        return []

    return await asyncio.to_thread(search_qobuz_tracks_sync, roon, query, limit)


def check_qobuz_available_sync(roon) -> bool:
    """Synchronous Qobuz availability check. Must be called from a thread."""
    try:
        with roon._browse_lock:
            root_items = _browse_root_items(roon)
            qobuz_item = _find_item_by_title(root_items, _QOBUZ_TITLE_HINTS)
            return qobuz_item is not None and bool(qobuz_item.get("item_key"))
    except Exception as exc:
        logger.debug("Qobuz availability check failed: %s", exc)
        return False


async def check_qobuz_available() -> bool:
    """Check if Qobuz is configured and accessible in Roon.

    Browses to root and checks whether a Qobuz service entry is visible.
    Returns False if Roon is not connected or Qobuz is not logged in.

    Result is cached for 60 seconds to avoid hammering the Browse API.
    """
    global _qobuz_available_cache

    # Return cached result if still fresh
    if _qobuz_available_cache is not None:
        cached_result, cached_at = _qobuz_available_cache
        if time.monotonic() - cached_at < _QOBUZ_CACHE_TTL:
            return cached_result

    from backend.roon_client import get_roon_client

    roon = get_roon_client()
    if not roon or not roon.is_connected():
        return False

    result = await asyncio.to_thread(check_qobuz_available_sync, roon)
    _qobuz_available_cache = (result, time.monotonic())
    return result
