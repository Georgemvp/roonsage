"""Database connection helpers for RoonSage."""

from __future__ import annotations

import logging
import os
import sqlite3
import threading
from contextlib import asynccontextmanager
from pathlib import Path

import aiosqlite

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# The SQLite DB lives in ROONSAGE_DB_DIR when set, otherwise alongside the rest
# of the data dir. On macOS + Docker Desktop, keep this on a *named volume*
# (inside the Linux VM) rather than a bind mount: SQLite WAL over the macOS
# file-sharing layer corrupts the database under heavy writes.
DATA_DIR = Path(os.environ.get("ROONSAGE_DB_DIR") or (Path(__file__).parent.parent.parent / "data"))
DB_PATH = DATA_DIR / "library_cache.db"

# ---------------------------------------------------------------------------
# Write lock
# ---------------------------------------------------------------------------

_write_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------


def get_db_connection() -> sqlite3.Connection:
    """Open a WAL-mode SQLite connection with dict-like row access."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(DB_PATH), timeout=30.0)
    conn.row_factory = sqlite3.Row

    # WAL mode: concurrent readers during writes.
    # After a crash or force-kill the -shm (WAL index) can be left in an
    # inconsistent state, causing "database disk image is malformed" on the
    # first PRAGMA journal_mode=WAL of a new connection.
    # Recovery: switch to DELETE journal mode first (doesn't use SHM), which
    # checkpoints and removes the WAL/SHM files, then reopen in WAL mode.
    # As last resort, delete the stale SHM/WAL files directly.
    try:
        conn.execute("PRAGMA journal_mode=WAL")
    except sqlite3.DatabaseError:
        logger.warning("WAL header inconsistent; attempting journal reset recovery")
        try:
            conn.execute("PRAGMA journal_mode=DELETE")
        except Exception as exc:
            logger.warning("journal_mode=DELETE failed: %s", exc)
        conn.close()
        shm_path = DB_PATH.parent / (DB_PATH.name + "-shm")
        wal_path = DB_PATH.parent / (DB_PATH.name + "-wal")
        for p in (shm_path, wal_path):
            if p.exists():
                try:
                    p.unlink()
                    logger.info("Removed stale WAL artefact: %s", p.name)
                except OSError as exc:
                    logger.warning("Could not remove %s: %s", p.name, exc)
        conn = sqlite3.connect(str(DB_PATH), timeout=30.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")

    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")

    return conn


@asynccontextmanager
async def aget_connection():
    """Async context manager that yields an aiosqlite connection.

    Moves SQLite I/O off the event-loop thread via aiosqlite's internal
    thread executor. Schema must already be initialised (ensure_db_initialized
    is called at startup before any route handler runs).

    Usage::

        async with aget_connection() as conn:
            cursor = await conn.execute("SELECT ...")
            rows   = await cursor.fetchall()
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(str(DB_PATH), timeout=30.0) as conn:
        conn.row_factory = aiosqlite.Row
        await conn.execute("PRAGMA journal_mode=WAL")
        await conn.execute("PRAGMA busy_timeout=5000")
        await conn.execute("PRAGMA foreign_keys=ON")
        yield conn


async def execute_write(query: str, params: tuple | list | None = None) -> None:
    """Run a single write statement on an aiosqlite connection."""
    async with aget_connection() as conn:
        await conn.execute(query, params or ())
        await conn.commit()
