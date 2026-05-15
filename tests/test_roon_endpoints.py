"""Tests for new Roon API endpoints: volume, transfer, grouping, radio, playlists."""

import pytest
from unittest.mock import MagicMock, patch
from fastapi.testclient import TestClient


@pytest.fixture
def client():
    from backend.main import app
    return TestClient(app)


def _mock_roon(connected: bool = True, extra_attrs: dict | None = None):
    """Return a MagicMock roon_client stub."""
    m = MagicMock()
    m.is_connected.return_value = connected
    if extra_attrs:
        for k, v in extra_attrs.items():
            setattr(m, k, v)
    return m


# ---------------------------------------------------------------------------
# Transport control (extended: shuffle / repeat / seek)
# ---------------------------------------------------------------------------

class TestTransportControlExtended:

    def test_shuffle_toggle(self, client):
        roon = _mock_roon()
        roon.transport_control.return_value = {
            "success": True,
            "zone_name": "Woonkamer",
            "action": "shuffle",
            "state": "on",
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/transport", json={"zone_id": "z1", "action": "shuffle"})
        assert r.status_code == 200
        data = r.json()
        assert data["success"] is True
        assert data["action"] == "shuffle"

    def test_repeat_cycle(self, client):
        roon = _mock_roon()
        roon.transport_control.return_value = {
            "success": True,
            "zone_name": "Woonkamer",
            "action": "repeat",
            "state": "loop",
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/transport", json={
                "zone_id": "z1", "action": "repeat", "value": "cycle",
            })
        assert r.status_code == 200
        assert r.json()["state"] == "loop"

    def test_seek_absolute(self, client):
        roon = _mock_roon()
        roon.transport_control.return_value = {
            "success": True,
            "zone_name": "Woonkamer",
            "action": "seek",
            "state": "absolute:90s",
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/transport", json={
                "zone_id": "z1", "action": "seek", "position_seconds": 90,
            })
        assert r.status_code == 200
        assert "absolute" in r.json()["state"]

    def test_seek_relative(self, client):
        roon = _mock_roon()
        roon.transport_control.return_value = {
            "success": True,
            "zone_name": "Woonkamer",
            "action": "seek",
            "state": "relative:+30s",
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/transport", json={
                "zone_id": "z1", "action": "seek", "seek_offset": 30,
            })
        assert r.status_code == 200
        assert "relative" in r.json()["state"]

    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.roon.get_roon_client", return_value=_mock_roon(connected=False)):
            r = client.post("/api/roon/transport", json={"zone_id": "z1", "action": "play"})
        assert r.status_code == 503


# ---------------------------------------------------------------------------
# Volume control
# ---------------------------------------------------------------------------

