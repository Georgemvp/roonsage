"""Library cache — thin re-export layer.

All implementation has been moved to focused modules:
  backend.db      — connection, schema, get_connection() context manager
  backend.sync    — sync_library() and sync-state helpers
  backend.tracks  — track queries and filtering
  backend.results — results persistence (playlists and recommendations)

Existing callers that import from ``backend.library_cache`` (or use
``library_cache.X`` attribute access) continue to work unchanged.
"""

from backend.db import (  # noqa: F401
    DATA_DIR,
    DB_PATH,
    ensure_db_initialized,
    get_connection,
    get_db_connection,
    needs_resync,
)
from backend.results import (  # noqa: F401
    delete_result,
    get_result,
    list_results,
    save_result,
)
from backend.sync import (  # noqa: F401
    check_server_changed,
    clear_cache,
    get_sync_progress,
    get_sync_state,
    is_cache_stale,
    sync_library,
)
# Compatibility alias: tests reference this private name via library_cache._is_live_version
from backend.sync import _is_live as _is_live_version  # noqa: F401
from backend.tracks import (  # noqa: F401
    count_tracks_by_filters,
    get_album_candidates,
    get_album_familiarity,
    get_albums_by_artist,
    get_cached_genre_decade_stats,
    get_cached_tracks,
    get_enriched_tags_for_keys,
    get_tracks_by_filters,
    get_tracks_by_item_keys,
    has_cached_tracks,
    search_cached_tracks,
)
