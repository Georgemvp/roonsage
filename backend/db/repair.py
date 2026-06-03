"""Database corruption repair utilities for RoonSage."""

import logging
import re
import sqlite3

logger = logging.getLogger(__name__)


def repair_corrupt_indexes(conn: sqlite3.Connection) -> list[str]:
    """Run PRAGMA integrity_check and REINDEX any tables flagged as broken."""
    rows = conn.execute("PRAGMA integrity_check").fetchall()
    issues = [r[0] for r in rows if r[0] != "ok"]
    if not issues:
        return []

    logger.warning("SQLite integrity_check reported %d issue(s): %s",
                   len(issues), issues[:3])

    affected_tables: set[str] = set()
    for msg in issues:
        match = re.search(r"index\s+(\S+)", msg)
        if not match:
            continue
        index_name = match.group(1)
        tbl_row = conn.execute(
            "SELECT tbl_name FROM sqlite_master WHERE type='index' AND name=?",
            (index_name,),
        ).fetchone()
        if tbl_row:
            affected_tables.add(tbl_row[0])

    for tbl in affected_tables:
        logger.warning("Rebuilding indexes on table '%s' (corruption detected)", tbl)
        conn.execute(f"REINDEX {tbl}")
    conn.commit()

    rows2 = conn.execute("PRAGMA integrity_check").fetchall()
    issues_after = [r[0] for r in rows2 if r[0] != "ok"]
    if issues_after:
        logger.error(
            "SQLite integrity_check still failing after REINDEX: %s",
            issues_after[:3],
        )
    else:
        logger.info("SQLite integrity restored via REINDEX on: %s",
                    sorted(affected_tables))
    return sorted(affected_tables)