class TestVolumeControl:

    def test_set_volume(self, client):
        roon = _mock_roon()
        roon.volume_control.return_value = {
            "success": True, "zone_name": "Keuken", "action": "set",
            "volume": 55, "is_muted": False,
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/volume", json={
                "zone_name": "Keuken", "action": "set", "value": 55,
            })
        assert r.status_code == 200
        assert r.json()["volume"] == 55

    def test_adjust_volume(self, client):
        roon = _mock_roon()
        roon.volume_control.return_value = {
            "success": True, "zone_name": "Keuken", "action": "adjust",
            "volume": 65, "is_muted": False,
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/volume", json={
                "zone_name": "Keuken", "action": "adjust", "value": 10,
            })
        assert r.status_code == 200

    def test_mute(self, client):
        roon = _mock_roon()
        roon.volume_control.return_value = {
            "success": True, "zone_name": "Keuken", "action": "mute",
            "volume": 55, "is_muted": True,
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/volume", json={"zone_name": "Keuken", "action": "mute"})
        assert r.status_code == 200
        assert r.json()["is_muted"] is True

    def test_get_volume(self, client):
        roon = _mock_roon()
        roon.volume_control.return_value = {
            "success": True, "zone_name": "Keuken", "action": "get",
            "volume": 40, "is_muted": False,
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/volume", json={"zone_name": "Keuken", "action": "get"})
        assert r.status_code == 200
        assert r.json()["volume"] == 40

    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.roon.get_roon_client", return_value=_mock_roon(connected=False)):
            r = client.post("/api/roon/volume", json={"zone_name": "Keuken", "action": "get"})
        assert r.status_code == 503


# ---------------------------------------------------------------------------
# Zone transfer
# ---------------------------------------------------------------------------

class TestZoneTransfer:

    def test_transfer_zone(self, client):
        roon = _mock_roon()
        roon.transfer_zone.return_value = {
            "success": True, "from_zone": "Woonkamer", "to_zone": "Slaapkamer",
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/transfer", json={
                "from_zone": "Woonkamer", "to_zone": "Slaapkamer",
            })
        assert r.status_code == 200
        data = r.json()
        assert data["from_zone"] == "Woonkamer"
        assert data["to_zone"] == "Slaapkamer"

    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.roon.get_roon_client", return_value=_mock_roon(connected=False)):
            r = client.post("/api/roon/transfer", json={"from_zone": "A", "to_zone": "B"})
        assert r.status_code == 503


# ---------------------------------------------------------------------------
# Zone grouping
# ---------------------------------------------------------------------------

class TestZoneGrouping:

    def test_list_groups(self, client):
        roon = _mock_roon()
        roon.zone_grouping.return_value = {
            "success": True, "action": "list_groups",
            "groups": [{"group_name": "Huis", "zones": ["Woonkamer", "Keuken"]}],
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/group", json={"action": "list_groups", "zones": []})
        assert r.status_code == 200
        assert len(r.json()["groups"]) == 1

    def test_group_zones(self, client):
        roon = _mock_roon()
        roon.zone_grouping.return_value = {
            "success": True, "action": "group",
            "groups": [{"zones": ["Woonkamer", "Keuken"]}],
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/group", json={
                "action": "group", "zones": ["Woonkamer", "Keuken"],
            })
        assert r.status_code == 200
        assert r.json()["action"] == "group"

    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.roon.get_roon_client", return_value=_mock_roon(connected=False)):
            r = client.post("/api/roon/group", json={"action": "list_groups", "zones": []})
        assert r.status_code == 503


# ---------------------------------------------------------------------------
# Play radio
# ---------------------------------------------------------------------------

class TestPlayRadio:

    def test_play_radio_success(self, client):
        roon = _mock_roon()
        roon.play_radio.return_value = {
            "success": True, "station_name": "NPO Radio 1", "zone_name": "Woonkamer",
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/radio", json={"station": "NPO Radio 1", "zone_id": "z1"})
        assert r.status_code == 200
        assert r.json()["station_name"] == "NPO Radio 1"

    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.roon.get_roon_client", return_value=_mock_roon(connected=False)):
            r = client.post("/api/roon/radio", json={"station": "BBC", "zone_id": "z1"})
        assert r.status_code == 503


# ---------------------------------------------------------------------------
# Browse playlists
# ---------------------------------------------------------------------------

class TestBrowsePlaylists:

    def test_list_playlists(self, client):
        roon = _mock_roon()
        roon.browse_playlists.return_value = {
            "success": True, "action": "list",
            "playlists": [
                {"name": "Mijn Favorieten", "subtitle": "20 tracks", "item_key": "pk1"},
                {"name": "Chill Vibes", "subtitle": "35 tracks", "item_key": "pk2"},
            ],
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/playlists", json={"action": "list"})
        assert r.status_code == 200
        data = r.json()
        assert len(data["playlists"]) == 2

    def test_play_playlist(self, client):
        roon = _mock_roon()
        roon.browse_playlists.return_value = {
            "success": True, "action": "play",
            "playlists": [{"name": "Chill Vibes"}],
            "zone_name": "Woonkamer",
        }
        with patch("backend.routes.roon.get_roon_client", return_value=roon):
            r = client.post("/api/roon/playlists", json={
                "action": "play", "playlist_name": "Chill Vibes", "zone_id": "z1",
            })
        assert r.status_code == 200
        assert r.json()["zone_name"] == "Woonkamer"

    def test_503_when_roon_disconnected(self, client):
        with patch("backend.routes.roon.get_roon_client", return_value=_mock_roon(connected=False)):
            r = client.post("/api/roon/playlists", json={"action": "list"})
        assert r.status_code == 503
