"""Live log viewer endpoints.

Backs the Settings → Logs page with a ring-buffered tail of recent log entries.
Polled from the frontend every ~1s (no WebSocket — keeps this dependency-free
and avoids backpressure handling complexity for a human-readable log stream).
"""

from __future__ import annotations

import logging
from collections import deque
from threading import Lock
from typing import Any

from fastapi import APIRouter, Query

router = APIRouter(prefix="/api/logs", tags=["logs"])


# ---------------------------------------------------------------------------
# Ring buffer + handler
# ---------------------------------------------------------------------------

_BUFFER_SIZE = 2000
_seq = 0
_seq_lock = Lock()
_buffer: deque[dict[str, Any]] = deque(maxlen=_BUFFER_SIZE)


def _next_seq() -> int:
    """Monotonic record id so the UI can ask for entries newer than seq=X."""
    global _seq
    with _seq_lock:
        _seq += 1
        return _seq


class RingBufferHandler(logging.Handler):
    """Push each formatted record into the in-memory ring buffer."""

    def emit(self, record: logging.LogRecord) -> None:
        try:
            entry = {
                "seq":    _next_seq(),
                "ts":     record.created,  # epoch seconds (UTC)
                "level":  record.levelname,
                "logger": record.name,
                "msg":    record.getMessage(),
            }
            if record.exc_info and record.exc_info[0]:
                entry["exception"] = logging.Formatter().formatException(record.exc_info)
            _buffer.append(entry)
        except Exception:
            self.handleError(record)


_handler_installed = False


def install_ring_handler() -> None:
    """Attach the ring-buffer handler to the root logger (idempotent)."""
    global _handler_installed
    if _handler_installed:
        return
    handler = RingBufferHandler(level=logging.DEBUG)
    logging.root.addHandler(handler)
    _handler_installed = True


# Install at import time. Auto-router-discovery imports this module during app
# init, which happens after setup_logging() in main.py — so this handler is
# added alongside the existing stderr JSONFormatter handler.
install_ring_handler()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

_LEVEL_RANK = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40, "CRITICAL": 50}


@router.get("/tail")
async def tail_logs(
    n:       int = Query(200, ge=1, le=_BUFFER_SIZE),
    level:   str = Query("DEBUG"),
    since:   int = Query(0, ge=0),
    logger_: str | None = Query(None, alias="logger"),
    q:       str | None = Query(None),
) -> dict[str, Any]:
    """Return the most recent buffered log entries.

    - `n`:      max entries returned (after filtering)
    - `level`:  minimum level (DEBUG=all, ERROR=errors+critical only)
    - `since`:  return only entries with seq > since (for incremental polling)
    - `logger`: filter by logger name substring
    - `q`:      filter message by case-insensitive substring
    """
    min_rank = _LEVEL_RANK.get(level.upper(), 0)
    needle = q.lower() if q else None

    snapshot = list(_buffer)
    selected: list[dict[str, Any]] = []
    for entry in snapshot:
        if entry["seq"] <= since:
            continue
        if _LEVEL_RANK.get(entry["level"], 0) < min_rank:
            continue
        if logger_ and logger_ not in entry["logger"]:
            continue
        if needle and needle not in entry["msg"].lower():
            continue
        selected.append(entry)

    return {
        "entries":  selected[-n:],
        "last_seq": snapshot[-1]["seq"] if snapshot else 0,
        "buffered": len(snapshot),
        "capacity": _BUFFER_SIZE,
    }


@router.get("/levels")
async def level_counts() -> dict[str, int]:
    """Count of buffered entries per level — for the filter chips."""
    counts: dict[str, int] = {}
    for entry in _buffer:
        counts[entry["level"]] = counts.get(entry["level"], 0) + 1
    return counts
