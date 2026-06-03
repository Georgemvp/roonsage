"""Unified worker dashboard.

Aggregates the background workers behind a single endpoint so the Workers view
can render them in one poll, and routes pause/resume by worker name. The
per-worker control routes (under /api/enrichment and /api/audio-features) still
exist and remain the source of truth — this is a thin façade over them.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import APIRouter, HTTPException

from backend.db import get_db_connection

router = APIRouter(prefix="/api/workers", tags=["workers"])
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Per-worker probes — each wrapped so one failure can't blank the dashboard
# ---------------------------------------------------------------------------

def _pct(complete: int, total: int) -> int:
    return round(complete / total * 100) if total else 0


def _enrichment_status() -> dict[str, Any]:
    from backend.enrichment_worker import get_queue_stats, get_worker  # noqa: PLC0415

    conn = get_db_connection()
    try:
        stats = get_queue_stats(conn)
    finally:
        conn.close()
    worker = get_worker()
    pending = stats.get("pending", 0)
    processing = stats.get("processing", 0)
    complete = stats.get("complete", 0)
    failed = stats.get("failed", 0)
    total = pending + processing + complete + failed
    return {
        "name": "enrichment",
        "label": "Metadata Enrichment",
        "controllable": True,
        "running": worker.is_running(),
        "paused": worker.is_paused(),
        "queue": {"pending": pending, "processing": processing, "complete": complete, "failed": failed},
        "progress_pct": _pct(complete, total),
        "detail": f"{stats.get('enriched_total', complete)} tracks enriched",
    }


def _audio_features_status() -> dict[str, Any]:
    from backend.audio_features.worker import get_features_worker, get_queue_stats  # noqa: PLC0415
    from backend.config import get_audio_features_enabled  # noqa: PLC0415

    if not get_audio_features_enabled():
        return {
            "name": "audio_features",
            "label": "Audio Features",
            "controllable": True,
            "running": False,
            "paused": False,
            "queue": {"pending": 0, "processing": 0, "complete": 0, "failed": 0},
            "progress_pct": 0,
            "detail": "Disabled (AUDIO_FEATURES_ENABLED=false)",
            "disabled": True,
        }

    conn = get_db_connection()
    try:
        stats = get_queue_stats(conn)
    finally:
        conn.close()
    worker = get_features_worker()
    pending = stats.get("pending", 0)
    analyzing = stats.get("analyzing", 0)
    complete = stats.get("complete", 0)
    failed = stats.get("failed", 0)
    total = pending + analyzing + complete + failed
    return {
        "name": "audio_features",
        "label": "Audio Features",
        "controllable": True,
        "running": worker.is_running(),
        "paused": worker.is_paused(),
        "queue": {"pending": pending, "processing": analyzing, "complete": complete, "failed": failed},
        "progress_pct": _pct(complete, total),
        "detail": f"{stats.get('analysed_total', complete)} tracks analysed",
    }


def _scheduler_status() -> dict[str, Any]:
    from backend.scheduler import get_scheduler  # noqa: PLC0415

    sched = get_scheduler()
    count = 0
    if sched is not None:
        conn = get_db_connection()
        try:
            row = conn.execute(
                "SELECT COUNT(*) FROM scheduled_playlists WHERE enabled = 1"
            ).fetchone()
            count = row[0] if row else 0
        except Exception:
            count = 0
        finally:
            conn.close()
    return {
        "name": "scheduler",
        "label": "Playlist Scheduler",
        "controllable": False,
        "running": sched is not None,
        "paused": False,
        "queue": None,
        "progress_pct": None,
        "detail": f"{count} scheduled playlist(s)",
    }


_PROBES = (_enrichment_status, _audio_features_status, _scheduler_status)


# ---------------------------------------------------------------------------
# Pause / resume dispatch
# ---------------------------------------------------------------------------

def _get_controllable(name: str):
    if name == "enrichment":
        from backend.enrichment_worker import get_worker  # noqa: PLC0415
        return get_worker()
    if name == "audio_features":
        from backend.audio_features.worker import get_features_worker  # noqa: PLC0415
        return get_features_worker()
    return None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("/status")
async def workers_status() -> dict[str, Any]:
    """Snapshot of every background worker for the dashboard."""
    workers: list[dict[str, Any]] = []
    for probe in _PROBES:
        try:
            workers.append(probe())
        except Exception as exc:
            logger.warning("worker probe %s failed: %s", probe.__name__, exc)
            workers.append({
                "name": probe.__name__.strip("_").replace("_status", ""),
                "label": "Worker",
                "controllable": False,
                "running": False,
                "paused": False,
                "queue": None,
                "progress_pct": None,
                "detail": f"status unavailable: {exc}",
                "error": True,
            })
    return {"workers": workers}


@router.post("/{name}/pause")
async def pause_worker(name: str) -> dict[str, Any]:
    worker = _get_controllable(name)
    if worker is None:
        raise HTTPException(status_code=404, detail=f"Unknown or non-controllable worker '{name}'")
    worker.pause()
    return {"success": True, "name": name, "paused": True}


@router.post("/{name}/resume")
async def resume_worker(name: str) -> dict[str, Any]:
    worker = _get_controllable(name)
    if worker is None:
        raise HTTPException(status_code=404, detail=f"Unknown or non-controllable worker '{name}'")
    if not worker.is_running():
        worker.start()
    worker.resume()
    return {"success": True, "name": name, "paused": False}
