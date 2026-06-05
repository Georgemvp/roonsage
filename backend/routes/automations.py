"""REST API endpoints for the RoonSage Automation Engine.

Routes:
  GET    /api/automations             — list all automations
  POST   /api/automations             — create automation
  PUT    /api/automations/{id}        — update automation
  DELETE /api/automations/{id}        — delete automation
  PATCH  /api/automations/{id}/toggle — enable/disable
  POST   /api/automations/{id}/run    — trigger immediately
  GET    /api/automations/log         — recent runs (last 100)
  GET    /api/automations/presets     — built-in presets
  GET    /api/automations/graph       — load the visual builder graph
  POST   /api/automations/graph       — save the visual builder graph
"""

from __future__ import annotations

import json
import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.automation_engine import (
    ActionType,
    TriggerType,
    get_engine,
)
from backend.db import get_connection

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/automations", tags=["automations"])


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------


class AutomationCreate(BaseModel):
    name: str
    trigger_type: str
    trigger_config: dict = {}
    action_type: str
    action_config: dict = {}
    then_actions: list[dict] = []
    enabled: bool = True
    cooldown_seconds: int = 300


class AutomationUpdate(BaseModel):
    name: str | None = None
    trigger_type: str | None = None
    trigger_config: dict | None = None
    action_type: str | None = None
    action_config: dict | None = None
    then_actions: list[dict] | None = None
    enabled: bool | None = None
    cooldown_seconds: int | None = None




# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_BUILT_IN_PRESETS = [
    {
        "name": "Morning Playlist",
        "description": "Calm playlist on weekday mornings at 07:00",
        "trigger": {"type": "schedule", "cron": "0 7 * * 1-5"},
        "action": {
            "type": "generate_playlist",
            "prompt": "Calm morning music to start the day",
            "track_count": 20,
        },
    },
    {
        "name": "Friday Evening",
        "description": "Celebration mix every Friday at 18:00",
        "trigger": {"type": "schedule", "cron": "0 18 * * 5"},
        "action": {
            "type": "generate_playlist",
            "prompt": "Friday evening celebration mix",
            "track_count": 30,
        },
    },
    {
        "name": "Nightly Library Sync",
        "description": "Keep the library cache fresh at 03:00 every night",
        "trigger": {"type": "schedule", "cron": "0 3 * * *"},
        "action": {"type": "sync_library"},
    },
    {
        "name": "New Release Alert",
        "description": "Send a notification whenever a watched artist releases something new",
        "trigger": {"type": "watchlist_match"},
        "action": {
            "type": "send_notification",
            "message": "New release found for a watched artist!",
        },
    },
    {
        "name": "Weekly Maintenance",
        "description": "Clean up old automation logs and listening history every Sunday at 04:00",
        "trigger": {"type": "schedule", "cron": "0 4 * * 0"},
        "action": {"type": "run_maintenance"},
    },
    {
        "name": "Post-Sync ListenBrainz Refresh",
        "description": "Refresh ListenBrainz stats after every library sync",
        "trigger": {"type": "library_synced"},
        "action": {"type": "sync_listenbrainz"},
    },
    {
        "name": "Auto-scan Watchlist",
        "description": "Scan watched artists for new releases every day at noon",
        "trigger": {"type": "schedule", "cron": "0 12 * * *"},
        "action": {"type": "scan_watchlist"},
    },
    {
        "name": "Daily circadian playlists at 6am",
        "description": "Generate morning, afternoon and evening playlists each day at 06:00",
        "trigger": {"type": "schedule", "cron": "0 6 * * *"},
        "action": {"type": "generate_circadian_set", "track_count": 25},
    },
]


def _serialize_row(row) -> dict:
    d = dict(row)
    for key in ("trigger_config", "action_config"):
        if isinstance(d.get(key), str):
            try:
                d[key] = json.loads(d[key])
            except Exception:
                d[key] = {}
    raw_then = d.get("then_actions")
    if isinstance(raw_then, str):
        try:
            d["then_actions"] = json.loads(raw_then)
        except Exception:
            d["then_actions"] = []
    elif raw_then is None:
        d["then_actions"] = []
    d["enabled"] = bool(d.get("enabled", 1))
    return d


def _validate_trigger_type(value: str) -> None:
    try:
        TriggerType(value)
    except ValueError:
        valid = [t.value for t in TriggerType]
        raise HTTPException(
            status_code=422, detail=f"Invalid trigger_type {value!r}. Valid: {valid}"
        ) from None


def _validate_action_type(value: str) -> None:
    try:
        ActionType(value)
    except ValueError:
        valid = [a.value for a in ActionType]
        raise HTTPException(
            status_code=422, detail=f"Invalid action_type {value!r}. Valid: {valid}"
        ) from None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("/presets")
