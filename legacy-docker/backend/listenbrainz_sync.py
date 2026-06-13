"""ListenBrainz stats synchronisation service for RoonSage.

Pulls statistics from the ListenBrainz API and caches them in the
lb_stats_cache SQLite table. Cache TTL is 6 hours.

Usage::

    from backend.listenbrainz_sync import init_sync_instance, get_sync_instance

    # Called from main.py lifespan with an initialised ListenBrainzClient:
    init_sync_instance(lb_client)

    # Called later from routes or taste_profile.py:
    sync = get_sync_instance()
    if sync:
        await sync.sync_all()
        data = sync.get_cached_stat("top_artists")
"""

import json
import logging
from datetime import datetime, timedelta
from typing import Any

logger = logging.getLogger(__name__)

# Stat type definitions: (stat_type, method_name, kwargs)
_STAT_DEFS: list[tuple[str, str, dict]] = [
    ("top_artists",      "get_top_artists",      {"range": "all_time", "count": 50}),
    ("top_recordings",   "get_top_recordings",   {"range": "all_time", "count": 50}),
    ("top_releases",     "get_top_releases",     {"range": "all_time", "count": 50}),
    ("genre_activity",   "get_genre_activity",   {}),
    ("daily_activity",   "get_daily_activity",   {"range": "all_time"}),
    ("era_activity",     "get_era_activity",     {"range": "all_time"}),
    ("artist_map",       "get_artist_map",       {"range": "all_time"}),
    ("similar_users",    "get_similar_users",    {}),
    ("listening_activity", "get_listening_activity", {"range": "all_time"}),
]

_FEEDBACK_DEFS: list[tuple[str, int]] = [
    ("feedback_loved", 1),
    ("feedback_hated", -1),
]


class ListenBrainzSync:
    """Pull LB stats and cache them in lb_stats_cache (SQLite)."""

    CACHE_TTL_HOURS = 6

    def __init__(self, lb_client) -> None:
        self._lb = lb_client

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def sync_all(self, force: bool = False) -> dict:
        """Pull all configured LB stats and cache them.

        Args:
            force: When True, bypass the cache TTL and always re-fetch every stat.
                   Use this for manual "Sync now" actions so stale/corrupt cache data
                   is always overwritten.

        Returns:
            Summary dict: {stat_type: "synced" | "cached" | "failed"}
        """
        summary: dict[str, str] = {}

        for stat_type, method_name, kwargs in _STAT_DEFS:
            if force or self.is_stale(stat_type):
                ok = await self.sync_stat(stat_type, method_name, kwargs)
                summary[stat_type] = "synced" if ok else "failed"
            else:
                summary[stat_type] = "cached"

        for stat_type, score in _FEEDBACK_DEFS:
            if force or self.is_stale(stat_type):
                try:
                    data = await self._lb.get_user_feedback(score=score)
                    self._write_cache(stat_type, data or [])
                    summary[stat_type] = "synced"
                except Exception as exc:
                    logger.warning("LB feedback sync failed (%s): %s", stat_type, exc)
                    summary[stat_type] = "failed"
            else:
                summary[stat_type] = "cached"

        logger.info("ListenBrainz sync_all complete: %s", summary)

        # Fire-and-forget notification
        try:
            from backend.notifications import EventType, event_bus  # noqa: PLC0415
            synced = [k for k, v in summary.items() if v == "synced"]
            await event_bus.emit_async(
                EventType.LISTENBRAINZ_SYNC_COMPLETE,
                {"synced_stats": synced, "summary": summary},
            )
        except Exception:
            pass

        # Automation: fire LB_SYNCED event
        try:
            from backend.automation_engine import TriggerType, get_engine  # noqa: PLC0415
            _eng = get_engine()
            if _eng:
                await _eng.on_event_async(TriggerType.LB_SYNCED, {})
        except Exception:
            pass

        return summary

    async def sync_stat(
        self, stat_type: str, method_name: str | None = None, kwargs: dict | None = None
    ) -> bool:
        """Sync a single stat type.  Returns True on success."""
        if method_name is None:
            # Look up method from _STAT_DEFS
            for _st, _mn, _kw in _STAT_DEFS:
                if _st == stat_type:
                    method_name = _mn
                    kwargs = _kw
                    break

        if method_name is None:
            logger.warning("Unknown stat_type: %s", stat_type)
            return False

        try:
            method = getattr(self._lb, method_name)
            data = await method(**(kwargs or {}))
            if data is not None:
                # Log what we actually received for debugging
                if isinstance(data, list):
                    logger.info("LB sync %s: received %d items", stat_type, len(data))
                elif isinstance(data, dict):
                    logger.info(
                        "LB sync %s: received dict with keys %s",
                        stat_type,
                        list(data.keys())[:5],
                    )
                else:
                    logger.info("LB sync %s: received %s", stat_type, type(data).__name__)
                self._write_cache(stat_type, data)
                return True
            else:
                logger.warning(
                    "LB sync %s: received None (API call returned nothing)", stat_type
                )
        except Exception as exc:
            logger.warning("LB sync_stat %s failed: %s", stat_type, exc)
        return False

    def get_cached_stat(self, stat_type: str) -> Any:
        """Return the cached stat data from SQLite (synchronous).

        Returns None when no cache entry exists.
        """
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                row = conn.execute(
                    "SELECT data_json FROM lb_stats_cache WHERE stat_type = ?",
                    (stat_type,),
                ).fetchone()
                if row and row[0]:
                    return json.loads(row[0])
            finally:
                conn.close()
        except Exception as exc:
            logger.warning("get_cached_stat(%s) failed: %s", stat_type, exc)
        return None

    def is_stale(self, stat_type: str) -> bool:
        """Return True when the cache is missing or older than TTL."""
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                row = conn.execute(
                    "SELECT synced_at FROM lb_stats_cache WHERE stat_type = ?",
                    (stat_type,),
                ).fetchone()
                if not row:
                    return True
                synced_at = datetime.fromisoformat(row[0])
                return datetime.utcnow() - synced_at > timedelta(hours=self.CACHE_TTL_HOURS)
            finally:
                conn.close()
        except Exception:
            return True

    def get_last_sync_time(self) -> str | None:
        """Return the most recent synced_at timestamp across all stat types."""
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                row = conn.execute(
                    "SELECT MAX(synced_at) FROM lb_stats_cache"
                ).fetchone()
                return row[0] if row else None
            finally:
                conn.close()
        except Exception:
            return None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _write_cache(self, stat_type: str, data: Any) -> None:
        """Upsert a stat into lb_stats_cache."""
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                conn.execute(
                    """
                    INSERT INTO lb_stats_cache (stat_type, data_json, synced_at)
                    VALUES (?, ?, datetime('now'))
                    ON CONFLICT(stat_type) DO UPDATE SET
                        data_json = excluded.data_json,
                        synced_at = excluded.synced_at
                    """,
                    (stat_type, json.dumps(data, ensure_ascii=False)),
                )
                conn.commit()
                logger.debug("LB cache written: %s", stat_type)
            finally:
                conn.close()
        except Exception as exc:
            logger.warning("_write_cache(%s) failed: %s", stat_type, exc)


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_sync_instance: ListenBrainzSync | None = None


def get_sync_instance() -> ListenBrainzSync | None:
    """Return the module-level sync instance, or None if not initialised."""
    return _sync_instance


def init_sync_instance(lb_client) -> ListenBrainzSync:
    """Initialise the module-level sync instance. Called from main.py lifespan."""
    global _sync_instance
    _sync_instance = ListenBrainzSync(lb_client)
    return _sync_instance
