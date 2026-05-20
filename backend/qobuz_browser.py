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
# hammer the Browse API on every poll.
# Positive results (True) are cached for 5 minutes — availability rarely changes.
# Negative results (False) are cached for only 30 seconds so that enabling
# Qobuz in Roon is detected quickly on the next status poll.
_qobuz_available_cache: tuple[bool, float] | None = None
_QOBUZ_CACHE_TTL_TRUE = 300.0   # 5 minutes when Qobuz IS available
_QOBUZ_CACHE_TTL_FALSE = 30.0   # 30 seconds when Qobuz is NOT available

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
    result = roon._api.browse_browse({"hierarchy": "browse", "pop_all": True})
    if not result:
        logger.warning("_browse_root_items: browse_browse returned None/empty")
        return []
    count = result.get("list", {}).get("count", 0)
    if count == 0:
        logger.warning("_browse_root_items: browse_browse list count is 0")
        return []
    root_page = roon._api.browse_load({"hierarchy": "browse", "count": count})
    items = root_page.get("items", []) if root_page else []
    logger.debug("_browse_root_items: loaded %d root items (count=%d)", len(items), count)
    return items


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

            # Step 2 — Navigate into Qobuz; capture list-level input_prompt flag.
            qobuz_nav = roon._api.browse_browse({
                "hierarchy": "browse",
                "item_key": qobuz_item["item_key"],
            })
            qobuz_list_info = qobuz_nav.get("list", {}) if qobuz_nav else {}
            qobuz_list_has_input = bool(qobuz_list_info.get("input_prompt"))

            qobuz_page = roon._api.browse_load({"hierarchy": "browse", "count": 100})
            qobuz_items = qobuz_page.get("items", []) if qobuz_page else []

            logger.debug(
                "Qobuz sub-items (list_has_input=%s): %s",
                qobuz_list_has_input,
                [(i.get("title"), i.get("hint")) for i in qobuz_items],
            )

            # Step 3 — Determine how to reach the search input.
            # Roon can expose search in two ways:
            #   A) The list returned after navigating into Qobuz already has input_prompt
            #      → send input directly without another item_key browse.
            #   B) One of the child items has hint="input_prompt" or a title matching search
            #      → navigate to that item first, then send input in a separate call.
            #
            # IMPORTANT: item_key and input must NEVER be combined in the same browse_browse
            # call — Roon ignores one of them silently, causing 0 results.

            # result_items is populated by whichever path successfully reaches search results.
            # None means no path has run yet; the global search fallback sets it when all
            # browse-hierarchy paths (A / B / C) fail to find a search entry point.
            result_items: list[dict[str, Any]] | None = None
            # Tracks which Roon Browse hierarchy owns the item_keys in result_items.
            # Must be used consistently for all subsequent browse calls (Step 5/6) so
            # that item_keys resolve correctly.  Set to "search" when the global Roon
            # search fallback fires; stays "browse" for the normal Qobuz hierarchy paths.
            used_hierarchy = "browse"

            if qobuz_list_has_input:
                # Path A — search prompt is at list level; send input directly.
                logger.debug("Qobuz search: using list-level input_prompt")
            else:
                # Path B — look for a Search child item and navigate to it first.
                search_item = next(
                    (i for i in qobuz_items if i.get("hint") == "input_prompt" and i.get("item_key")),
                    None,
                ) or _find_item_by_title(qobuz_items, _SEARCH_TITLE_HINTS)

                if not search_item or not search_item.get("item_key"):
                    # Path C — no search entry at the Qobuz root level; try navigating
                    # one level deeper into "My Qobuz" where the search prompt may live.
                    logger.debug(
                        "Path B: no search entry found in Qobuz root. Items: %s — trying Path C (My Qobuz)",
                        [(i.get("title"), i.get("hint")) for i in qobuz_items[:10]],
                    )
                    my_qobuz_item = _find_item_by_title(qobuz_items, {"my qobuz"})
                    if not my_qobuz_item or not my_qobuz_item.get("item_key"):
                        # No My Qobuz entry either — fall back to Roon global search.
                        logger.info(
                            "Qobuz browse has no search entry — falling back to global Roon search for '%s'",
                            query,
                        )
                        roon._api.browse_browse({
                            "hierarchy": "search",
                            "input": query,
                            "pop_all": True,
                        })
                        _fb = roon._api.browse_load({"hierarchy": "search", "count": 100})
                        result_items = _fb.get("items", []) if _fb else []
                        used_hierarchy = "search"
                    else:
                        logger.debug("Path C: navigating into '%s'", my_qobuz_item.get("title"))
                        # Navigate into My Qobuz — item_key only, NO input (Roon API rule).
                        my_nav = roon._api.browse_browse({
                            "hierarchy": "browse",
                            "item_key": my_qobuz_item["item_key"],
                        })
                        my_list = my_nav.get("list", {}) if my_nav else {}

                        if my_list.get("input_prompt"):
                            # My Qobuz has a list-level search prompt — browse session is
                            # now positioned here; Step 4 can submit the query directly.
                            logger.debug("Path C: 'My Qobuz' has list-level input_prompt — proceeding to search")
                        else:
                            # Load My Qobuz sub-items and look for a Search child entry.
                            my_page = roon._api.browse_load({"hierarchy": "browse", "count": 100})
                            my_items = my_page.get("items", []) if my_page else []
                            logger.debug(
                                "Path C: 'My Qobuz' sub-items (no list input_prompt): %s",
                                [(i.get("title"), i.get("hint")) for i in my_items[:10]],
                            )

                            deep_search = next(
                                (i for i in my_items if i.get("hint") == "input_prompt" and i.get("item_key")),
                                None,
                            ) or _find_item_by_title(my_items, _SEARCH_TITLE_HINTS)

                            if not deep_search or not deep_search.get("item_key"):
                                # No search entry inside My Qobuz either — fall back to global search.
                                logger.info(
                                    "Qobuz browse has no search entry — falling back to global Roon search for '%s'",
                                    query,
                                )
                                roon._api.browse_browse({
                                    "hierarchy": "search",
                                    "input": query,
                                    "pop_all": True,
                                })
                                _fb = roon._api.browse_load({"hierarchy": "search", "count": 100})
                                result_items = _fb.get("items", []) if _fb else []
                                used_hierarchy = "search"
                            else:
                                # Navigate to the search entry inside My Qobuz — separate call, no input yet.
                                logger.debug("Path C: navigating to search entry '%s' inside 'My Qobuz'", deep_search.get("title"))
                                deep_nav = roon._api.browse_browse({
                                    "hierarchy": "browse",
                                    "item_key": deep_search["item_key"],
                                })
                                deep_list = deep_nav.get("list", {}) if deep_nav else {}
                                if not deep_list.get("input_prompt"):
                                    logger.debug(
                                        "Path C: search entry '%s' did not return input_prompt — trying anyway",
                                        deep_search.get("title"),
                                    )
                else:
                    # Path B: navigate to the search entry — separate call, no input yet.
                    nav_result = roon._api.browse_browse({
                        "hierarchy": "browse",
                        "item_key": search_item["item_key"],
                    })
                    nav_list = nav_result.get("list", {}) if nav_result else {}
                    if not nav_list.get("input_prompt"):
                        logger.debug(
                            "Search entry '%s' did not return input_prompt — trying anyway",
                            search_item.get("title"),
                        )

            if result_items is None:
                # Step 4 — Submit the search query in its own browse_browse call (no item_key).
                # Only reached by Paths A / B / C when a search entry point was found above.
                search_result = roon._api.browse_browse({
                    "hierarchy": "browse",
                    "input": query,
                })
                count = search_result.get("list", {}).get("count", 0) if search_result else 0
                logger.debug("Qobuz search '%s': count=%d", query, count)

                results_page = roon._api.browse_load({
                    "hierarchy": "browse",
                    "count": min(max(count, limit * 3), 100),
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
                        "hierarchy": used_hierarchy,
                        "item_key": tracks_section["item_key"],
                    })
                    tracks_page = roon._api.browse_load({
                        "hierarchy": used_hierarchy,
                        "count": min(limit * 2, 100),
                    })
                    sub_items = tracks_page.get("items", []) if tracks_page else []
                    tracks = [
                        i for i in sub_items
                        if i.get("hint") in ("action", "action_list") and i.get("item_key")
                    ][:limit]

            # Step 6 — Convert to dicts
            # NOTE: item_keys from hierarchy:"search" (global search fallback) are
            # ephemeral session keys — they expire as soon as the search session
            # changes (e.g. by the next search call).  Replaying them minutes later
            # via play_tracks resolves to wrong/random content.
            #
            # When used_hierarchy == "search" we therefore encode the track metadata
            # in a synthetic key of the form:
            #
            #   qobuz_search::<url-encoded artist>::<url-encoded title>
            #
            # play_tracks detects this prefix and performs a FRESH Roon global search
            # at play time instead of browsing the stale key.
            import urllib.parse  # noqa: PLC0415 (local import, tiny perf cost)

            output = []
            for item in tracks:
                subtitle = item.get("subtitle") or ""
                parts = [p.strip() for p in subtitle.split("•")]
                artist = parts[0] if parts else ""
                album = parts[1] if len(parts) > 1 else ""
                title = item.get("title", "Unknown Track")

                if used_hierarchy == "search":
                    # Synthetic key — encodes artist+title for fresh-search playback.
                    item_key = (
                        "qobuz_search::"
                        + urllib.parse.quote(artist, safe="")
                        + "::"
                        + urllib.parse.quote(title, safe="")
                    )
                else:
                    item_key = item["item_key"]

                output.append({
                    "item_key": item_key,
                    "title": title,
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


async def search_qobuz_tracks(
    query: str,
    limit: int = 10,
    verify: bool = False,
    expected_artist: str = "",
    expected_title: str = "",
    expected_duration: int = 0,
) -> list[dict[str, Any]]:
    """Search Qobuz for tracks via Roon's Browse API.

    Navigates: Root → My Qobuz / Qobuz → Search → query

    Args:
        query:             Search string (e.g. "Miles Davis So What")
        limit:             Max results to return
        verify:            When True, run AcoustID verification on each result and
                           add ``match_confidence`` / ``version_flags`` fields.
                           Requires AcoustID to be configured; silently skipped when
                           it is not.  Errors never block results.
        expected_artist:   Original artist name (used for verification).
        expected_title:    Original track title (used for verification).
        expected_duration: Expected track duration in seconds (0 = unknown).

    Returns:
        List of dicts with item_key, title, artist, album, source="qobuz".
        When verify=True each dict also contains match_confidence (float 0-1),
        version_flags (list[str]), and match_reason (str).
        Empty list if Qobuz is not configured or search fails.
    """
    from backend.roon_client import get_roon_client

    roon = get_roon_client()
    if not roon or not roon.is_connected():
        return []

    results = await asyncio.to_thread(search_qobuz_tracks_sync, roon, query, limit)

    if not verify or not results:
        return results

    # Optional verification pass — fail-open
    try:
        from backend.acoustid_client import verify_match_sync  # noqa: PLC0415
        from backend.config import get_acoustid_config  # noqa: PLC0415

        acoustid_cfg = get_acoustid_config()
        if not acoustid_cfg["enabled"]:
            return results

        ea = expected_artist or query
        et = expected_title or query

        for track in results:
            try:
                verdict = verify_match_sync(
                    expected_artist=ea,
                    expected_title=et,
                    candidate_artist=track.get("artist", ""),
                    candidate_title=track.get("title", ""),
                    expected_duration=expected_duration,
                )
                track["match_confidence"] = verdict["confidence"]
                track["version_flags"] = verdict["version_flags"]
                track["match_reason"] = verdict["reason"]
                track["verified"] = verdict["match"]
            except Exception as exc:
                logger.debug("AcoustID per-track verify failed for '%s': %s", track.get("title"), exc)
                track["match_confidence"] = None
                track["version_flags"] = []
                track["match_reason"] = "Verification skipped"
                track["verified"] = None
    except Exception as exc:
        logger.warning("AcoustID verification pass failed: %s", exc)

    return results


def check_qobuz_available_sync(roon) -> bool:
    """Synchronous Qobuz availability check. Must be called from a thread.

    Strategy:
      1. Check top-level Browse root items for any item whose title contains
         "qobuz" (case-insensitive).
      2. If not found at root level, navigate one level deeper into items that
         look like service containers (title contains "service", "streaming",
         or "internet") and check their children.

    This two-level scan is necessary because Roon's Browse hierarchy varies
    across versions and configurations — Qobuz may appear at root or one level
    down depending on how the user has configured their Roon setup.
    """
    logger.info("check_qobuz_available_sync: starting check...")
    try:
        with roon._browse_lock:
            logger.info("check_qobuz_available_sync: lock acquired, loading root items")
            root_items = _browse_root_items(roon)

            logger.info(
                "check_qobuz_available_sync: root has %d items: %s",
                len(root_items),
                [i.get("title") for i in root_items],
            )

            # Step 1 — check top-level items
            qobuz_item = _find_item_by_title(root_items, _QOBUZ_TITLE_HINTS)
            if qobuz_item and qobuz_item.get("item_key"):
                logger.info(
                    "check_qobuz_available_sync: Qobuz FOUND at Browse root: '%s'",
                    qobuz_item.get("title"),
                )
                return True
            logger.info(
                "check_qobuz_available_sync: Qobuz NOT found at root level, checking sub-containers"
            )

            # Step 2 — look one level deeper in service-like containers
            service_keywords = {"service", "streaming", "internet"}
            for item in root_items:
                title_lower = (item.get("title") or "").lower()
                if not any(kw in title_lower for kw in service_keywords):
                    continue
                item_key = item.get("item_key")
                if not item_key:
                    continue

                roon._api.browse_browse({
                    "hierarchy": "browse",
                    "item_key": item_key,
                })
                sub_page = roon._api.browse_load({"hierarchy": "browse", "count": 100})
                sub_items = sub_page.get("items", []) if sub_page else []

                sub_qobuz = _find_item_by_title(sub_items, _QOBUZ_TITLE_HINTS)
                if sub_qobuz and sub_qobuz.get("item_key"):
                    logger.info(
                        "check_qobuz_available_sync: Qobuz FOUND under '%s': '%s'",
                        item.get("title"),
                        sub_qobuz.get("title"),
                    )
                    return True

            logger.info(
                "check_qobuz_available_sync: Qobuz NOT found in Browse hierarchy "
                "(root + 1 level deep). Returning False."
            )
            return False

    except Exception as exc:
        logger.warning("check_qobuz_available_sync: exception: %s", exc, exc_info=True)
        return False


async def check_qobuz_available() -> bool:
    """Check if Qobuz is configured and accessible in Roon.

    Browses to root and checks whether a Qobuz service entry is visible.
    Returns False if Roon is not connected or Qobuz is not logged in.

    Positive results are cached for 5 minutes; negative results are cached
    for only 30 seconds so that newly enabled Qobuz is detected quickly.
    """
    global _qobuz_available_cache

    # Return cached result if still fresh — use different TTL for True vs False
    if _qobuz_available_cache is not None:
        cached_result, cached_at = _qobuz_available_cache
        ttl = _QOBUZ_CACHE_TTL_TRUE if cached_result else _QOBUZ_CACHE_TTL_FALSE
        age = time.monotonic() - cached_at
        if age < ttl:
            logger.debug(
                "check_qobuz_available: cache hit (result=%s, age=%.1fs, ttl=%.1fs)",
                cached_result, age, ttl,
            )
            return cached_result
        logger.debug(
            "check_qobuz_available: cache expired (result=%s, age=%.1fs)", cached_result, age
        )

    from backend.roon_client import get_roon_client

    roon = get_roon_client()
    if not roon or not roon.is_connected():
        logger.info("check_qobuz_available: Roon not connected — returning False (no cache)")
        return False

    logger.info("check_qobuz_available: running synchronous check via asyncio.to_thread")
    result = await asyncio.to_thread(check_qobuz_available_sync, roon)
    _qobuz_available_cache = (result, time.monotonic())
    logger.info("check_qobuz_available: result=%s — cached", result)
    return result
