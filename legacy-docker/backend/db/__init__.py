"""Database package for RoonSage — backwards-compatible re-exports."""

import sqlite3
import threading
from collections.abc import Generator
from contextlib import contextmanager

from backend.db.connection import (  # noqa: F401
    DATA_DIR,
    DB_PATH,
    _write_lock,
    aget_connection,
    execute_write,
    get_db_connection,
)
from backend.db.migrations import SCHEMA_VERSION, init_schema  # noqa: F401
from backend.db.repair import repair_corrupt_indexes  # noqa: F401

# Module-level schema state — accessed directly by tests via monkeypatch
_schema_initialized = False
_schema_lock = threading.Lock()
_migration_applied = False


def ensure_db_initialized() -> sqlite3.Connection:
    """Open a connection and initialize the schema exactly once per process."""
    global _schema_initialized, _migration_applied
    conn = get_db_connection()
    if not _schema_initialized:
        with _schema_lock:
            if not _schema_initialized:
                _migration_applied = init_schema(conn)
                _schema_initialized = True
    return conn


def needs_resync() -> bool:
    """Return True if a schema migration requires the library to be re-synced."""
    return _migration_applied


def clear_migration_flag() -> None:
    """Clear the migration flag after a successful library sync."""
    global _migration_applied
    _migration_applied = False


@contextmanager
def get_connection() -> Generator[sqlite3.Connection, None, None]:
    """Yield an initialized sync connection and close it on exit."""
    conn = ensure_db_initialized()
    try:
        yield conn
    finally:
        conn.close()
