"""Scheduled playlist regeneration for RoonSage.

PlaylistScheduler runs an asyncio background loop that fires playlist generation
jobs according to cron expressions stored in the ``scheduled_playlists`` DB table.

Cron format: "minute hour day-of-month month day-of-week"
  - Fields:       0-59  0-23  1-31           1-12  0-6 (0=Sunday)
  - Wildcards:    *     — match any value
  - Ranges:       1-5   — match 1 through 5 (inclusive)
  - Lists:        1,3,5 — match any value in the list

The scheduler checks every 60 seconds whether any enabled schedule is due.
Double-run protection: a schedule is skipped when its last_run is within 55 s of now.
"""

import asyncio
import contextlib
import json
import logging
import random
from datetime import UTC, datetime

from backend.db import get_connection

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Cron parsing helpers
# ---------------------------------------------------------------------------


def _parse_field(field: str, lo: int, hi: int) -> set[int]:
    """Parse a single cron field into a set of matching integers.

    Supports:
      *        — all values in [lo, hi]
      N        — exact value
      N-M      — inclusive range
      N,M,...  — comma-separated list of any of the above
    """
    values: set[int] = set()
    for part in field.split(","):
        part = part.strip()
        if part == "*":
            values.update(range(lo, hi + 1))
        elif "-" in part:
            start, end = part.split("-", 1)
            values.update(range(int(start), int(end) + 1))
        else:
            values.add(int(part))
    return values


def matches_cron(cron_expr: str, dt: datetime) -> bool:
    """Return True if *dt* matches *cron_expr*.

    Args:
        cron_expr: Five-field cron string ("minute hour dom month dow").
        dt:        datetime to test (timezone-aware or naive local time).

    Returns:
        True when all five fields match the datetime.
    """
    try:
        fields = cron_expr.strip().split()
        if len(fields) != 5:
            logger.warning("Invalid cron expression (expected 5 fields): %r", cron_expr)
            return False

        minute_f, hour_f, dom_f, month_f, dow_f = fields

        minutes = _parse_field(minute_f, 0, 59)
        hours = _parse_field(hour_f, 0, 23)
        doms = _parse_field(dom_f, 1, 31)
        months = _parse_field(month_f, 1, 12)
        dows = _parse_field(dow_f, 0, 6)

        # Python's weekday(): Monday=0 … Sunday=6; cron: Sunday=0 … Saturday=6
        py_weekday = dt.weekday()  # 0=Mon … 6=Sun
        cron_dow = (py_weekday + 1) % 7  # 0=Sun … 6=Sat

        return (
            dt.minute in minutes
            and dt.hour in hours
            and dt.day in doms
            and dt.month in months
            and cron_dow in dows
        )
    except Exception as exc:
        logger.warning("Error parsing cron %r: %s", cron_expr, exc)
        return False


# ---------------------------------------------------------------------------
# Schedule runner
# ---------------------------------------------------------------------------


async def _generate_circadian_tracks(
    track_count: int, schedule_id: int, name: str
) -> tuple[list[dict], str]:
    """Generate tracks for a circadian-type schedule using the current hour."""
    from backend.audio_features import circadian as _circadian  # noqa: PLC0415
    from backend.db import get_db_connection as _gdc  # noqa: PLC0415

    hour = datetime.now().hour

    def _run() -> dict:
        conn = _gdc()
        try:
            return _circadian.get_circadian_playlist(
                conn, hour=hour, limit=track_count
            )
        finally:
            conn.close()

    data = await asyncio.to_thread(_run)
    if data.get("error"):
        raise RuntimeError(data["error"])
    results = data.get("results") or []
    if not results:
        raise RuntimeError(f"Circadian schedule returned no tracks for hour={hour}")
    logger.info(
        "Schedule id=%d circadian hour=%d -> %d tracks", schedule_id, hour, len(results)
    )
    title = f"{name} — hour {hour}"
    return results, title