async def get_presets() -> list[dict]:
    """Return built-in automation presets."""
    return _BUILT_IN_PRESETS


@router.get("/log")
async def get_log(limit: int = 100) -> list[dict]:
    """Return the most recent automation run entries."""
    limit = min(max(1, limit), 500)
    with get_connection() as conn:
        rows = conn.execute(
            """SELECT al.*, a.name AS automation_name
               FROM automation_log al
               LEFT JOIN automations a ON al.automation_id = a.id
               ORDER BY al.triggered_at DESC
               LIMIT ?""",
            (limit,),
        ).fetchall()
    return [dict(r) for r in rows]


@router.get("")
async def list_automations() -> list[dict]:
    """List all automations with their current status."""
    with get_connection() as conn:
        rows = conn.execute(
            "SELECT * FROM automations ORDER BY created_at DESC"
        ).fetchall()
    return [_serialize_row(r) for r in rows]


@router.post("", status_code=201)
async def create_automation(body: AutomationCreate) -> dict:
    """Create a new automation."""
    _validate_trigger_type(body.trigger_type)
    _validate_action_type(body.action_type)

    with get_connection() as conn:
        cursor = conn.execute(
            """INSERT INTO automations
               (name, trigger_type, trigger_config, action_type, action_config,
                then_actions, enabled, cooldown_seconds)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                body.name,
                body.trigger_type,
                json.dumps(body.trigger_config),
                body.action_type,
                json.dumps(body.action_config),
                json.dumps(body.then_actions or []),
                1 if body.enabled else 0,
                body.cooldown_seconds,
            ),
        )
        conn.commit()
        new_id = cursor.lastrowid
        row = conn.execute("SELECT * FROM automations WHERE id=?", (new_id,)).fetchone()

    return _serialize_row(row)




@router.put("/{automation_id}")
async def update_automation(automation_id: int, body: AutomationUpdate) -> dict:
    """Update an existing automation."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM automations WHERE id=?", (automation_id,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail=f"Automation {automation_id} not found")

        current = _serialize_row(row)

        if body.trigger_type is not None:
            _validate_trigger_type(body.trigger_type)
        if body.action_type is not None:
            _validate_action_type(body.action_type)

        new_name = body.name if body.name is not None else current["name"]
        new_trigger_type = body.trigger_type if body.trigger_type is not None else current["trigger_type"]
        new_trigger_config = json.dumps(body.trigger_config if body.trigger_config is not None else current["trigger_config"])
        new_action_type = body.action_type if body.action_type is not None else current["action_type"]
        new_action_config = json.dumps(body.action_config if body.action_config is not None else current["action_config"])
        new_then = json.dumps(
            body.then_actions if body.then_actions is not None else current.get("then_actions", [])
        )
        new_enabled = (1 if body.enabled else 0) if body.enabled is not None else current["enabled"]
        new_cooldown = body.cooldown_seconds if body.cooldown_seconds is not None else current["cooldown_seconds"]

        conn.execute(
            """UPDATE automations
               SET name=?, trigger_type=?, trigger_config=?, action_type=?, action_config=?,
                   then_actions=?, enabled=?, cooldown_seconds=?
               WHERE id=?""",
            (new_name, new_trigger_type, new_trigger_config, new_action_type, new_action_config,
             new_then, new_enabled, new_cooldown, automation_id),
        )
        conn.commit()
        updated = conn.execute("SELECT * FROM automations WHERE id=?", (automation_id,)).fetchone()

    return _serialize_row(updated)


@router.delete("/{automation_id}", status_code=204)
async def delete_automation(automation_id: int) -> None:
    """Delete an automation and its log entries."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT id FROM automations WHERE id=?", (automation_id,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail=f"Automation {automation_id} not found")
        conn.execute("DELETE FROM automation_log WHERE automation_id=?", (automation_id,))
        conn.execute("DELETE FROM automations WHERE id=?", (automation_id,))
        conn.commit()


@router.patch("/{automation_id}/toggle")
async def toggle_automation(automation_id: int) -> dict:
    """Toggle the enabled/disabled state of an automation."""
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM automations WHERE id=?", (automation_id,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail=f"Automation {automation_id} not found")
        new_enabled = 0 if row["enabled"] else 1
        conn.execute(
            "UPDATE automations SET enabled=? WHERE id=?", (new_enabled, automation_id)
        )
        conn.commit()
        updated = conn.execute("SELECT * FROM automations WHERE id=?", (automation_id,)).fetchone()

    result = _serialize_row(updated)
    return {"id": automation_id, "enabled": result["enabled"], "name": result["name"]}


@router.post("/{automation_id}/run")
async def run_automation(automation_id: int) -> dict:
    """Immediately trigger an automation (bypasses cooldown)."""
    engine = get_engine()
    if not engine:
        raise HTTPException(status_code=503, detail="AutomationEngine not started")
    try:
        result = await engine.run_now(automation_id)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return result


# ---------------------------------------------------------------------------
# Visual builder graph (Tier 3.2)
# ---------------------------------------------------------------------------
#
# Stores a React-Flow document (nodes + edges) per automation. The legacy
# trigger/action engine remains the runtime — the graph is a richer overlay
# that we render the same automation from.
#
# Storage: a simple key/value table created on demand. id=null for the
# singleton "current draft" graph; persisted graphs get an integer id.


class GraphDocBody(BaseModel):
    id: int | None = None
    name: str = "Nieuwe automation"
    enabled: bool = True
    nodes: list[dict] = []
    edges: list[dict] = []


def _ensure_graph_table() -> None:
    with get_connection() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS automation_graphs (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                name        TEXT NOT NULL,
                enabled     INTEGER DEFAULT 1,
                doc         TEXT NOT NULL,
                created_at  TEXT DEFAULT (datetime('now')),
                updated_at  TEXT DEFAULT (datetime('now'))
            )
            """
        )
        conn.commit()


