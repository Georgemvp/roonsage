"""SQLite-backed cache for LLM generation responses.

Used by ``backend.generator`` (playlist generation) and
``backend.recommender`` (album selection) to skip provider calls when the
same prompt / system / model combination is requested within the
configured TTL window.

Cache keys are SHA-256 hashes of a canonical JSON encoding of the request
parameters that influence the LLM output:

* the full user prompt (which already encodes filters and the track pool
  the model sees), and
* the system prompt, and
* the model name (so a smart_generation toggle invalidates the entry).

The cache is best-effort: any database error is logged and the caller
falls back to the live LLM call.
"""

import hashlib
import json
import logging
import sqlite3
import time
from typing import Any

from backend.db import get_db_connection
from backend.llm_client import LLMResponse

logger = logging.getLogger(__name__)


def make_cache_key(
    prompt: str,
    system: str,
    model: str,
    extras: dict[str, Any] | None = None,
) -> str:
    """Compute a deterministic cache key for an LLM request.

    Args:
        prompt: The full user prompt sent to the model.
        system: The system prompt sent to the model.
        model: Model name (e.g. ``"claude-haiku-4-5"``).
        extras: Optional extra fields to mix into the hash. Useful when
            the caller wants to namespace entries beyond what the prompt
            text already encodes.

    Returns:
        Hex-encoded SHA-256 digest (64 chars).
    """
    payload = json.dumps(
        {
            "prompt": prompt,
            "system": system,
            "model": model,
            "extras": extras or {},
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def get_cached(cache_key: str, ttl_seconds: int) -> LLMResponse | None:
    """Return a cached :class:`LLMResponse` or ``None`` if missing/expired.

    Expired entries are deleted on read. Returned responses report 0
    tokens so cost reporting reflects that no provider call occurred.
    """
    if ttl_seconds <= 0:
        return None

    now = int(time.time())
    cutoff = now - ttl_seconds

    try:
        conn = get_db_connection()
    except sqlite3.Error as exc:
        logger.warning("llm_cache get_cached: db connect failed: %s", exc)
        return None

    try:
        row = conn.execute(
            "SELECT content, model, created_at "
            "FROM llm_response_cache WHERE cache_key = ?",
            (cache_key,),
        ).fetchone()

        if row is None:
            return None

        if row["created_at"] < cutoff:
            conn.execute(
                "DELETE FROM llm_response_cache WHERE cache_key = ?",
                (cache_key,),
            )
            conn.commit()
            return None

        conn.execute(
            "UPDATE llm_response_cache SET hit_count = hit_count + 1 "
            "WHERE cache_key = ?",
            (cache_key,),
        )
        conn.commit()

        return LLMResponse(
            content=row["content"],
            input_tokens=0,
            output_tokens=0,
            model=row["model"],
        )
    except sqlite3.Error as exc:
        logger.warning("llm_cache get_cached: query failed: %s", exc)
        return None
    finally:
        conn.close()


def set_cached(cache_key: str, kind: str, response: LLMResponse) -> None:
    """Persist an :class:`LLMResponse` under ``cache_key``.

    Args:
        cache_key: Hex digest from :func:`make_cache_key`.
        kind: Free-form label (``"playlist"``, ``"album_selection"`` …)
            for diagnostics — does not affect lookup.
        response: The response to store. Empty content is skipped to
            avoid memoising obvious failures.
    """
    if not response.content or not response.content.strip():
        return

    now = int(time.time())

    try:
        conn = get_db_connection()
    except sqlite3.Error as exc:
        logger.warning("llm_cache set_cached: db connect failed: %s", exc)
        return

    try:
        conn.execute(
            "INSERT OR REPLACE INTO llm_response_cache "
            "(cache_key, kind, content, model, input_tokens, output_tokens, "
            " created_at, hit_count) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 0)",
            (
                cache_key,
                kind,
                response.content,
                response.model,
                response.input_tokens,
                response.output_tokens,
                now,
            ),
        )
        conn.commit()
    except sqlite3.Error as exc:
        logger.warning("llm_cache set_cached: insert failed: %s", exc)
    finally:
        conn.close()


def purge_expired(ttl_seconds: int) -> int:
    """Delete entries older than ``ttl_seconds``. Returns the row count."""
    if ttl_seconds <= 0:
        return 0

    cutoff = int(time.time()) - ttl_seconds

    try:
        conn = get_db_connection()
    except sqlite3.Error as exc:
        logger.warning("llm_cache purge_expired: db connect failed: %s", exc)
        return 0

    try:
        cur = conn.execute(
            "DELETE FROM llm_response_cache WHERE created_at < ?",
            (cutoff,),
        )
        conn.commit()
        return cur.rowcount or 0
    except sqlite3.Error as exc:
        logger.warning("llm_cache purge_expired: delete failed: %s", exc)
        return 0
    finally:
        conn.close()


def clear_cache(kind: str | None = None) -> int:
    """Remove all cached entries, optionally restricted to a ``kind``."""
    try:
        conn = get_db_connection()
    except sqlite3.Error as exc:
        logger.warning("llm_cache clear_cache: db connect failed: %s", exc)
        return 0

    try:
        if kind is None:
            cur = conn.execute("DELETE FROM llm_response_cache")
        else:
            cur = conn.execute(
                "DELETE FROM llm_response_cache WHERE kind = ?", (kind,)
            )
        conn.commit()
        return cur.rowcount or 0
    except sqlite3.Error as exc:
        logger.warning("llm_cache clear_cache: delete failed: %s", exc)
        return 0
    finally:
        conn.close()


def get_stats() -> dict[str, Any]:
    """Return diagnostics: total entries, per-kind counts, total hits."""
    try:
        conn = get_db_connection()
    except sqlite3.Error as exc:
        logger.warning("llm_cache get_stats: db connect failed: %s", exc)
        return {"total": 0, "per_kind": {}, "total_hits": 0}

    try:
        total_row = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(hit_count), 0) AS hits "
            "FROM llm_response_cache"
        ).fetchone()
        per_kind = {
            row["kind"]: row["n"]
            for row in conn.execute(
                "SELECT kind, COUNT(*) AS n FROM llm_response_cache GROUP BY kind"
            ).fetchall()
        }
        return {
            "total": total_row["n"],
            "per_kind": per_kind,
            "total_hits": total_row["hits"],
        }
    except sqlite3.Error as exc:
        logger.warning("llm_cache get_stats: query failed: %s", exc)
        return {"total": 0, "per_kind": {}, "total_hits": 0}
    finally:
        conn.close()
