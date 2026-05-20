"""Last.fm stats synchronisation service for RoonSage.

Pulls statistics from the Last.fm API and caches them in the
lastfm_stats_cache SQLite table.  Cache TTL is 6 hours.

Usage::

    from backend.lastfm_sync import init_lf_sync_instance, get_lf_sync_instance

    # Called from main.py lifespan with an initialised LastFmClient:
    init_lf_sync_instance(lf_client)

    # Called later from routes or taste_profile.py:
    sync = get_lf_sync_instance()
    if sync:
        await sync.sync_all()
        data = sync.get_cached_stat("top_artists")
"""

import asyncio
import json
import logging
from datetime import datetime, timedelta
from typing import Any

logger = logging.getLogger(__name__)

# Stat type definitions: (stat_type, method_name, kwargs)
# For each top-artist we also fetch similar_artists + tags — handled separately
# in sync_all() because they require per-artist loops.
_STAT_DEFS: list[tuple[str, str, dict]] = [
    ("top_artists", "get_user_top_artists", {"period": "3month", "limit": 50}),
    ("top_tracks",  "get_user_top_tracks",  {"period": "3month", "limit": 50}),
    # "similar_artists" and "artist_tags" are composite — built in sync_all()
]


class LastFmSync:
    """Pull Last.fm stats and cache them in lastfm_stats_cache (SQLite)."""

    CACHE_TTL_HOURS = 6

    # Maximum number of top artists to enrich with similar/tags calls.
    # Each artist requires 2 HTTP calls; keep low to avoid hammering the API.
    MAX_ENRICH_ARTISTS = 10
    # Seconds between enrichment calls (Last.fm rate limit: ~5 req/s)
    ENRICH_DELAY = 0.25

    def __init__(self, lf_client) -> None:
        self._lf = lf_client

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def sync_all(self, force: bool = False) -> dict:
        """Pull all configured Last.fm stats and cache them.

        Args:
            force: When True, bypass the cache TTL and always re-fetch.

        Returns:
            Summary dict: {stat_type: "synced" | "cached" | "failed"}
        """
        summary: dict[str, str] = {}

        # ── Simple stats (top_artists, top_tracks) ─────────────────────────
        for stat_type, method_name, kwargs in _STAT_DEFS:
            if force or self.is_stale(stat_type):
                ok = await self._sync_stat(stat_type, method_name, kwargs)
                summary[stat_type] = "synced" if ok else "failed"
            else:
                summary[stat_type] = "cached"

        # ── Composite: similar_artists + artist_tags ────────────────────────
        # Build these from top_artists (cached or just-synced)
        if force or self.is_stale("similar_artists") or self.is_stale("artist_tags"):
            ok = await self._sync_enrichment()
            summary["similar_artists"] = "synced" if ok else "failed"
            summary["artist_tags"]     = "synced" if ok else "failed"
        else:
            summary["similar_artists"] = "cached"
            summary["artist_tags"]     = "cached"

        logger.info("Last.fm sync_all complete: %s", summary)
        return summary

    async def _sync_stat(
        self, stat_type: str, method_name: str, kwargs: dict
    ) -> bool:
        """Sync a single stat type.  Returns True on success."""
        try:
            method = getattr(self._lf, method_name)
            data = await method(**kwargs)
            if data is not None:
                logger.info(
                    "Last.fm sync %s: received %d items",
                    stat_type,
                    len(data) if isinstance(data, list) else 1,
                )
                self._write_cache(stat_type, data)
                return True
            logger.warning("Last.fm sync %s: received None", stat_type)
        except Exception as exc:
            logger.warning("Last.fm _sync_stat %s failed: %s", stat_type, exc)
        return False

    async def _sync_enrichment(self) -> bool:
        """Fetch similar artists + tags for each top artist and cache them."""
        try:
            top_artists: list[dict] = self.get_cached_stat("top_artists") or []
            if not top_artists:
                # Try fetching fresh
                top_artists = await self._lf.get_user_top_artists(
                    period="3month", limit=50
                ) or []

            artists_to_enrich = [a["name"] for a in top_artists if a.get("name")][
                : self.MAX_ENRICH_ARTISTS
            ]

            similar_map: dict[str, list] = {}
            tags_map: dict[str, list] = {}

            for artist in artists_to_enrich:
                try:
                    similar = await self._lf.get_similar_artists(artist, limit=10)
                    if similar:
                        similar_map[artist] = similar
                except Exception as exc:
                    logger.debug("Last.fm similar_artists(%s) failed: %s", artist, exc)

                await asyncio.sleep(self.ENRICH_DELAY)

                try:
                    tags = await self._lf.get_artist_tags(artist)
                    if tags:
                        tags_map[artist] = tags
                except Exception as exc:
                    logger.debug("Last.fm artist_tags(%s) failed: %s", artist, exc)

                await asyncio.sleep(self.ENRICH_DELAY)

            self._write_cache("similar_artists", similar_map)
            self._write_cache("artist_tags", tags_map)
            logger.info(
                "Last.fm enrichment done: %d similar_artists, %d artist_tags",
                len(similar_map),
                len(tags_map),
            )
            return True
        except Exception as exc:
            logger.warning("Last.fm _sync_enrichment failed: %s", exc)
            return False

    def get_cached_stat(self, stat_type: str) -> Any:
        """Return cached stat data from SQLite (synchronous).

        Returns None when no cache entry exists.
        """
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                row = conn.execute(
                    "SELECT data_json FROM lastfm_stats_cache WHERE stat_type = ?",
                    (stat_type,),
                ).fetchone()
                if row and row[0]:
                    return json.loads(row[0])
            finally:
                conn.close()
        except Exception as exc:
            logger.warning("Last.fm get_cached_stat(%s) failed: %s", stat_type, exc)
        return None

    def is_stale(self, stat_type: str) -> bool:
        """Return True when the cache is missing or older than TTL."""
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                row = conn.execute(
                    "SELECT synced_at FROM lastfm_stats_cache WHERE stat_type = ?",
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
                    "SELECT MAX(synced_at) FROM lastfm_stats_cache"
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
        """Upsert a stat into lastfm_stats_cache."""
        try:
            from backend.db import get_db_connection  # noqa: PLC0415
            conn = get_db_connection()
            try:
                conn.execute(
                    """
                    INSERT INTO lastfm_stats_cache (stat_type, data_json, synced_at)
                    VALUES (?, ?, datetime('now'))
                    ON CONFLICT(stat_type) DO UPDATE SET
                        data_json = excluded.data_json,
                        synced_at = excluded.synced_at
                    """,
                    (stat_type, json.dumps(data, ensure_ascii=False)),
                )
                conn.commit()
                logger.debug("Last.fm cache written: %s", stat_type)
            finally:
                conn.close()
        except Exception as exc:
            logger.warning("Last.fm _write_cache(%s) failed: %s", stat_type, exc)


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_lf_sync_instance: LastFmSync | None = None


def get_lf_sync_instance() -> LastFmSync | None:
    """Return the module-level sync instance, or None if not initialised."""
    return _lf_sync_instance


def init_lf_sync_instance(lf_client) -> LastFmSync:
    """Initialise the module-level sync instance. Called from main.py lifespan."""
    global _lf_sync_instance
    _lf_sync_instance = LastFmSync(lf_client)
    return _lf_sync_instance
