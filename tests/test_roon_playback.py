"""Tests for RoonPlaybackMixin — focusing on zone listing, track matching,
and the synthetic qobuz_search:: key detection in play_tracks."""

import threading
from unittest.mock import MagicMock, patch

import pytest

from backend.models import RoonResponse


# ---------------------------------------------------------------------------
# Minimal concrete class that satisfies the mixin's self.* references
# ---------------------------------------------------------------------------

class FakeRoonClient:
    """Minimal stub that instantiates RoonPlaybackMixin without the full client."""

    def __init__(self, *, connected: bool = True):
        from backend.roon_playback import RoonPlaybackMixin
        # Mixin methods are grafted directly as unbound functions; we need to
        # inherit properly — so we build an ad-hoc subclass.
        RoonPlaybackMixin.__init__(self)  # no-op (mixin has no __init__)
        self._connected = connected
        self._api = MagicMock()
        self._browse_lock = threading.Lock()

    def is_connected(self) -> bool:
        return self._connected

    # Graft mixin methods
    from backend.roon_playback import RoonPlaybackMixin as _m
    get_zones = _m.get_zones
    _get_track_metadata_batch = _m._get_track_metadata_batch
    _find_best_track_match = _m._find_best_track_match
    _play_track_via_search = _m._play_track_via_search
    _play_track_via_direct_key = _m._play_track_via_direct_key
    play_tracks = _m.play_tracks


def _make_client(*, connected: bool = True) -> FakeRoonClient:
    return FakeRoonClient(connected=connected)


# ---------------------------------------------------------------------------
# get_zones
# ---------------------------------------------------------------------------

class TestGetZones:
    def test_returns_empty_when_disconnected(self):
        client = _make_client(connected=False)
        assert client.get_zones() == []

    def test_returns_zone_list_when_connected(self):
        client = _make_client(connected=True)
        client._api.zones = {
            "z1": {
                "display_name": "Living Room",
                "state": "playing",
                "outputs": [{"display_name": "Amp"}],
            }
        }
        zones = client.get_zones()
        assert len(zones) == 1
        assert zones[0].zone_id == "z1"
        assert zones[0].display_name == "Living Room"
        assert zones[0].state == "playing"
        assert zones[0].is_grouped is False

    def test_grouped_zone_flagged(self):
        client = _make_client()
        client._api.zones = {
            "z2": {
                "display_name": "Group",
                "state": "stopped",
                "outputs": [{"display_name": "A"}, {"display_name": "B"}],
            }
        }
        assert client.get_zones()[0].is_grouped is True

    def test_exception_in_api_returns_empty(self):
        client = _make_client()
        client._api.zones = None  # will raise TypeError on iteration
        # The mixin must not propagate; return []
        result = client.get_zones()
        assert result == []


# ---------------------------------------------------------------------------
# _find_best_track_match
# ---------------------------------------------------------------------------

class TestFindBestTrackMatch:
    def _make_items(self, entries):
        """Convert list of (title, subtitle, hint) tuples to item dicts."""
        return [
            {"title": t, "subtitle": s, "hint": h, "item_key": f"key_{i}"}
            for i, (t, s, h) in enumerate(entries)
        ]

    def test_returns_none_when_no_playable_items(self):
        client = _make_client()
        items = self._make_items([("Creep", "Radiohead", "list")])  # hint=list, not playable
        result = client._find_best_track_match(items, "Creep", "Radiohead")
        assert result is None

    def test_returns_best_match(self):
        client = _make_client()
        items = self._make_items([
            ("Completely Different Song", "Other Artist", "action"),
            ("Creep", "Radiohead", "action"),
        ])
        result = client._find_best_track_match(items, "Creep", "Radiohead")
        assert result is not None
        assert result["title"] == "Creep"

    def test_falls_back_to_first_playable_when_no_good_match(self):
        client = _make_client()
        items = self._make_items([
            ("XXXXXXXXXX", "YYYYYY", "action"),
        ])
        # Threshold likely not met but should fall back to first playable
        result = client._find_best_track_match(items, "My Song", "My Artist")
        assert result is not None


# ---------------------------------------------------------------------------
# play_tracks — high-level dispatch
# ---------------------------------------------------------------------------

class TestPlayTracks:
    def test_returns_error_when_disconnected(self):
        client = _make_client(connected=False)
        result = client.play_tracks("zone1", ["key1"])
        assert result.success is False
        assert "Not connected" in (result.error or "")

    def test_returns_error_when_no_keys(self):
        client = _make_client()
        result = client.play_tracks("zone1", [])
        assert result.success is False

    def test_synthetic_key_triggers_search(self):
        """qobuz_search::<artist>::<title> must call _play_track_via_search, not direct browse."""
        import urllib.parse
        client = _make_client()
        artist = urllib.parse.quote("Miles Davis")
        title = urllib.parse.quote("So What")
        key = f"qobuz_search::{artist}::{title}"

        search_calls: list[tuple] = []

        def fake_search(zone_id, query, exp_title, exp_artist, target_kw, fallback_kw):
            search_calls.append((zone_id, query, exp_title, exp_artist))
            return True  # report success so play_tracks counts it

        client._play_track_via_search = fake_search

        with patch.object(client, "_get_track_metadata_batch", return_value={}):
            result = client.play_tracks("zone1", [key])

        assert len(search_calls) == 1
        zone, query, exp_title, exp_artist = search_calls[0]
        assert exp_artist == "Miles Davis"
        assert exp_title == "So What"

    def test_regular_key_tries_direct_browse_first(self):
        """Non-synthetic keys must go through _play_track_via_direct_key first."""
        client = _make_client()
        direct_calls: list[str] = []

        def fake_direct(zone_id, key, target_kw, fallback_kw):
            direct_calls.append(key)
            return True

        client._play_track_via_direct_key = fake_direct

        with patch.object(
            client,
            "_get_track_metadata_batch",
            return_value={"real_key": {"title": "Creep", "artist": "Radiohead"}},
        ):
            client.play_tracks("zone1", ["real_key"])

        assert "real_key" in direct_calls

    def test_synthetic_key_does_not_call_direct_browse(self):
        """Direct-browse must NOT be called for synthetic qobuz keys."""
        import urllib.parse
        client = _make_client()
        direct_calls: list[str] = []

        def fake_direct(zone_id, key, target_kw, fallback_kw):
            direct_calls.append(key)
            return True

        client._play_track_via_direct_key = fake_direct
        client._play_track_via_search = MagicMock(return_value=True)

        key = f"qobuz_search::{urllib.parse.quote('Artist')}::{urllib.parse.quote('Title')}"
        with patch.object(client, "_get_track_metadata_batch", return_value={}):
            client.play_tracks("zone1", [key])

        assert direct_calls == []

    def test_queue_reversal_in_replace_mode(self):
        """In replace mode with >1 track, tracks 2–N are reversed so Roon's
        prepend-queue delivers them in the original order."""
        client = _make_client()
        queued_order: list[str] = []

        def fake_direct(zone_id, key, target_kw, fallback_kw):
            queued_order.append(key)
            return True

        client._play_track_via_direct_key = fake_direct
        meta = {f"k{i}": {"title": f"Track {i}", "artist": "A"} for i in range(3)}

        with patch.object(client, "_get_track_metadata_batch", return_value=meta):
            client.play_tracks("zone1", ["k0", "k1", "k2"], mode="replace")

        # First key stays first; remainder reversed
        assert queued_order[0] == "k0"
        assert queued_order[1:] == ["k2", "k1"]
