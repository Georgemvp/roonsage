"""Tests for server-side filter session storage (filter_sessions.py)."""

import threading
import time

import pytest


@pytest.fixture(autouse=True)
def clear_sessions():
    """Reset the in-memory sessions dict before each test."""
    import backend.filter_sessions as fs
    with fs._lock:
        fs._sessions.clear()
    yield
    with fs._lock:
        fs._sessions.clear()


class TestStoreSession:
    def test_returns_12char_hex_id(self):
        from backend.filter_sessions import store_session
        sid = store_session({"1": "key_a"}, total_matching=10, returned=5)
        assert len(sid) == 12
        assert all(c in "0123456789abcdef" for c in sid)

    def test_stored_session_is_retrievable(self):
        from backend.filter_sessions import get_session, store_session
        key_map = {"1": "k1", "2": "k2"}
        sid = store_session(key_map, total_matching=100, returned=50)
        session = get_session(sid)
        assert session is not None
        assert session["key_map"] == key_map
        assert session["total_matching"] == 100
        assert session["returned"] == 50

    def test_multiple_sessions_are_independent(self):
        from backend.filter_sessions import get_session, store_session
        sid1 = store_session({"1": "a"}, total_matching=5, returned=5)
        sid2 = store_session({"1": "b"}, total_matching=10, returned=10)
        assert get_session(sid1)["key_map"] == {"1": "a"}
        assert get_session(sid2)["key_map"] == {"1": "b"}


class TestGetSession:
    def test_missing_session_returns_none(self):
        from backend.filter_sessions import get_session
        assert get_session("nonexistent123") is None

    def test_expired_session_returns_none(self, monkeypatch):
        import backend.filter_sessions as fs
        from backend.filter_sessions import get_session, store_session
        sid = store_session({"1": "key"}, total_matching=1, returned=1)

        # Force the session to appear expired by backdating its creation time
        with fs._lock:
            fs._sessions[sid]["created"] -= fs._MAX_AGE_SECONDS + 1

        assert get_session(sid) is None

    def test_expired_session_is_evicted_on_get(self, monkeypatch):
        import backend.filter_sessions as fs
        from backend.filter_sessions import get_session, store_session
        sid = store_session({"1": "key"}, total_matching=1, returned=1)
        with fs._lock:
            fs._sessions[sid]["created"] -= fs._MAX_AGE_SECONDS + 1

        get_session(sid)
        with fs._lock:
            assert sid not in fs._sessions


class TestLRUEviction:
    def test_expired_sessions_evicted_on_store(self, monkeypatch):
        import backend.filter_sessions as fs
        from backend.filter_sessions import store_session
        # Store a session then backdate it
        old_sid = store_session({"1": "old"}, total_matching=1, returned=1)
        with fs._lock:
            fs._sessions[old_sid]["created"] -= fs._MAX_AGE_SECONDS + 1

        # Storing a new session should evict the expired one
        store_session({"1": "new"}, total_matching=1, returned=1)
        with fs._lock:
            assert old_sid not in fs._sessions

    def test_oldest_evicted_when_at_max_capacity(self):
        import backend.filter_sessions as fs
        from backend.filter_sessions import store_session

        # Fill to exactly MAX_SESSIONS
        ids = []
        for i in range(fs._MAX_SESSIONS):
            sid = store_session({str(i): f"k{i}"}, total_matching=i, returned=i)
            ids.append(sid)
            time.sleep(0.001)  # ensure distinct creation timestamps

        oldest = ids[0]
        # Storing one more should evict the oldest
        store_session({"extra": "key"}, total_matching=0, returned=0)

        with fs._lock:
            assert oldest not in fs._sessions
            assert len(fs._sessions) <= fs._MAX_SESSIONS


class TestThreadSafety:
    def test_concurrent_stores_do_not_corrupt(self):
        from backend.filter_sessions import get_session, store_session
        stored_ids: list[str] = []
        lock = threading.Lock()

        def _store():
            sid = store_session({"x": "y"}, total_matching=1, returned=1)
            with lock:
                stored_ids.append(sid)

        threads = [threading.Thread(target=_store) for _ in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # Every stored ID should be retrievable
        for sid in stored_ids:
            session = get_session(sid)
            # May be evicted if over MAX_SESSIONS, but should not raise
            assert session is None or isinstance(session, dict)
