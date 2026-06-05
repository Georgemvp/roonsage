"""Pipelines — one-click multi-step automation recipes.

A pipeline is a named bundle of automations. Installing one inserts every
automation in the recipe into the `automations` table in a single click, so the
user doesn't have to wire each schedule/trigger by hand. Built on the existing
automation engine — no new execution machinery.
"""

from __future__ import annotations

import json
from typing import Any

from fastapi import APIRouter, HTTPException

from backend.automation_engine import ActionType, TriggerType
from backend.db import get_connection

router = APIRouter(prefix="/api/pipelines", tags=["pipelines"])


# Each step becomes one row in `automations`. trigger/action types must be valid
# TriggerType / ActionType values (validated at install time).
_PIPELINES: list[dict[str, Any]] = [
    {
        "id": "nightly_ops",
        "name": "Nightly Operations",
        "description": "Keep everything fresh overnight: sync the library at 03:00, "
                       "refresh ListenBrainz right after, then run maintenance at 04:00.",
        "steps": [
            {
                "name": "Nightly · library sync",
                "trigger_type": "schedule", "trigger_config": {"cron": "0 3 * * *"},
                "action_type": "sync_library", "action_config": {},
            },
            {
                "name": "Nightly · ListenBrainz refresh after sync",
                "trigger_type": "library_synced", "trigger_config": {},
                "action_type": "sync_listenbrainz", "action_config": {},
            },
            {
                "name": "Nightly · maintenance",
                "trigger_type": "schedule", "trigger_config": {"cron": "0 4 * * *"},
                "action_type": "run_maintenance", "action_config": {},
            },
        ],
    },
    {
        "id": "new_music",
        "name": "New Music",
        "description": "Scan watched artists for new releases every day at noon and "
                       "notify you the moment something drops.",
        "steps": [
            {
                "name": "New Music · daily watchlist scan",
                "trigger_type": "schedule", "trigger_config": {"cron": "0 12 * * *"},
                "action_type": "scan_watchlist", "action_config": {},
            },
            {
                "name": "New Music · new-release alert",
                "trigger_type": "watchlist_match", "trigger_config": {},
                "action_type": "send_notification",
                "action_config": {"message": "New release found for a watched artist!"},
            },
        ],
    },
    {
        "id": "daily_circadian",
        "name": "Daily Circadian Playlists",
        "description": "Generate morning, afternoon and evening playlists each day at "
                       "06:00, and keep the queue flowing with smart continuation.",
        "steps": [
            {
                "name": "Circadian · daily set at 06:00",
                "trigger_type": "schedule", "trigger_config": {"cron": "0 6 * * *"},
                "action_type": "generate_circadian_set", "action_config": {"track_count": 25},
            },
            {
                "name": "Circadian · smart queue continuation",
                "trigger_type": "queue_ending", "trigger_config": {},
                "action_type": "smart_continuation", "action_config": {},
            },
        ],
    },
    {
        "id": "sync_chain",
        "name": "Library + ListenBrainz Chain",
        "description": "Een signal-chain: nightly library sync → fire 'library.synced' "
                       "signal → ListenBrainz refresh → notificatie. Demonstreert "
                       "then_actions + signal_received.",
        "steps": [
            {
                "name": "Chain · nightly library sync (signal source)",
                "trigger_type": "schedule", "trigger_config": {"cron": "30 2 * * *"},
                "action_type": "sync_library", "action_config": {},
                "then_actions": [
                    {
                        "type": "emit_signal",
                        "config": {"signal": "library.synced",
                                   "payload": {"source": "nightly"}},
                    }
                ],
            },
            {
                "name": "Chain · refresh ListenBrainz on signal",
                "trigger_type": "signal_received",
                "trigger_config": {"signal": "library.synced"},
                "action_type": "sync_listenbrainz", "action_config": {},
                "then_actions": [
                    {
                        "type": "emit_signal",
                        "config": {"signal": "stats.refresh"},
                    }
                ],
            },
            {
                "name": "Chain · notify when stats refresh fires",
                "trigger_type": "signal_received",
                "trigger_config": {"signal": "stats.refresh"},
                "action_type": "send_notification",
                "action_config": {
                    "message": "Nachtelijke library + scrobble refresh klaar.",
                    "channel": "all",
                },
            },
        ],
    },
]

_PIPELINE_BY_ID = {p["id"]: p for p in _PIPELINES}


def _validate_step(step: dict[str, Any]) -> None:
    try:
        TriggerType(step["trigger_type"])
        ActionType(step["action_type"])
    except ValueError as exc:
        raise HTTPException(status_code=500, detail=f"Invalid pipeline step: {exc}") from None


@router.get("")
async def list_pipelines() -> list[dict[str, Any]]:
    """Return the built-in pipeline recipes (id, name, description, step count)."""
    return [
        {
            "id": p["id"],
            "name": p["name"],
            "description": p["description"],
            "step_count": len(p["steps"]),
            "steps": [{"name": s["name"], "trigger": s["trigger_type"], "action": s["action_type"]}
                      for s in p["steps"]],
        }
        for p in _PIPELINES
    ]


@router.post("/{pipeline_id}/install", status_code=201)
async def install_pipeline(pipeline_id: str) -> dict[str, Any]:
    """Create every automation in the recipe. Idempotent by name: steps whose
    name already exists in `automations` are skipped, so re-installing won't
    create duplicates."""
    pipeline = _PIPELINE_BY_ID.get(pipeline_id)
    if pipeline is None:
        raise HTTPException(status_code=404, detail=f"Unknown pipeline '{pipeline_id}'")

    created: list[dict[str, Any]] = []
    skipped: list[str] = []

    with get_connection() as conn:
        existing_names = {
            r[0] for r in conn.execute("SELECT name FROM automations").fetchall()
        }
        for step in pipeline["steps"]:
            _validate_step(step)
            if step["name"] in existing_names:
                skipped.append(step["name"])
                continue
            cursor = conn.execute(
                """INSERT INTO automations
                   (name, trigger_type, trigger_config, action_type, action_config,
                    then_actions, enabled, cooldown_seconds)
                   VALUES (?, ?, ?, ?, ?, ?, 1, ?)""",
                (
                    step["name"],
                    step["trigger_type"],
                    json.dumps(step.get("trigger_config", {})),
                    step["action_type"],
                    json.dumps(step.get("action_config", {})),
                    json.dumps(step.get("then_actions", [])),
                    step.get("cooldown_seconds", 300),
                ),
            )
            created.append({"id": cursor.lastrowid, "name": step["name"]})
        conn.commit()

    return {
        "pipeline": pipeline_id,
        "installed": len(created),
        "skipped": len(skipped),
        "created": created,
        "skipped_names": skipped,
    }
