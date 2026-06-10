"""Tests for the cache-only discovery functions (discovery.py).

All tests use a temporary SQLite DB populated with minimal fixture data.
"""

import json
from datetime import UTC, datetime, timedelta

import pytest

import backend.db as _db
import backend.db.connection as _db_connection

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def tmp_db(tmp_path, monkeypatch):
    db_path = tmp_path / "test_discovery.db"
    monkeypatch.setattr(_db, "DB_PATH", db_path)
    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(_db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(_db, "_schema_initialized", False)

    from backend.db import ensure_db_initialized
    conn = ensure_db_initialized()
    conn.close()
    return db_path


def _get_conn():
    from backend.db import get_db_connection
    return get_db_connection()


def _insert_track(conn, item_key, title, artist, album="Album", is_live=0):
    conn.execute(
        """INSERT OR REPLACE INTO tracks (item_key, title, artist, album, is_live)
           VALUES (?, ?, ?, ?, ?)""",
        (item_key, title, artist, album, is_live),
    )


def _insert_album(conn, item_key, title, artist):
    conn.execute(
        """INSERT OR REPLACE INTO albums (item_key, title, artist)
           VALUES (?, ?, ?)""",
        (item_key, title, artist),
    )


def _insert_history(conn, artist, title, timestamp=None, skipped=0):
    ts = timestamp or datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
    conn.execute(
        """INSERT INTO listening_history (artist, track_title, timestamp, skipped)
           VALUES (?, ?, ?, ?)""",
        (artist, title, ts, skipped),
    )


# ---------------------------------------------------------------------------
# get_favorites_in_library
# ---------------------------------------------------------------------------

class TestGetFavoritesInLibrary:
    def test_returns_empty_with_no_data(self, tmp_db):
        from backend.discovery import get_favorites_in_library
        assert get_favorites_in_library() == []

    def test_returns_artists_by_play_count(self, tmp_db):
        from backend.discovery import get_favorites_in_library
        conn = _get_conn()
        try:
            _insert_album(conn, "album_rh", "The Bends", "Radiohead")
            _insert_album(conn, "album_pj", "Ten", "Pearl Jam")

            # Radiohead played 5×, Pearl Jam 2×
            for _ in range(5):
                _insert_history(conn, "Radiohead", "Fake Plastic Trees")
            for _ in range(2):
                _insert_history(conn, "Pearl Jam", "Black")
            conn.commit()
        finally:
            conn.close()

        results = get_favorites_in_library()
        assert len(results) >= 1
        artists = [r["artist"] for r in results]
        assert "Radiohead" in artists

    def test_returns_at_most_20_results(self, tmp_db):
        from backend.discovery import get_favorites_in_library
        conn = _get_conn()
        try:
            for i in range(50):
                artist = f"Artist{i:02d}"
                _insert_album(conn, f"alb{i}", f"Album {i}", artist)
                _insert_history(conn, artist, f"Track {i}")
            conn.commit()
        finally:
            conn.close()

        results = get_favorites_in_library()
        assert len(results) <= 20


# ---------------------------------------------------------------------------
# get_lb_top_releases_in_library
# ---------------------------------------------------------------------------

class TestGetLbTopReleasesInLibrary:
    def test_returns_empty_when_no_cache(self, tmp_db):
        from backend.discovery import get_lb_top_releases_in_library
        assert get_lb_top_releases_in_library() == []

    def test_matches_lb_release_to_library_album(self, tmp_db):
        from backend.discovery import get_lb_top_releases_in_library
        conn = _get_conn()
        try:
            _insert_album(conn, "ok_computer", "OK Computer", "Radiohead")
            # Write a fake lb_stats_cache top_releases entry
            releases = [
                {"artist_name": "Radiohead", "release_name": "OK Computer", "listen_count": 100}
            ]
            conn.execute(
                "INSERT OR REPLACE INTO lb_stats_cache (stat_type, data_json) VALUES (?, ?)",
                ("top_releases", json.dumps(releases)),
            )
            conn.commit()
        finally:
            conn.close()

        results = get_lb_top_releases_in_library()
        assert any(r["album"] == "OK Computer" for r in results)

    def test_strips_remastered_suffix(self, tmp_db):
        from backend.discovery import get_lb_top_releases_in_library
        conn = _get_conn()
        try:
            _insert_album(conn, "ok_clean", "OK Computer", "Radiohead")
            releases = [
                {
                    "artist_name": "Radiohead",
                    "release_name": "OK Computer (Remastered)",
                    "listen_count": 50,
                }
            ]
            conn.execute(
                "INSERT OR REPLACE INTO lb_stats_cache (stat_type, data_json) VALUES (?, ?)",
                ("top_releases", json.dumps(releases)),
            )
            conn.commit()
        finally:
            conn.close()

        results = get_lb_top_releases_in_library()
        assert any(r["album"] == "OK Computer" for r in results)


# ---------------------------------------------------------------------------
# get_lb_loved_in_library
# ---------------------------------------------------------------------------

class TestGetLbLovedInLibrary:
    def test_returns_empty_when_no_cache(self, tmp_db):
        from backend.discovery import get_lb_loved_in_library
        assert get_lb_loved_in_library() == []

    def test_matches_loved_track_in_library(self, tmp_db):
        from backend.discovery import get_lb_loved_in_library
        conn = _get_conn()
        try:
            _insert_track(conn, "creep_key", "Creep", "Radiohead")
            loved = [
                {"track_metadata": {"artist_name": "Radiohead", "track_name": "Creep"}}
            ]
            conn.execute(
                "INSERT OR REPLACE INTO lb_stats_cache (stat_type, data_json) VALUES (?, ?)",
                ("feedback_loved", json.dumps(loved)),
            )
            conn.commit()
        finally:
            conn.close()

        results = get_lb_loved_in_library()
        assert any(r["title"] == "Creep" for r in results)

    def test_excludes_live_tracks(self, tmp_db):
        from backend.discovery import get_lb_loved_in_library
        conn = _get_conn()
        try:
            _insert_track(conn, "creep_live", "Creep", "Radiohead", is_live=1)
            loved = [
                {"track_metadata": {"artist_name": "Radiohead", "track_name": "Creep"}}
            ]
            conn.execute(
                "INSERT OR REPLACE INTO lb_stats_cache (stat_type, data_json) VALUES (?, ?)",
                ("feedback_loved", json.dumps(loved)),
            )
            conn.commit()
        finally:
            conn.close()

        results = get_lb_loved_in_library()
        # is_live=1 should be filtered out
        assert not any(r["item_key"] == "creep_live" for r in results)


# ---------------------------------------------------------------------------
# get_deep_cuts
# ---------------------------------------------------------------------------

class TestGetDeepCuts:
    def test_returns_empty_with_no_data(self, tmp_db):
        from backend.discovery import get_deep_cuts
        assert get_deep_cuts() == []

    def test_returns_low_play_tracks_for_top_artist(self, tmp_db):
        from backend.discovery import get_deep_cuts
        conn = _get_conn()
        try:
            # Radiohead is a top artist (10 plays total)
            for i in range(10):
                _insert_history(conn, "Radiohead", f"Hit {i}")

            # This track has 0 plays — qualifies as deep cut
            _insert_track(conn, "deep_cut_key", "B-Side Track", "Radiohead")
            conn.commit()
        finally:
            conn.close()

        results = get_deep_cuts()
        assert any(r["title"] == "B-Side Track" for r in results)

    def test_excludes_live_tracks(self, tmp_db):
        from backend.discovery import get_deep_cuts
        conn = _get_conn()
        try:
            for i in range(10):
                _insert_history(conn, "Radiohead", f"Hit {i}")
            _insert_track(conn, "live_key", "Live B-Side", "Radiohead", is_live=1)
            conn.commit()
        finally:
            conn.close()

        results = get_deep_cuts()
        assert not any(r["item_key"] == "live_key" for r in results)


# ---------------------------------------------------------------------------
# get_forgotten_favorites
# ---------------------------------------------------------------------------

class TestGetForgottenFavorites:
    def test_returns_empty_with_no_data(self, tmp_db):
        from backend.discovery import get_forgotten_favorites
        assert get_forgotten_favorites() == []

    def test_returns_tracks_not_played_in_30_days(self, tmp_db):
        from backend.discovery import get_forgotten_favorites
        conn = _get_conn()
        try:
            old_ts = (datetime.now(UTC) - timedelta(days=60)).strftime("%Y-%m-%d %H:%M:%S")
            # 3+ plays but all >30 days ago
            for _ in range(3):
                _insert_history(conn, "Radiohead", "Creep", timestamp=old_ts)
            _insert_track(conn, "creep_key", "Creep", "Radiohead")
            conn.commit()
        finally:
            conn.close()

        results = get_forgotten_favorites()
        assert any(r["title"] == "Creep" for r in results)

    def test_excludes_recently_played(self, tmp_db):
        from backend.discovery import get_forgotten_favorites
        conn = _get_conn()
        try:
            recent_ts = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S")
            for _ in range(5):
                _insert_history(conn, "Radiohead", "Creep", timestamp=recent_ts)
            _insert_track(conn, "creep_key", "Creep", "Radiohead")
            conn.commit()
        finally:
            conn.close()

        results = get_forgotten_favorites()
        assert not any(r["title"] == "Creep" for r in results)


# ---------------------------------------------------------------------------
# get_genre_explorer
# ---------------------------------------------------------------------------

class TestGetGenreExplorer:
    def test_returns_empty_with_no_data(self, tmp_db):
        from backend.discovery import get_genre_explorer
        assert get_genre_explorer() == []

    def test_aggregates_genre_counts(self, tmp_db):
        from backend.discovery import get_genre_explorer
        conn = _get_conn()
        try:
            _insert_track(conn, "k1", "Song A", "Artist1")
            _insert_track(conn, "k2", "Song B", "Artist2")
            conn.execute("INSERT INTO track_genres (track_key, genre) VALUES ('k1', 'Rock')")
            conn.execute("INSERT INTO track_genres (track_key, genre) VALUES ('k2', 'Rock')")
            conn.execute("INSERT INTO track_genres (track_key, genre) VALUES ('k1', 'Jazz')")
            conn.commit()
        finally:
            conn.close()

        results = get_genre_explorer()
        genres = {r["genre"]: r for r in results}
        assert "Rock" in genres
        assert genres["Rock"]["artist_count"] == 2
        assert genres["Rock"]["track_count"] == 2
        assert "Jazz" in genres
        assert genres["Jazz"]["artist_count"] == 1
