"""Automation Engine for RoonSage — trigger-action pairs that run workflows automatically.

Supported trigger types:
  - schedule        : cron expression (checked every 60 s)
  - track_played    : fired when any track finishes playing
  - zone_started    : fired when a zone starts playing
  - library_synced  : fired after a library sync completes
  - lb_synced       : fired after a ListenBrainz sync completes
  - watchlist_match : fired when a new release is found for a watched artist

Supported action types:
  - generate_playlist    : prompt + filters + zone
  - play_template        : template_id + zone
  - sync_library         : trigger a library re-sync
  - sync_listenbrainz    : trigger a ListenBrainz sync
  - scan_watchlist       : scan watchlist for new releases
  - send_notification    : emit an event_bus notification
  - run_maintenance      : clean up old DB records
  - volume_set           : set volume on a zone
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import time
from datetime import UTC, datetime
from enum import StrEnum

from backend.db import get_connection
from backend.scheduler import matches_cron  # reuse existing cron parser

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------


class TriggerType(StrEnum):
    SCHEDULE = "schedule"
    TRACK_PLAYED = "track_played"
    ZONE_STARTED = "zone_started"
    LIBRARY_SYNCED = "library_synced"
    LB_SYNCED = "lb_synced"
    WATCHLIST_MATCH = "watchlist_match"
    CLUSTERING_COMPLETE = "clustering_complete"


class ActionType(StrEnum):
    GENERATE_PLAYLIST = "generate_playlist"
    PLAY_TEMPLATE = "play_template"
    SYNC_LIBRARY = "sync_library"
    SYNC_LISTENBRAINZ = "sync_listenbrainz"
    SCAN_WATCHLIST = "scan_watchlist"
    SEND_NOTIFICATION = "send_notification"
    RUN_MAINTENANCE = "run_maintenance"
    VOLUME_SET = "volume_set"
    BUILD_DJ_SET_QOBUZ = "build_dj_set_qobuz"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _row_to_dict(row) -> dict:
    d = dict(row)
    for key in ("trigger_config", "action_config"):
        if isinstance(d.get(key), str):
            try:
                d[key] = json.loads(d[key])
            except Exception:
                d[key] = {}
    return d


# ---------------------------------------------------------------------------
# Action executors
# ---------------------------------------------------------------------------


async def _exec_generate_playlist(config: dict) -> str:
    """Generate a playlist from a prompt and optionally queue it in a zone."""
    prompt = config.get("prompt", "Relaxing background music")
    track_count = int(config.get("track_count", 20))
    zone_name: str | None = config.get("zone_name") or config.get("zone")
    genres: list[str] | None = config.get("genres") or None
    decades: list[str] | None = config.get("decades") or None
    exclude_live: bool = config.get("exclude_live", True)
    source_mode: str = config.get("source_mode", "library")

    from backend.generator import generate_playlist_stream  # noqa: PLC0415

    result_data: dict = {}

    def _generate() -> None:
        nonlocal result_data
        for chunk in generate_playlist_stream(
            prompt=prompt,
            genres=genres,
            decades=decades,
            track_count=track_count,
            exclude_live=exclude_live,
            source_mode=source_mode,
        ):
            for line in chunk.splitlines():
                if line.startswith("data:"):
                    try:
                        payload = json.loads(line[5:].strip())
                        if isinstance(payload, dict) and "tracks" in payload:
                            result_data = payload
                    except Exception:
                        pass

    await asyncio.to_thread(_generate)

    if not result_data or not result_data.get("tracks"):
        raise RuntimeError("Playlist generation produced no tracks")

    generated_tracks = result_data["tracks"]
    title = result_data.get("title") or prompt[:40]
    logger.info("Automation generated %d tracks (title=%r)", len(generated_tracks), title)

    if zone_name and generated_tracks:
        from backend.roon_client import get_roon_client  # noqa: PLC0415
        roon = get_roon_client()
        if roon and roon.is_connected():
            zones = roon.get_zones()
            zone_id: str | None = None
            for z in zones:
                if zone_name.lower() in z.get("display_name", "").lower():
                    zone_id = z.get("zone_id")
                    break
            if zone_id:
                item_keys = [t.get("item_key", "") for t in generated_tracks if t.get("item_key")]
                if item_keys:
                    await asyncio.to_thread(roon.queue_tracks, zone_id, item_keys, replace_queue=True)
                    logger.info("Automation: queued %d tracks to zone %r", len(item_keys), zone_name)
            else:
                logger.warning("Automation: zone %r not found", zone_name)

    return f"Generated {len(generated_tracks)} tracks — {title}"


async def _exec_play_template(config: dict) -> str:
    """Play a saved template in a zone."""
    template_id = config.get("template_id")
    zone_name = config.get("zone_name") or config.get("zone", "")
    if not template_id:
        raise ValueError("play_template action requires template_id")

    from backend.templates import get_template  # noqa: PLC0415
    template = get_template(int(template_id))
    if not template:
        raise ValueError(f"Template {template_id} not found")

    # Delegate to generate_playlist with the template's prompt/filters
    return await _exec_generate_playlist({
        "prompt": template.get("prompt", ""),
        "track_count": template.get("track_count", 25),
        "zone_name": zone_name,
        "genres": template.get("genres"),
        "decades": template.get("decades"),
        "exclude_live": template.get("exclude_live", True),
    })


async def _exec_sync_library(_config: dict) -> str:
    from backend import library_cache  # noqa: PLC0415
    from backend.roon_client import get_roon_client  # noqa: PLC0415
    roon = get_roon_client()
    if not roon or not roon.is_connected():
        raise RuntimeError("Roon not connected — cannot sync library")
    await asyncio.to_thread(library_cache.sync_library, roon)
    return "Library sync completed"


async def _exec_sync_listenbrainz(_config: dict) -> str:
    from backend.listenbrainz_sync import get_sync_instance  # noqa: PLC0415
    sync = get_sync_instance()
    if not sync:
        raise RuntimeError("ListenBrainz not configured")
    result = await sync.sync_all(force=True)
    synced_count = len(result.get("synced", []))
    return f"ListenBrainz sync completed ({synced_count} stat types)"


async def _exec_scan_watchlist(_config: dict) -> str:
    from backend.watchlist import scan_all_watched  # noqa: PLC0415
    new_releases = await scan_all_watched()
    return f"Watchlist scan done — {len(new_releases)} new release(s)"


async def _exec_send_notification(config: dict) -> str:
    channel = config.get("channel", "all")
    message = config.get("message", "RoonSage automation triggered")
    event_type = config.get("event_type", "automation")

    from backend.notifications import event_bus  # noqa: PLC0415
    await event_bus.emit(event_type, {"message": message, "channel": channel})
    return f"Notification sent: {message[:60]}"


async def _exec_run_maintenance(_config: dict) -> str:
    """Delete old automation log entries and old listening history entries."""
    cutoff_days = 30
    with get_connection() as conn:
        deleted_log = conn.execute(
            "DELETE FROM automation_log WHERE triggered_at < datetime('now', ?)",
            (f"-{cutoff_days} days",),
        ).rowcount
        deleted_history = conn.execute(
            "DELETE FROM listening_history WHERE timestamp < datetime('now', ?)",
            (f"-{cutoff_days * 3} days",),
        ).rowcount
        conn.commit()
    return f"Maintenance: removed {deleted_log} log entries, {deleted_history} history entries"


async def _exec_volume_set(config: dict) -> str:
    zone_name = config.get("zone_name") or config.get("zone", "")
    level = config.get("level")
    if level is None:
        raise ValueError("volume_set action requires level")

    from backend.roon_client import get_roon_client  # noqa: PLC0415
    roon = get_roon_client()
    if not roon or not roon.is_connected():
        raise RuntimeError("Roon not connected")

    zones = roon.get_zones()
    zone_id: str | None = None
    for z in zones:
        if zone_name.lower() in z.get("display_name", "").lower():
            zone_id = z.get("zone_id")
            break
    if not zone_id:
        raise ValueError(f"Zone {zone_name!r} not found")

    await asyncio.to_thread(roon.set_volume, zone_id, int(level))
    return f"Volume set to {level} on zone {zone_name!r}"


async def _exec_build_dj_set_qobuz(config: dict) -> str:
    """Build a DJ set from a template and (re)fill a Qobuz playlist.

    Config:
      - dj_template_id (str, required)
      - qobuz_playlist_id (str, optional — persisted back after first run)
      - qobuz_playlist_name (str, optional — used when creating a new playlist)
      - zone_name (str, optional — also queue to a Roon zone)
      - automation_id (injected by _execute, used to persist new playlist_id)
    """
    template_id = config.get("dj_template_id")
    if not template_id:
        raise ValueError("build_dj_set_qobuz action requires dj_template_id")

    from backend.dj_templates import get_dj_template  # noqa: PLC0415

    template = get_dj_template(template_id)
    if not template:
        raise ValueError(f"DJ template '{template_id}' not found")

    from backend.audio_features.dj_generator import build_dj_set as _build_set  # noqa: PLC0415

    result = await asyncio.to_thread(
        _build_set,
        duration_minutes=template.duration_minutes,
        track_count=template.track_count,
        start_bpm=template.start_bpm,
        end_bpm=template.end_bpm,
        energy_curve=template.energy_curve,
        genres=template.genres or None,
        decades=template.decades or None,
        exclude_live=template.exclude_live,
        start_mood=template.start_mood,
        end_mood=template.end_mood,
    )
    tracks = result.get("tracks") or []
    if not tracks:
        raise RuntimeError(
            f"DJ set builder returned no tracks for template '{template_id}' "
            "(check AUDIO_FEATURES_ENABLED + matching pool)"
        )

    playlist_id = (config.get("qobuz_playlist_id") or "").strip() or None
    playlist_name = config.get("qobuz_playlist_name") or template.name

    from backend.qobuz_api import get_qobuz_api_client  # noqa: PLC0415

    qobuz = get_qobuz_api_client()
    if not qobuz or not qobuz.is_authenticated():
        raise RuntimeError("Qobuz not configured — cannot update Qobuz playlist")

    track_dicts = [
        {"artist": t.get("artist", ""), "title": t.get("title", "")}
        for t in tracks
    ]
    resolved = await asyncio.to_thread(qobuz.resolve_tracks, track_dicts)
    matched_ids = [str(m["qobuz_id"]) for m in resolved.get("matched", [])]
    if not matched_ids:
        raise RuntimeError(
            f"None of the {len(tracks)} DJ-set tracks matched on Qobuz"
        )

    if playlist_id:
        # Overwrite existing: clear playlist_track_ids, then refill with global ids
        try:
            pl = await asyncio.to_thread(qobuz.get_playlist, playlist_id)
            existing_pt_ids = [
                str(t["playlist_track_id"])
                for t in (pl.get("tracks", {}).get("items") or [])
                if t.get("playlist_track_id")
            ]
            if existing_pt_ids:
                await asyncio.to_thread(
                    qobuz.remove_tracks_from_playlist, playlist_id, existing_pt_ids
                )
        except Exception as exc:
            logger.warning("Could not clear Qobuz playlist %s: %s", playlist_id, exc)

        await asyncio.to_thread(
            qobuz.add_tracks_to_playlist_by_id, playlist_id, matched_ids
        )
        action_result = (
            f"Updated Qobuz playlist {playlist_id} with {len(matched_ids)}/{len(tracks)} tracks"
        )
    else:
        # First run — create new playlist and persist the ID back to action_config
        save_result = await asyncio.to_thread(
            qobuz.save_playlist,
            name=playlist_name,
            tracks=track_dicts,
            description=f"Auto-generated by RoonSage from DJ template '{template.name}'",
            is_public=False,
        )
        new_id = save_result.get("playlist_id") or save_result.get("id")
        if not new_id:
            raise RuntimeError(f"Qobuz save_playlist returned no playlist_id: {save_result}")

        automation_id = config.get("automation_id")
        if automation_id:
            with get_connection() as conn:
                row = conn.execute(
                    "SELECT action_config FROM automations WHERE id=?",
                    (automation_id,),
                ).fetchone()
                if row:
                    try:
                        cfg_db = json.loads(row["action_config"] or "{}")
                    except Exception:
                        cfg_db = {}
                    cfg_db["qobuz_playlist_id"] = str(new_id)
                    conn.execute(
                        "UPDATE automations SET action_config=? WHERE id=?",
                        (json.dumps(cfg_db), automation_id),
                    )
                    conn.commit()
        action_result = (
            f"Created Qobuz playlist '{playlist_name}' (id={new_id}) "
            f"with {len(matched_ids)}/{len(tracks)} tracks"
        )

    zone_name = (config.get("zone_name") or "").strip()
    if zone_name:
        from backend.roon_client import get_roon_client  # noqa: PLC0415

        roon = get_roon_client()
        if roon and roon.is_connected():
            zones = roon.get_zones()
            zone_id: str | None = None
            zn = zone_name.lower()
            for z in zones:
                if zn in z.get("display_name", "").lower():
                    zone_id = z.get("zone_id")
                    break
            if zone_id:
                item_keys = [t.get("item_key", "") for t in tracks if t.get("item_key")]
                if item_keys:
                    await asyncio.to_thread(
                        roon.queue_tracks, zone_id, item_keys, replace_queue=True
                    )
                    action_result += f" — queued to zone {zone_name!r}"

    return action_result


_ACTION_EXECUTORS = {
    ActionType.GENERATE_PLAYLIST: _exec_generate_playlist,
    ActionType.PLAY_TEMPLATE: _exec_play_template,
    ActionType.SYNC_LIBRARY: _exec_sync_library,
    ActionType.SYNC_LISTENBRAINZ: _exec_sync_listenbrainz,
    ActionType.SCAN_WATCHLIST: _exec_scan_watchlist,
    ActionType.SEND_NOTIFICATION: _exec_send_notification,
    ActionType.RUN_MAINTENANCE: _exec_run_maintenance,
    ActionType.VOLUME_SET: _exec_volume_set,
    ActionType.BUILD_DJ_SET_QOBUZ: _exec_build_dj_set_qobuz,
}


# ---------------------------------------------------------------------------
# AutomationEngine
# ---------------------------------------------------------------------------


class AutomationEngine:
    """Manages trigger-action automations with schedule checking and event dispatch."""

    _SCHEDULE_INTERVAL = 60   # seconds between cron checks
    _SCHEDULE_SKIP_WINDOW = 55  # double-run guard (seconds)

    def __init__(self) -> None:
        self._task: asyncio.Task | None = None  # type: ignore[type-arg]
        self._running = False

    # ------------------------------------------------------------------ #
    # Lifecycle
    # ------------------------------------------------------------------ #

    def start(self) -> None:
        """Start the background scheduling loop."""
        if self._running:
            return
        self._running = True
        self._task = asyncio.create_task(self._loop(), name="automation-engine")
        logger.info("AutomationEngine started (schedule check every %ds)", self._SCHEDULE_INTERVAL)

    def stop(self) -> None:
        """Stop the background loop gracefully."""
        self._running = False
        if self._task and not self._task.done():
            self._task.cancel()
        logger.info("AutomationEngine stopped")

    # ------------------------------------------------------------------ #
    # Schedule loop
    # ------------------------------------------------------------------ #

    async def _loop(self) -> None:
        # Initial offset so scheduler and automation_engine don't fire simultaneously
        await asyncio.sleep(30 + random.uniform(0, 10))
        while self._running:
            try:
                await self._check_schedules()
            except asyncio.CancelledError:
                break
            except Exception as exc:
                logger.error("AutomationEngine loop error: %s", exc, exc_info=True)
            await asyncio.sleep(self._SCHEDULE_INTERVAL + random.uniform(-9, 9))

    async def _check_schedules(self) -> None:
        now = datetime.now()
        with get_connection() as conn:
            rows = conn.execute(
                "SELECT * FROM automations WHERE enabled=1 AND trigger_type=?",
                (TriggerType.SCHEDULE.value,),
            ).fetchall()

        for row in rows:
            automation = _row_to_dict(row)
            cron_expr = automation["trigger_config"].get("cron", "")
            if not cron_expr:
                continue
            if not matches_cron(cron_expr, now):
                continue
            # Double-run guard
            last = automation.get("last_triggered")
            if last:
                try:
                    last_dt = datetime.fromisoformat(last.replace("Z", "+00:00")).replace(tzinfo=None)
                    if (now - last_dt).total_seconds() < self._SCHEDULE_SKIP_WINDOW:
                        continue
                except Exception:
                    pass
            logger.info(
                "Automation id=%d (%r) schedule triggered at %s",
                automation["id"], automation["name"], now.strftime("%H:%M"),
            )
            asyncio.create_task(
                self._execute(automation, {"trigger": "schedule", "time": now.isoformat()}),
                name=f"automation-{automation['id']}",
            )

    # ------------------------------------------------------------------ #
    # Event dispatch (called by external modules)
    # ------------------------------------------------------------------ #

    def on_event(self, trigger_type: str | TriggerType, data: dict | None = None) -> None:
        """Non-blocking entry point for event-driven triggers.

        Call from synchronous contexts (e.g. roon_intelligence.py).
        """
        trigger = TriggerType(trigger_type) if isinstance(trigger_type, str) else trigger_type
        if not self._running:
            return
        loop = asyncio.get_event_loop()
        if loop and loop.is_running():
            asyncio.run_coroutine_threadsafe(
                self._dispatch_event(trigger, data or {}), loop
            )
        else:
            logger.debug("AutomationEngine.on_event: no running loop, event dropped: %s", trigger)

    async def on_event_async(self, trigger_type: str | TriggerType, data: dict | None = None) -> None:
        """Async entry point for event-driven triggers (call from async code)."""
        trigger = TriggerType(trigger_type) if isinstance(trigger_type, str) else trigger_type
        await self._dispatch_event(trigger, data or {})

    async def _dispatch_event(self, trigger: TriggerType, data: dict) -> None:
        with get_connection() as conn:
            rows = conn.execute(
                "SELECT * FROM automations WHERE enabled=1 AND trigger_type=?",
                (trigger.value,),
            ).fetchall()

        for row in rows:
            automation = _row_to_dict(row)
            # Cooldown check
            last = automation.get("last_triggered")
            cooldown = automation.get("cooldown_seconds") or 300
            if last:
                try:
                    last_dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
                    elapsed = (datetime.now(UTC) - last_dt).total_seconds()
                    if elapsed < cooldown:
                        logger.debug(
                            "Automation id=%d cooldown (%ds remaining)",
                            automation["id"], int(cooldown - elapsed),
                        )
                        continue
                except Exception:
                    pass

            logger.info(
                "Automation id=%d (%r) triggered by event: %s",
                automation["id"], automation["name"], trigger.value,
            )
            asyncio.create_task(
                self._execute(automation, data),
                name=f"automation-{automation['id']}",
            )

    # ------------------------------------------------------------------ #
    # Execution
    # ------------------------------------------------------------------ #

    async def run_now(self, automation_id: int) -> dict:
        """Immediately execute an automation by ID (ignores cooldown)."""
        with get_connection() as conn:
            row = conn.execute(
                "SELECT * FROM automations WHERE id=?", (automation_id,)
            ).fetchone()
        if not row:
            raise ValueError(f"Automation {automation_id} not found")
        automation = _row_to_dict(row)
        return await self._execute(automation, {"trigger": "manual"})

    async def _execute(self, automation: dict, trigger_data: dict) -> dict:
        """Execute the action for an automation and log the result."""
        automation_id = automation["id"]
        action_type_str = automation["action_type"]
        action_config = automation.get("action_config") or {}

        start_ms = time.monotonic()
        status = "failed"
        error_msg: str | None = None
        result_msg = ""

        try:
            action_type = ActionType(action_type_str)
            executor = _ACTION_EXECUTORS.get(action_type)
            if not executor:
                raise ValueError(f"Unknown action type: {action_type_str}")
            # Inject automation_id so actions that need to persist state back
            # (e.g. saving a newly-created Qobuz playlist_id) can do so.
            action_config = {**action_config, "automation_id": automation_id}
            result_msg = await executor(action_config)
            status = "success"
        except Exception as exc:
            error_msg = str(exc)
            logger.error(
                "Automation id=%d action %r failed: %s",
                automation_id, action_type_str, exc, exc_info=True,
            )

        duration_ms = int((time.monotonic() - start_ms) * 1000)
        now = _now_iso()

        with get_connection() as conn:
            conn.execute(
                """UPDATE automations
                   SET last_triggered=?, last_status=?, run_count=run_count+1
                   WHERE id=?""",
                (now, status, automation_id),
            )
            conn.execute(
                """INSERT INTO automation_log
                   (automation_id, triggered_at, trigger_type, action_type, status, duration_ms, error_message)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    automation_id,
                    now,
                    automation.get("trigger_type"),
                    action_type_str,
                    status,
                    duration_ms,
                    error_msg,
                ),
            )
            conn.commit()

        logger.info(
            "Automation id=%d finished: status=%s duration=%dms%s",
            automation_id, status, duration_ms,
            f" ({error_msg})" if error_msg else f" — {result_msg}",
        )
        return {
            "automation_id": automation_id,
            "status": status,
            "duration_ms": duration_ms,
            "result": result_msg,
            "error": error_msg,
        }


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_engine: AutomationEngine | None = None


def get_engine() -> AutomationEngine | None:
    """Return the running AutomationEngine singleton, or None if not started."""
    return _engine


def init_engine() -> AutomationEngine:
    """Create and start the global AutomationEngine."""
    global _engine
    if _engine is None:
        _engine = AutomationEngine()
    _engine.start()
    return _engine


def stop_engine() -> None:
    """Stop the global AutomationEngine if running."""
    global _engine
    if _engine is not None:
        _engine.stop()
