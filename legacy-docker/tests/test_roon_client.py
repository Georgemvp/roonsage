"""Tests for Roon client (replaces legacy test_plex_client.py)."""

import time

from backend.models import Track
from backend.roon_client import TrackCache

# ---------------------------------------------------------------------------
# TrackCache tests — pure Python cache logic, no external dependencies
# ---------------------------------------------------------------------------


class TestTrackCache:
    """Tests for track caching functionality."""

    def _make_track(self, item_key: str, title: str = "Test Track") -> Track:
        """Helper to create a test track."""
        return Track(
            item_key=item_key,
            title=title,
            artist="Test Artist",
            album="Test Album",
            duration_ms=180000,
        )

    def test_cache_miss_returns_none(self):
        """Should return None for uncached filters."""
        cache = TrackCache()
        result = cache.get(["Rock"], ["1990s"], True, 0)
        assert result is None

    def test_cache_hit_returns_tracks(self):
        """Should return cached tracks for matching filters."""
        cache = TrackCache()
        tracks = [self._make_track("1"), self._make_track("2")]

        cache.set(["Rock"], ["1990s"], True, 0, tracks)
        result = cache.get(["Rock"], ["1990s"], True, 0)

        assert result is not None
        assert len(result) == 2
        assert result[0].item_key == "1"

    def test_cache_expired_returns_none(self):
        """Should return None for expired entries."""
        cache = TrackCache(ttl_seconds=0)  # Immediate expiration
        tracks = [self._make_track("1")]

        cache.set(["Rock"], ["1990s"], True, 0, tracks)
        time.sleep(0.01)  # Ensure TTL expires
        result = cache.get(["Rock"], ["1990s"], True, 0)

        assert result is None

    def test_different_filters_are_separate_entries(self):
        """Should cache separately for different filter combinations."""
        cache = TrackCache()
        rock_tracks = [self._make_track("1", "Rock Song")]
        jazz_tracks = [self._make_track("2", "Jazz Song")]

        cache.set(["Rock"], [], True, 0, rock_tracks)
        cache.set(["Jazz"], [], True, 0, jazz_tracks)

        rock_result = cache.get(["Rock"], [], True, 0)
        jazz_result = cache.get(["Jazz"], [], True, 0)

        assert rock_result[0].title == "Rock Song"
        assert jazz_result[0].title == "Jazz Song"

    def test_key_generation_is_consistent(self):
        """Should generate same key regardless of genre/decade order."""
        cache = TrackCache()
        tracks = [self._make_track("1")]

        # Set with one order
        cache.set(["Rock", "Alternative"], ["1990s", "2000s"], True, 0, tracks)

        # Get with different order - should still hit
        result = cache.get(["Alternative", "Rock"], ["2000s", "1990s"], True, 0)

        assert result is not None

    def test_max_entries_evicts_oldest(self):
        """Should evict oldest entry when at capacity."""
        cache = TrackCache(max_entries=2)

        cache.set(["Rock"], [], True, 0, [self._make_track("1")])
        time.sleep(0.01)
        cache.set(["Jazz"], [], True, 0, [self._make_track("2")])
        time.sleep(0.01)
        cache.set(["Pop"], [], True, 0, [self._make_track("3")])  # Should evict Rock

        assert cache.get(["Rock"], [], True, 0) is None  # Evicted
        assert cache.get(["Jazz"], [], True, 0) is not None
        assert cache.get(["Pop"], [], True, 0) is not None

    def test_clear_removes_all_entries(self):
        """Should remove all entries on clear."""
        cache = TrackCache()
        cache.set(["Rock"], [], True, 0, [self._make_track("1")])
        cache.set(["Jazz"], [], True, 0, [self._make_track("2")])

        cache.clear()

        assert cache.get(["Rock"], [], True, 0) is None
        assert cache.get(["Jazz"], [], True, 0) is None

    def test_updating_existing_key_does_not_evict(self):
        """Should not evict when updating an existing entry."""
        cache = TrackCache(max_entries=2)

        cache.set(["Rock"], [], True, 0, [self._make_track("1")])
        cache.set(["Jazz"], [], True, 0, [self._make_track("2")])

        # Update Rock - should not trigger eviction
        cache.set(["Rock"], [], True, 0, [self._make_track("1-updated")])

        assert cache.get(["Rock"], [], True, 0) is not None
        assert cache.get(["Jazz"], [], True, 0) is not None
