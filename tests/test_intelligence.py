"""Tests for the RoonSage intelligence layer.

Covers:
- TasteProfile CRUD (get, update, add_event, get_recent_events)
- Weighted merge logic
- Listening history logging (via RoonIntelligenceMixin)
- Saved playlists CRUD (via FastAPI test client)
- Profile computation from history
- Browse tags (mocked Roon Browse API)
"""

import json
import sqlite3
import threading
from pathlib import Path
from typing import Generator
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def tmp_db(tmp_path: Path) -> Generator[Path, None, None]:
    """Create a fresh SQLite database with the full intelligence schema."""
    db_path = tmp_path / "test_intelligence.db"

    # Patch DB_PATH so all modules use our temp db
    with patch("backend.db.DB_PATH", db_path), \
         patch("backend.db.DATA_DIR", tmp_path), \
         patch("backend.db._schema_initialized", False):

        from backend.db import get_db_connection, init_schema
        conn = get_db_connection.__wrapped__(db_path) if hasattr(get_db_connection, "__wrapped__") else sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        init_schema(conn)
        conn.close()

        yield db_path


@pytest.fixture()
def patched_db(tmp_db: Path):
    """Patch all DB access to use the temporary database."""
    import backend.db as db_module

    def fake_get_db():
        conn = sqlite3.connect(str(tmp_db), timeout=30.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    with patch.object(db_module, "get_db_connection", fake_get_db), \
         patch("backend.taste_profile._get_conn", fake_get_db):
        yield fake_get_db


# ---------------------------------------------------------------------------
# TasteProfile — basic CRUD
# ---------------------------------------------------------------------------


class TestTasteProfileGet:
    def test_get_returns_dict(self, patched_db):
        from backend.taste_profile import TasteProfile
        profile = TasteProfile.get()
        assert isinstance(profile, dict)

    def test_get_has_required_keys(self, patched_db):
        from backend.taste_profile import TasteProfile
        profile = TasteProfile.get()
        for key in ("genres", "decades", "artists", "moods", "dislikes", "notes", "stats"):
            assert key in profile, f"Missing key: {key}"

    def test_get_empty_on_fresh_db(self, patched_db):
        from backend.taste_profile import TasteProfile
        profile = TasteProfile.get()
        assert profile["genres"] == {}
        assert profile["dislikes"] == []
        assert profile["notes"] == []


class TestTasteProfileUpdate:
    def test_update_adds_genres(self, patched_db):
        from backend.taste_profile import TasteProfile
        new = TasteProfile.update({"genres": {"Jazz": 0.8, "Rock": 0.6}})
        assert "Jazz" in new["genres"]
        assert abs(new["genres"]["Jazz"] - 0.8) < 0.01

    def test_update_weighted_merge(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.update({"genres": {"Jazz": 0.8}})
        TasteProfile.update({"genres": {"Jazz": 0.2}})  # should blend, not replace
        profile = TasteProfile.get()
        # With weight=0.3: 0.8 * 0.7 + 0.2 * 0.3 = 0.56 + 0.06 = 0.62
        assert 0.5 < profile["genres"]["Jazz"] < 0.8

    def test_update_appends_dislikes(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.update({"dislikes": ["christmas"]})
        TasteProfile.update({"dislikes": ["karaoke"]})
        profile = TasteProfile.get()
        assert "christmas" in profile["dislikes"]
        assert "karaoke" in profile["dislikes"]

    def test_update_deduplicates_dislikes(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.update({"dislikes": ["christmas"]})
        TasteProfile.update({"dislikes": ["christmas", "CHRISTMAS"]})  # case-insensitive dup
        profile = TasteProfile.get()
        lowercase = [d.lower() for d in profile["dislikes"]]
        assert lowercase.count("christmas") == 1

    def test_update_appends_notes(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.update({"notes": ["prefers vinyl-era production"]})
        profile = TasteProfile.get()
        assert any("vinyl" in n for n in profile["notes"])

    def test_update_sets_last_updated(self, patched_db):
        from backend.taste_profile import TasteProfile
        profile = TasteProfile.update({"genres": {"Electronic": 0.7}})
        assert "last_updated" in profile.get("stats", {})

    def test_update_clamps_scores(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.update({"genres": {"Jazz": 1.5}})  # above 1.0
        profile = TasteProfile.get()
        assert profile["genres"]["Jazz"] <= 1.0

    def test_update_persists_across_calls(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.update({"artists": {"Radiohead": 0.9}})
        profile = TasteProfile.get()
        assert "Radiohead" in profile["artists"]


class TestTasteProfileEvents:
    def test_add_event_stores_row(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.add_event("playlist_created", {"name": "Test Playlist"})
        events = TasteProfile.get_recent_events(limit=5)
        assert len(events) >= 1
        assert events[0]["event_type"] == "playlist_created"

    def test_get_recent_events_newest_first(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.add_event("playlist_created", {"name": "First"})
        TasteProfile.add_event("playlist_rated", {"rating": 5})
        events = TasteProfile.get_recent_events(limit=10)
        # Newest first (playlist_rated was added last)
        assert events[0]["event_type"] == "playlist_rated"

    def test_get_recent_events_respects_limit(self, patched_db):
        from backend.taste_profile import TasteProfile
        for i in range(10):
            TasteProfile.add_event("feedback", {"i": i})
        events = TasteProfile.get_recent_events(limit=3)
        assert len(events) == 3

    def test_event_data_is_preserved(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.add_event("playlist_rated", {"rating": 4, "name": "My Jazz Set"})
        events = TasteProfile.get_recent_events(limit=1)
        assert events[0]["data"]["rating"] == 4
        assert events[0]["data"]["name"] == "My Jazz Set"


# ---------------------------------------------------------------------------
# TasteProfile — compute_profile_from_history
# ---------------------------------------------------------------------------


class TestComputeProfileFromHistory:
    def _insert_listens(self, db_path: Path, listens: list[dict]):
        conn = sqlite3.connect(str(db_path))
        for listen in listens:
            conn.execute(
                """INSERT INTO listening_history
                   (zone_name, track_title, artist, album, genre, duration_seconds, played_seconds, skipped)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    listen.get("zone_name", "Living Room"),
                    listen.get("track_title", "Unknown"),
                    listen.get("artist", ""),
                    listen.get("album", ""),
                    listen.get("genre", ""),
                    listen.get("duration_seconds", 240),
                    listen.get("played_seconds", 240),
                    listen.get("skipped", 0),
                ),
            )
        conn.commit()
        conn.close()

    def test_compute_extracts_top_genre(self, patched_db, tmp_db):
        listens = [
            {"artist": "Miles Davis", "genre": "Jazz", "played_seconds": 240},
            {"artist": "Coltrane", "genre": "Jazz", "played_seconds": 200},
            {"artist": "Boards of Canada", "genre": "Electronic", "played_seconds": 240},
        ]
        self._insert_listens(tmp_db, listens)

        from backend.taste_profile import TasteProfile
        profile = TasteProfile.compute_profile_from_history()
        assert "Jazz" in profile["genres"]
        # Jazz should rank higher than Electronic (2 vs 1 plays)
        assert profile["genres"].get("Jazz", 0) >= profile["genres"].get("Electronic", 0)

    def test_compute_handles_empty_history(self, patched_db):
        from backend.taste_profile import TasteProfile
        profile = TasteProfile.compute_profile_from_history()
        # Should return a valid profile even with no history
        assert isinstance(profile, dict)
        assert "genres" in profile

    def test_compute_counts_playlists(self, patched_db):
        from backend.taste_profile import TasteProfile
        TasteProfile.add_event("playlist_created", {"name": "A"})
        TasteProfile.add_event("playlist_created", {"name": "B"})
        profile = TasteProfile.compute_profile_from_history()
        assert profile["stats"]["total_playlists"] == 2


# ---------------------------------------------------------------------------
# Listening history — RoonIntelligenceMixin._log_listen
# ---------------------------------------------------------------------------


class TestListeningHistoryLogging:
    def test_log_listen_inserts_row(self, patched_db, tmp_db):
        from backend.roon_intelligence import RoonIntelligenceMixin

        mixin = RoonIntelligenceMixin()
        track_info = {
            "title": "Blue in Green",
            "artist": "Miles Davis",
            "album": "Kind of Blue",
            "genre": "Jazz",
            "duration": 337,
        }
        mixin._log_listen(track_info, played_seconds=300, skipped=0, zone_name="Living Room")

        conn = sqlite3.connect(str(tmp_db))
        rows = conn.execute("SELECT * FROM listening_history").fetchall()
        conn.close()

        assert len(rows) == 1
        row = rows[0]
        assert row[3] == "Blue in Green"  # track_title
        assert row[4] == "Miles Davis"    # artist
        assert row[8] == 300              # played_seconds
        assert row[9] == 0               # skipped

    def test_log_listen_marks_skipped(self, patched_db, tmp_db):
        from backend.roon_intelligence import RoonIntelligenceMixin

        mixin = RoonIntelligenceMixin()
        mixin._log_listen(
            {"title": "Test", "artist": "X", "album": "", "genre": "", "duration": 240},
            played_seconds=20,  # < 30s → skipped
            skipped=1,
            zone_name="Kitchen",
        )
        conn = sqlite3.connect(str(tmp_db))
        row = conn.execute("SELECT skipped FROM listening_history").fetchone()
        conn.close()
        assert row[0] == 1

    def test_process_zone_change_detects_track_change(self, patched_db, tmp_db):
        """Simulate two consecutive track changes and verify the first is logged."""
        from backend.roon_intelligence import RoonIntelligenceMixin

        mixin = RoonIntelligenceMixin()
        mixin._last_zone_states = {}

        zone_playing_a = {
            "state": "playing",
            "display_name": "Living Room",
            "now_playing": {
                "three_line": {"line1": "Song A", "line2": "Artist A", "line3": "Album A"},
                "length": 240,
            },
        }
        zone_playing_b = {
            "state": "playing",
            "display_name": "Living Room",
            "now_playing": {
                "three_line": {"line1": "Song B", "line2": "Artist B", "line3": "Album B"},
                "length": 200,
            },
        }

        # First: start playing Song A
        mixin._process_zone_change("zone1", zone_playing_a)
        assert "zone1" in mixin._last_zone_states
        assert mixin._last_zone_states["zone1"]["title"] == "Song A"

        # Simulate time passing
        mixin._last_zone_states["zone1"]["started_at"] -= 60  # 60s ago

        # Second: Song B starts → Song A should be logged
        mixin._process_zone_change("zone1", zone_playing_b)

        conn = sqlite3.connect(str(tmp_db))
        rows = conn.execute("SELECT track_title, artist FROM listening_history").fetchall()
        conn.close()

        assert len(rows) == 1
        assert rows[0][0] == "Song A"
        assert rows[0][1] == "Artist A"


# ---------------------------------------------------------------------------
# Saved playlists — via FastAPI TestClient
# ---------------------------------------------------------------------------


@pytest.fixture()
def api_client(patched_db):
    """FastAPI TestClient with intelligence router mounted."""
    from fastapi import FastAPI
    from backend.routes.intelligence import router

    app = FastAPI()
    app.include_router(router)
    return TestClient(app)


class TestSavedPlaylistsAPI:
    def test_list_empty(self, api_client):
        resp = api_client.get("/api/playlists/saved")
        assert resp.status_code == 200
        assert resp.json() == []

    def test_save_and_list(self, api_client):
        payload = {
            "name": "Test Jazz Playlist",
            "prompt": "Jazz for a rainy evening",
            "tracks_json": json.dumps([
                {"item_key": "k1", "title": "So What", "artist": "Miles Davis", "album": "Kind of Blue"},
                {"item_key": "k2", "title": "Autumn Leaves", "artist": "Bill Evans", "album": "Portrait"},
            ]),
            "source_mode": "library",
            "tags": "avond,jazz",
        }
        save_resp = api_client.post("/api/playlists/saved", json=payload)
        assert save_resp.status_code == 200
        data = save_resp.json()
        assert data["status"] == "saved"
        assert data["track_count"] == 2
        pid = data["playlist_id"]

        list_resp = api_client.get("/api/playlists/saved")
        assert list_resp.status_code == 200
        playlists = list_resp.json()
        assert len(playlists) == 1
        assert playlists[0]["id"] == pid
        assert playlists[0]["name"] == "Test Jazz Playlist"

    def test_save_and_get_tracks(self, api_client):
        tracks = [{"item_key": "k1", "title": "Mood Indigo", "artist": "Ellington", "album": "X"}]
        save_resp = api_client.post("/api/playlists/saved", json={
            "name": "Ellington Set",
            "prompt": "Duke Ellington classics",
            "tracks_json": json.dumps(tracks),
            "source_mode": "library",
            "tags": "",
        })
        pid = save_resp.json()["playlist_id"]

        get_resp = api_client.get(f"/api/playlists/saved/{pid}/tracks")
        assert get_resp.status_code == 200
        body = get_resp.json()
        assert body["track_count"] == 1
        assert body["tracks"][0]["title"] == "Mood Indigo"

    def test_update_rating(self, api_client):
        save_resp = api_client.post("/api/playlists/saved", json={
            "name": "Evening Vibes", "prompt": "", "tracks_json": "[]",
            "source_mode": "library", "tags": "",
        })
        assert save_resp.status_code == 200
        pid = save_resp.json()["playlist_id"]

        # The PUT endpoint now returns the new rating in the response body
        upd_resp = api_client.put(f"/api/playlists/saved/{pid}", json={"rating": 5})
        assert upd_resp.status_code == 200
        body = upd_resp.json()
        assert body.get("rating") == 5, f"Expected rating=5 in PUT response, got: {body}"

    def test_update_invalid_rating_rejected(self, api_client):
        save_resp = api_client.post("/api/playlists/saved", json={
            "name": "X", "prompt": "", "tracks_json": "[]",
            "source_mode": "library", "tags": "",
        })
        pid = save_resp.json()["playlist_id"]
        resp = api_client.put(f"/api/playlists/saved/{pid}", json={"rating": 7})
        assert resp.status_code == 400

    def test_delete_playlist(self, api_client):
        save_resp = api_client.post("/api/playlists/saved", json={
            "name": "To Delete", "prompt": "", "tracks_json": "[]",
            "source_mode": "library", "tags": "",
        })
        pid = save_resp.json()["playlist_id"]

        del_resp = api_client.delete(f"/api/playlists/saved/{pid}")
        assert del_resp.status_code == 200

        playlists = api_client.get("/api/playlists/saved").json()
        assert all(p["id"] != pid for p in playlists)

    def test_delete_nonexistent_returns_404(self, api_client):
        resp = api_client.delete("/api/playlists/saved/99999")
        assert resp.status_code == 404

    def test_filter_by_tag(self, api_client):
        api_client.post("/api/playlists/saved", json={
            "name": "Road Trip", "prompt": "", "tracks_json": "[]",
            "source_mode": "library", "tags": "roadtrip,auto",
        })
        api_client.post("/api/playlists/saved", json={
            "name": "Evening Jazz", "prompt": "", "tracks_json": "[]",
            "source_mode": "library", "tags": "avond,jazz",
        })

        resp = api_client.get("/api/playlists/saved?tag=roadtrip")
        assert resp.status_code == 200
        playlists = resp.json()
        assert len(playlists) == 1
        assert playlists[0]["name"] == "Road Trip"


# ---------------------------------------------------------------------------
# Taste Profile API endpoints
# ---------------------------------------------------------------------------


class TestTasteProfileAPI:
    def test_get_profile_endpoint(self, api_client):
        resp = api_client.get("/api/taste/profile")
        assert resp.status_code == 200
        data = resp.json()
        assert "genres" in data

    def test_update_profile_endpoint(self, api_client):
        resp = api_client.post("/api/taste/profile", json={
            "updates": {"genres": {"Jazz": 0.8}, "dislikes": ["christmas"]}
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "Jazz" in data["genres"]
        assert "christmas" in data["dislikes"]

    def test_log_event_endpoint(self, api_client):
        resp = api_client.post("/api/taste/event", json={
            "event_type": "playlist_rated",
            "data": {"rating": 5, "name": "Evening Set"},
        })
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_get_events_endpoint(self, api_client):
        api_client.post("/api/taste/event", json={"event_type": "feedback", "data": {"note": "test"}})
        resp = api_client.get("/api/taste/events?limit=5")
        assert resp.status_code == 200
        events = resp.json()
        assert len(events) >= 1


# ---------------------------------------------------------------------------
# Listening history API
# ---------------------------------------------------------------------------


class TestListeningHistoryAPI:
    def test_get_empty_history(self, api_client):
        resp = api_client.get("/api/listening/history")
        assert resp.status_code == 200
        assert resp.json() == []

    def test_get_stats_empty(self, api_client):
        resp = api_client.get("/api/listening/stats")
        assert resp.status_code == 200
        data = resp.json()
        assert data["total_tracks"] == 0
        assert data["skip_rate_pct"] == 0.0


# ---------------------------------------------------------------------------
# Browse tags — mock Roon Browse API
# ---------------------------------------------------------------------------


class TestBrowseTags:
    def test_get_tags_via_api_no_roon(self, api_client):
        """When Roon is not connected, endpoint returns 503."""
        # The route uses a lazy import inside the function body, so patch via roon_client module
        with patch("backend.roon_client.get_roon_client", return_value=None):
            resp = api_client.get("/api/roon/tags")
        assert resp.status_code == 503

    def test_get_tags_returns_list(self, api_client):
        """Mock a connected Roon client that returns tags."""
        mock_client = MagicMock()
        mock_client.is_connected.return_value = True
        mock_client.get_tags.return_value = [
            {"title": "Chill", "item_key": "key_chill"},
            {"title": "Road Trip", "item_key": "key_roadtrip"},
            {"title": "Workout", "item_key": "key_workout"},
        ]

        with patch("backend.roon_client.get_roon_client", return_value=mock_client):
            resp = api_client.get("/api/roon/tags")

        assert resp.status_code == 200
        tags = resp.json()
        assert len(tags) == 3
        assert any(t["title"] == "Chill" for t in tags)

    def test_browse_tags_mixin_parses_browse_response(self):
        """Unit-test the mixin's Browse API navigation logic."""
        from backend.roon_intelligence import RoonIntelligenceMixin

        mixin = RoonIntelligenceMixin()
        mixin._browse_lock = threading.Lock()

        # _paginate_browse_load lives in RoonBrowseMixin — mock it on the instance
        def fake_paginate(hierarchy):
            return [
                {"title": "Chill", "item_key": "chill_key"},
                {"title": "Focus", "item_key": "focus_key"},
            ]
        mixin._paginate_browse_load = fake_paginate

        # Build a mock _api that returns structured browse responses
        mock_api = MagicMock()
        mock_api.browse_load.side_effect = [
            # Root page
            {"items": [
                {"title": "Library", "item_key": "lib_key"},
                {"title": "Playlists", "item_key": "pl_key"},
            ]},
            # Library sub-items
            {"items": [
                {"title": "Albums", "item_key": "albums_key"},
                {"title": "Tags", "item_key": "tags_key"},
            ]},
        ]
        mixin._api = mock_api

        with mixin._browse_lock:
            tags = mixin._browse_tags_locked()

        assert len(tags) == 2
        assert tags[0]["title"] == "Chill"
        assert tags[0]["item_key"] == "chill_key"
        assert tags[1]["title"] == "Focus"


# ---------------------------------------------------------------------------
# Thread safety
# ---------------------------------------------------------------------------


class TestThreadSafety:
    def test_concurrent_profile_updates(self, patched_db):
        """Multiple threads updating the profile should not corrupt data."""
        from backend.taste_profile import TasteProfile

        errors = []

        def update_worker(genre: str, score: float):
            try:
                TasteProfile.update({"genres": {genre: score}})
            except Exception as exc:
                errors.append(exc)

        threads = [
            threading.Thread(target=update_worker, args=(f"Genre{i}", 0.5 + i * 0.01))
            for i in range(10)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors, f"Thread errors: {errors}"
        profile = TasteProfile.get()
        assert len(profile["genres"]) == 10
