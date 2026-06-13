"""Server-side key_map storage for filter_tracks sessions.

Keeps key_maps in memory with a 1-hour TTL so Claude's context window
doesn't have to carry the full map (~10-20k tokens per playlist request).
"""

import threading
import time
import uuid

_sessions: dict[str, dict] = {}
_lock = threading.Lock()

_MAX_AGE_SECONDS = 3600  # 1 hour
_MAX_SESSIONS = 50


def store_session(key_map: dict[str, str], total_matching: int, returned: int) -> str:
    """Store a key_map and return a session_id."""
    session_id = uuid.uuid4().hex[:12]
    with _lock:
        # Evict expired sessions
        now = time.time()
        expired = [k for k, v in _sessions.items() if now - v["created"] > _MAX_AGE_SECONDS]
        for k in expired:
            del _sessions[k]

        # Cap at MAX_SESSIONS — evict oldest when full
        while len(_sessions) >= _MAX_SESSIONS:
            oldest = min(_sessions, key=lambda k: _sessions[k]["created"])
            del _sessions[oldest]

        _sessions[session_id] = {
            "key_map": key_map,
            "total_matching": total_matching,
            "returned": returned,
            "created": now,
        }
    return session_id


def get_session(session_id: str) -> dict | None:
    """Retrieve a stored session. Returns None if expired or missing."""
    with _lock:
        session = _sessions.get(session_id)
        if not session:
            return None
        if time.time() - session["created"] > _MAX_AGE_SECONDS:
            del _sessions[session_id]
            return None
        return session