def _signal_chain_depth(nodes: list[dict], edges: list[dict]) -> int:
    """Compute the worst-case signal chain depth.

    A 'signal' node forwards an event to another graph; chains > 5 levels deep
    are rejected so a runaway loop can't flood the engine. We BFS edges from
    every emit_signal action node and return the longest reachable path.
    """
    adj: dict[str, list[str]] = {}
    for e in edges:
        src, tgt = e.get("source"), e.get("target")
        if src and tgt:
            adj.setdefault(src, []).append(tgt)

    seeds = [
        n["id"]
        for n in nodes
        if isinstance(n.get("data"), dict)
        and str(n["data"].get("kind", "")).endswith("emit_signal")
    ]

    best = 0
    for seed in seeds:
        stack = [(seed, 0)]
        visited: set[str] = set()
        while stack:
            node, depth = stack.pop()
            if node in visited:
                continue
            visited.add(node)
            best = max(best, depth)
            for nxt in adj.get(node, []):
                stack.append((nxt, depth + 1))
    return best


@router.get("/graph")
async def load_graph() -> dict:
    """Return the latest saved graph or an empty draft."""
    _ensure_graph_table()
    with get_connection() as conn:
        row = conn.execute(
            "SELECT id, name, enabled, doc FROM automation_graphs ORDER BY updated_at DESC LIMIT 1"
        ).fetchone()
    if not row:
        return {"id": None, "name": "Nieuwe automation", "enabled": True, "nodes": [], "edges": []}
    doc = json.loads(row["doc"])
    return {
        "id": row["id"],
        "name": row["name"],
        "enabled": bool(row["enabled"]),
        "nodes": doc.get("nodes", []),
        "edges": doc.get("edges", []),
    }


@router.post("/graph")
async def save_graph(body: GraphDocBody) -> dict:
    """Validate and persist the graph document."""
    _ensure_graph_table()

    depth = _signal_chain_depth(body.nodes, body.edges)
    if depth > 5:
        raise HTTPException(
            status_code=400,
            detail=f"Signal chain depth {depth} exceeds the maximum of 5",
        )

    doc = json.dumps({"nodes": body.nodes, "edges": body.edges})
    with get_connection() as conn:
        if body.id:
            conn.execute(
                "UPDATE automation_graphs SET name=?, enabled=?, doc=?, updated_at=datetime('now') "
                "WHERE id=?",
                (body.name, 1 if body.enabled else 0, doc, body.id),
            )
            graph_id = body.id
        else:
            cur = conn.execute(
                "INSERT INTO automation_graphs (name, enabled, doc) VALUES (?, ?, ?)",
                (body.name, 1 if body.enabled else 0, doc),
            )
            graph_id = cur.lastrowid
        conn.commit()
    return {
        "id": graph_id,
        "name": body.name,
        "enabled": body.enabled,
        "signal_chain_depth": depth,
        "nodes": body.nodes,
        "edges": body.edges,
    }


class SignalFireBody(BaseModel):
    signal: str
    payload: dict = {}


@router.post("/signals/fire")
async def fire_signal_endpoint(body: SignalFireBody) -> dict:
    """Manually fire a signal — useful for testing chains from the UI."""
    engine = get_engine()
    if engine is None:
        raise HTTPException(status_code=503, detail="AutomationEngine not running")
    await engine.fire_signal(body.signal, body.payload, chain_depth=0)
    return {"ok": True, "signal": body.signal}
