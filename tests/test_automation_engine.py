"""Tests for AutomationEngine — row helpers, _execute, run_now, _dispatch_event."""

import asyncio
import json
import sqlite3
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import backend.db as _db
import backend.db.connection as _db_connection
from backend.automation_engine import (
    ActionType,
    AutomationEngine,
    TriggerType,
    _now_iso,
    _row_to_dict,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def tmp_db(tmp_path, monkeypatch):
    """Patch the DB path and initialise schema for each test."""
    db_path = tmp_path / "test_automations.db"
    monkeypatch.setattr(_db, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(_db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(_db, "_schema_initialized", False)

    from backend.db import ensure_db_initialized
    conn = ensure_db_initialized()
    conn.close()
    return db_path


@pytest.fixture()
def engine(tmp_db):
    """Return a fresh (not started) AutomationEngine bound to the tmp DB."""
    return AutomationEngine()


def _insert_automation(
    conn: sqlite3.Connection,
    *,
    name: str = "test auto",
    trigger_type: str = TriggerType.LIBRARY_SYNCED.value,
    trigger_config: dict | None = None,
    action_type: str = ActionType.RUN_MAINTENANCE.value,
    action_config: dict | None = None,
    enabled: int = 1,
    last_triggered: str | None = None,
    cooldown_seconds: int = 0,
) -> int:
    cur = conn.execute(
        """INSERT INTO automations
           (name, trigger_type, trigger_config, action_type, action_config,
            enabled, last_triggered, cooldown_seconds)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            name,
            trigger_type,
            json.dumps(trigger_config or {}),
            action_type,
            json.dumps(action_config or {}),
            enabled,
            last_triggered,
            cooldown_seconds,
        ),
    )
    conn.commit()
    return cur.lastrowid


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

class TestNowIso:
    def test_returns_utc_formatted_string(self):
        s = _now_iso()
        # Should parse back cleanly
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        assert dt.year >= 2024


class TestRowToDict:
    def test_converts_json_strings(self):
        row = MagicMock()
        row.__iter__ = MagicMock(return_value=iter([
            ("trigger_config", '{"cron": "0 8 * * *"}'),
            ("action_config", '{"zone": "Kitchen"}'),
            ("name", "my rule"),
        ]))
        row.keys = MagicMock(return_value=["trigger_config", "action_config", "name"])
        # Build a real dict to simulate sqlite3.Row
        raw = {"trigger_config": '{"cron": "0 8 * * *"}', "action_config": '{"zone": "Kitchen"}', "name": "my rule"}
        result = _row_to_dict(raw)
        assert result["trigger_config"] == {"cron": "0 8 * * *"}
        assert result["action_config"] == {"zone": "Kitchen"}
        assert result["name"] == "my rule"

    def test_invalid_json_becomes_empty_dict(self):
        raw = {"trigger_config": "not-json", "action_config": "{}"}
        result = _row_to_dict(raw)
        assert result["trigger_config"] == {}

    def test_non_string_values_are_preserved(self):
        raw = {"trigger_config": None, "action_config": None, "id": 42}
        result = _row_to_dict(raw)
        assert result["id"] == 42


# ---------------------------------------------------------------------------
# _execute
# ---------------------------------------------------------------------------

class TestExecute:
    @pytest.mark.asyncio
    async def test_successful_action_returns_success_status(self, engine, tmp_db):
        from backend.db import get_connection
        with get_connection() as conn:
            automation_id = _insert_automation(conn)
            row = dict(conn.execute(
                "SELECT * FROM automations WHERE id=?", (automation_id,)
            ).fetchone())

        automation = _row_to_dict(row)
        result = await engine._execute(automation, {"trigger": "test"})

        assert result["status"] == "success"
        assert result["automation_id"] == automation_id

    @pytest.mark.asyncio
    async def test_failed_action_returns_failed_status(self, engine, tmp_db):
        from backend.db import get_connection
        with get_connection() as conn:
            automation_id = _insert_automation(
                conn,
                action_type=ActionType.RUN_MAINTENANCE.value,
            )
            row = dict(conn.execute(
                "SELECT * FROM automations WHERE id=?", (automation_id,)
            ).fetchone())

        automation = _row_to_dict(row)
        # Patch the executor in the dispatch table so it raises deterministically
        with patch.dict(
            "backend.automation_engine._ACTION_EXECUTORS",
            {ActionType.RUN_MAINTENANCE: AsyncMock(side_effect=RuntimeError("db locked"))},
        ):
            result = await engine._execute(automation, {})

        assert result["status"] == "failed"
        assert "db locked" in (result["error"] or "")

    @pytest.mark.asyncio
    async def test_execute_writes_log_entry(self, engine, tmp_db):
        from backend.db import get_connection
        with get_connection() as conn:
            automation_id = _insert_automation(conn)
            row = dict(conn.execute(
                "SELECT * FROM automations WHERE id=?", (automation_id,)
            ).fetchone())

        automation = _row_to_dict(row)
        await engine._execute(automation, {})

        with get_connection() as conn:
            log = conn.execute(
                "SELECT * FROM automation_log WHERE automation_id=?", (automation_id,)
            ).fetchone()
        assert log is not None
        assert log["automation_id"] == automation_id

    @pytest.mark.asyncio
    async def test_execute_increments_run_count(self, engine, tmp_db):
        from backend.db import get_connection
        with get_connection() as conn:
            automation_id = _insert_automation(conn)
            row = dict(conn.execute(
                "SELECT * FROM automations WHERE id=?", (automation_id,)
            ).fetchone())

        automation = _row_to_dict(row)
        await engine._execute(automation, {})

        with get_connection() as conn:
            run_count = conn.execute(
                "SELECT run_count FROM automations WHERE id=?", (automation_id,)
            ).fetchone()[0]
        assert run_count == 1


# ---------------------------------------------------------------------------
# run_now
# ---------------------------------------------------------------------------

class TestRunNow:
    @pytest.mark.asyncio
    async def test_raises_for_missing_id(self, engine, tmp_db):
        with pytest.raises(ValueError, match="not found"):
            await engine.run_now(9999)

    @pytest.mark.asyncio
    async def test_runs_valid_automation(self, engine, tmp_db):
        from backend.db import get_connection
        with get_connection() as conn:
            automation_id = _insert_automation(conn)

        result = await engine.run_now(automation_id)
        assert result["automation_id"] == automation_id
        assert result["status"] in ("success", "failed")


# ---------------------------------------------------------------------------
# _dispatch_event
# ---------------------------------------------------------------------------

class TestDispatchEvent:
    @pytest.mark.asyncio
    async def test_triggers_matching_enabled_automation(self, engine, tmp_db):
        from backend.db import get_connection
        with get_connection() as conn:
            automation_id = _insert_automation(
                conn,
                trigger_type=TriggerType.LIBRARY_SYNCED.value,
                enabled=1,
            )

        executed_ids: list[int] = []
        original_execute = engine._execute

        async def tracking_execute(automation, data):
            executed_ids.append(automation["id"])
            return await original_execute(automation, data)

        engine._execute = tracking_execute
        await engine._dispatch_event(TriggerType.LIBRARY_SYNCED, {})
        # Give create_task a chance to run
        await asyncio.sleep(0)
        assert automation_id in executed_ids

    @pytest.mark.asyncio
    async def test_skips_disabled_automation(self, engine, tmp_db):
        from backend.db import get_connection
        with get_connection() as conn:
            automation_id = _insert_automation(
                conn,
                trigger_type=TriggerType.LIBRARY_SYNCED.value,
                enabled=0,
            )

        executed_ids: list[int] = []
        original_execute = engine._execute

        async def tracking_execute(automation, data):
            executed_ids.append(automation["id"])
            return await original_execute(automation, data)

        engine._execute = tracking_execute
        await engine._dispatch_event(TriggerType.LIBRARY_SYNCED, {})
        await asyncio.sleep(0)
        assert automation_id not in executed_ids

    @pytest.mark.asyncio
    async def test_cooldown_skips_recently_triggered(self, engine, tmp_db):
        from backend.db import get_connection
        recent = (datetime.now(UTC) - timedelta(seconds=10)).isoformat()
        with get_connection() as conn:
            automation_id = _insert_automation(
                conn,
                trigger_type=TriggerType.LIBRARY_SYNCED.value,
                last_triggered=recent,
                cooldown_seconds=300,  # 5 min cooldown — should skip
            )

        executed_ids: list[int] = []
        original_execute = engine._execute

        async def tracking_execute(automation, data):
            executed_ids.append(automation["id"])
            return await original_execute(automation, data)

        engine._execute = tracking_execute
        await engine._dispatch_event(TriggerType.LIBRARY_SYNCED, {})
        await asyncio.sleep(0)
        assert automation_id not in executed_ids


# ---------------------------------------------------------------------------
# _exec_run_maintenance (pure DB action, no external deps)
# ---------------------------------------------------------------------------

class TestExecRunMaintenance:
    @pytest.mark.asyncio
    async def test_deletes_old_log_entries(self, tmp_db):
        from backend.automation_engine import _exec_run_maintenance
        from backend.db import get_connection

        with get_connection() as conn:
            # Insert old log entry (40 days ago)
            conn.execute(
                """INSERT INTO automation_log
                   (automation_id, triggered_at, trigger_type, action_type, status)
                   VALUES (?, datetime('now', '-40 days'), ?, ?, ?)""",
                (None, "schedule", "run_maintenance", "success"),
            )
            conn.commit()
            before = conn.execute("SELECT COUNT(*) FROM automation_log").fetchone()[0]

        result = await _exec_run_maintenance({})
        assert "Maintenance" in result

        with get_connection() as conn:
            after = conn.execute("SELECT COUNT(*) FROM automation_log").fetchone()[0]

        assert after < before

    @pytest.mark.asyncio
    async def test_returns_summary_message(self, tmp_db):
        from backend.automation_engine import _exec_run_maintenance
        result = await _exec_run_maintenance({})
        assert "removed" in result.lower()