async def _run_schedule(row: dict) -> None:
    """Execute a single scheduled playlist job.

    Steps:
      1. Generate playlist via the existing generator pipeline (or via the
         circadian audio-feature engine when ``schedule_type == 'circadian'``).
      2. Optionally save to Qobuz (overwrite existing playlist or create new).
      3. Optionally queue into a Roon zone.
      4. Update last_run / last_status / last_error in DB.
    """
    schedule_id: int = row["id"]
    name: str = row["name"]
    prompt: str = row["prompt"]
    track_count: int = row["track_count"] or 25
    zone_name: str | None = row["zone_name"]
    save_to_qobuz: bool = bool(row["save_to_qobuz"])
    qobuz_playlist_id: str | None = row["qobuz_playlist_id"]
    schedule_type: str = (row.get("schedule_type") or "prompt").lower()

    # Parse optional filters JSON
    filters: dict = {}
    if row["filters"]:
        with contextlib.suppress(Exception):
            filters = json.loads(row["filters"])

    genres: list[str] | None = filters.get("genres") or None
    decades: list[str] | None = filters.get("decades") or None
    exclude_live: bool = filters.get("exclude_live", True)

    logger.info(
        "Running scheduled playlist id=%d name=%r type=%s",
        schedule_id, name, schedule_type,
    )
    error_msg: str | None = None
    status = "failed"
    generated_tracks: list[dict] = []
    playlist_title: str = name

    try:
        if schedule_type == "circadian":
            generated_tracks, playlist_title = await _generate_circadian_tracks(
                track_count=track_count,
                schedule_id=schedule_id,
                name=name,
            )
        else:
            # -------------------------------------------------------------------
            # 1. Generate playlist — consume the synchronous SSE generator
            # -------------------------------------------------------------------
            from backend.llm_client import is_background_ai_enabled  # noqa: PLC0415

            if not is_background_ai_enabled():
                logger.info(
                    "Schedule id=%d skipped — background AI disabled for paid provider", schedule_id
                )
                return

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
                    source_mode="library",
                ):
                    # SSE chunks look like "event: done\ndata: {...}\n\n"
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
                raise RuntimeError("Generation produced no tracks")

            generated_tracks = result_data["tracks"]
            playlist_title = result_data.get("title") or name
        logger.info(
            "Schedule id=%d generated %d tracks (title=%r)",
            schedule_id, len(generated_tracks), playlist_title,
        )

        # -------------------------------------------------------------------
        # 2. Save / overwrite Qobuz playlist
        # -------------------------------------------------------------------
        if save_to_qobuz:
            from backend.qobuz_api import get_qobuz_api_client  # noqa: PLC0415
            qobuz_client = get_qobuz_api_client()
            if qobuz_client and qobuz_client.is_authenticated():
                track_dicts = [
                    {"artist": t.get("artist", ""), "title": t.get("title", "")}
                    for t in generated_tracks
                ]
                if qobuz_playlist_id:
                    # Overwrite existing playlist: resolve, clear, refill
                    resolved = await asyncio.to_thread(
                        qobuz_client.resolve_tracks, track_dicts
                    )
                    matched_ids = [str(m["qobuz_id"]) for m in resolved.get("matched", [])]
                    if matched_ids:
                        # Clear the playlist first by fetching its track playlist_track_ids
                        try:
                            pl = await asyncio.to_thread(
                                qobuz_client.get_playlist, qobuz_playlist_id
                            )
                            existing_pt_ids = [
                                str(t["playlist_track_id"])
                                for t in (pl.get("tracks", {}).get("items") or [])
                                if t.get("playlist_track_id")
                            ]
                            if existing_pt_ids:
                                await asyncio.to_thread(
                                    qobuz_client.remove_tracks_from_playlist,
                                    qobuz_playlist_id,
                                    existing_pt_ids,
                                )
                        except Exception as exc:
                            logger.warning("Could not clear Qobuz playlist %s: %s", qobuz_playlist_id, exc)

                        await asyncio.to_thread(
                            qobuz_client.add_tracks_to_playlist_by_id,
                            qobuz_playlist_id,
                            matched_ids,
                        )
                        logger.info(
                            "Schedule id=%d: updated Qobuz playlist %s with %d tracks",
                            schedule_id, qobuz_playlist_id, len(matched_ids),
                        )
                else:
                    # Create new playlist and persist the ID back to DB
                    save_result = await asyncio.to_thread(
                        qobuz_client.save_playlist,
                        name=playlist_title,
                        tracks=track_dicts,
                        description=f"Auto-generated by RoonSage — {prompt[:120]}",
                        is_public=False,
                    )
                    new_id = save_result.get("playlist_id") or save_result.get("id")
                    if new_id:
                        with get_connection() as conn:
                            conn.execute(
                                "UPDATE scheduled_playlists SET qobuz_playlist_id=? WHERE id=?",
                                (str(new_id), schedule_id),
                            )
                            conn.commit()
                        logger.info(
                            "Schedule id=%d: created new Qobuz playlist id=%s",
                            schedule_id, new_id,
                        )
            else:
                logger.info(
                    "Schedule id=%d: save_to_qobuz=True but Qobuz not configured — skipping",
                    schedule_id,
                )

        # -------------------------------------------------------------------
        # 3. Auto-play in zone
        # -------------------------------------------------------------------
        if zone_name and generated_tracks:
            from backend.roon_client import get_roon_client  # noqa: PLC0415
            roon = get_roon_client()
            if roon and roon.is_connected():
                # Find the zone_id by name (fuzzy)
                zones = roon.get_zones()
                zone_id: str | None = None
                zone_name_lower = zone_name.lower()
                for z in zones:
                    if zone_name_lower in z.get("display_name", "").lower():
                        zone_id = z.get("zone_id")
                        break

                if zone_id:
                    item_keys = [t.get("item_key", "") for t in generated_tracks if t.get("item_key")]
                    if item_keys:
                        await asyncio.to_thread(
                            roon.queue_tracks, zone_id, item_keys, replace_queue=True
                        )
                        logger.info(
                            "Schedule id=%d: queued %d tracks to zone %r (id=%s)",
                            schedule_id, len(item_keys), zone_name, zone_id,
                        )
                else:
                    logger.warning(
                        "Schedule id=%d: zone %r not found — skipping auto-play", schedule_id, zone_name
                    )

        status = "success"

    except Exception as exc:
        error_msg = str(exc)
        logger.error("Schedule id=%d failed: %s", schedule_id, exc, exc_info=True)

    # -------------------------------------------------------------------
    # 4. Persist run result
    # -------------------------------------------------------------------
    now_iso = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    with get_connection() as conn:
        conn.execute(
            """UPDATE scheduled_playlists
               SET last_run=?, last_status=?, last_error=?
               WHERE id=?""",
            (now_iso, status, error_msg, schedule_id),
        )
        conn.commit()

    logger.info(
        "Schedule id=%d finished: status=%s%s",
        schedule_id, status, f" ({error_msg})" if error_msg else "",
    )


# ---------------------------------------------------------------------------
# PlaylistScheduler
# ---------------------------------------------------------------------------


class PlaylistScheduler:
    """Asyncio background scheduler for playlist generation jobs."""

    # Prevent launching the same schedule twice within this window (seconds)
    _SKIP_WINDOW = 55

    def __init__(self) -> None:
        self._task: asyncio.Task | None = None  # type: ignore[type-arg]
        self._running = False

    def start(self) -> None:
        """Start the background polling loop."""
        if self._running:
            return
        self._running = True
        self._task = asyncio.create_task(self._loop(), name="playlist-scheduler")
        logger.info("PlaylistScheduler started (checks every 60 s)")

    def stop(self) -> None:
        """Stop the background loop gracefully."""
        self._running = False
        if self._task and not self._task.done():
            self._task.cancel()
        logger.info("PlaylistScheduler stopped")

    async def _loop(self) -> None:
        """Main polling loop — runs every ~60 seconds with ±9 s jitter."""
        while self._running:
            try:
                await self._check_and_fire()
            except asyncio.CancelledError:
                break
            except Exception as exc:
                logger.error("Scheduler loop error: %s", exc, exc_info=True)
            await asyncio.sleep(60 + random.uniform(-9, 9))

    async def _check_and_fire(self) -> None:
        """Load enabled schedules and fire any that are due right now."""
        now = datetime.now()

        with get_connection() as conn:
            rows = conn.execute(
                "SELECT * FROM scheduled_playlists WHERE enabled=1"
            ).fetchall()

        for row in rows:
            row_dict = dict(row)
            cron_expr = row_dict.get("schedule", "")
            if not cron_expr:
                continue

            if not matches_cron(cron_expr, now):
                continue

            # Double-run guard: skip if last_run is within _SKIP_WINDOW seconds
            last_run_iso = row_dict.get("last_run")
            if last_run_iso:
                try:
                    last_dt = datetime.fromisoformat(last_run_iso.replace("Z", "+00:00"))
                    last_local = last_dt.replace(tzinfo=None)
                    diff = (now - last_local).total_seconds()
                    if diff < self._SKIP_WINDOW:
                        logger.debug(
                            "Schedule id=%d skipped (last_run %ds ago)", row_dict["id"], int(diff)
                        )
                        continue
                except Exception:
                    pass

            logger.info(
                "Schedule id=%d (%r) is due at %s — launching",
                row_dict["id"], row_dict.get("name"), now.strftime("%H:%M"),
            )
            asyncio.create_task(
                _run_schedule(row_dict),
                name=f"schedule-{row_dict['id']}",
            )


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_scheduler: PlaylistScheduler | None = None


def get_scheduler() -> PlaylistScheduler | None:
    """Return the running PlaylistScheduler singleton, or None if not started."""
    return _scheduler


def init_scheduler() -> PlaylistScheduler:
    """Create and start the global PlaylistScheduler."""
    global _scheduler
    if _scheduler is None:
        _scheduler = PlaylistScheduler()
    _scheduler.start()
    return _scheduler


def stop_scheduler() -> None:
    """Stop the global PlaylistScheduler if running."""
    global _scheduler
    if _scheduler is not None:
        _scheduler.stop()
