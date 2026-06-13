"""Tests for the audio_features path resolver.

Avoids real audio files by monkey-patching ``mutagen.File`` and the
filesystem walker so we can drive the matcher with synthetic tag data.
"""

from pathlib import Path
from unittest.mock import patch

import pytest

from backend.audio_features import path_resolver


def test_normalise_strips_unicode_and_parentheticals():
    assert path_resolver._normalise("Café (Remastered 2011)") == "cafe"
    assert path_resolver._normalise("BJÖRK") == "bjork"
    assert path_resolver._normalise("") == ""


def test_primary_artist_handles_multi_artist_strings():
    assert path_resolver._primary_artist("Radiohead") == "Radiohead"
    assert path_resolver._primary_artist("Lennon, McCartney") == "Lennon"
    assert path_resolver._primary_artist("Foo & Bar") == "Foo"
    assert path_resolver._primary_artist("") == ""


def test_apply_path_mapping_rewrites_prefix(monkeypatch):
    monkeypatch.setenv("MUSIC_PATH_MAP_FROM", "/Volumes/Music")
    monkeypatch.setenv("MUSIC_PATH_MAP_TO", "/music")
    assert (
        path_resolver.apply_path_mapping("/Volumes/Music/Foo/Bar.flac")
        == "/music/Foo/Bar.flac"
    )


def test_apply_path_mapping_passthrough_when_unmapped(monkeypatch):
    monkeypatch.setenv("MUSIC_PATH_MAP_FROM", "")
    monkeypatch.setenv("MUSIC_PATH_MAP_TO", "")
    assert path_resolver.apply_path_mapping("/foo/bar.flac") == "/foo/bar.flac"


class _FakeMutagenFile(dict):
    """Mimics ``mutagen.File(path, easy=True)`` minimal interface."""


def _patch_mutagen(monkeypatch, tag_lookup: dict[str, dict[str, list[str]]]):
    """Make ``mutagen.File`` return our fake tag dict per path."""

    class _MutagenModule:
        @staticmethod
        def File(path, easy=True):  # noqa: N802 — match real signature
            tags = tag_lookup.get(str(path))
            if tags is None:
                return None
            return _FakeMutagenFile(tags)

    monkeypatch.setattr(path_resolver, "_AUDIO_EXTENSIONS",
                        path_resolver._AUDIO_EXTENSIONS | {".dummy"})
    import sys
    monkeypatch.setitem(sys.modules, "mutagen", _MutagenModule)


def test_scan_library_indexes_tags(tmp_path: Path, monkeypatch):
    f1 = tmp_path / "a.flac"
    f1.write_bytes(b"x")
    f2 = tmp_path / "sub" / "b.mp3"
    f2.parent.mkdir()
    f2.write_bytes(b"x")
    f3 = tmp_path / "note.txt"  # ignored extension
    f3.write_text("nope")

    _patch_mutagen(monkeypatch, {
        str(f1): {"artist": ["Radiohead"], "album": ["The Bends"], "title": ["Fake Plastic Trees"]},
        str(f2): {"artist": ["Pearl Jam"], "album": ["Ten"], "title": ["Black"]},
    })

    index = path_resolver.scan_library(tmp_path)
    assert ("radiohead", "the bends", "fake plastic trees") in index
    assert ("pearl jam", "ten", "black") in index
    # txt file is skipped, so index size is exactly 2.
    assert len(index) == 2


def test_scan_library_missing_root_returns_empty(tmp_path):
    missing = tmp_path / "nope"
    assert path_resolver.scan_library(missing) == {}


def test_resolve_paths_matches_and_queues(tmp_path: Path, monkeypatch):
    """End-to-end: tracks table + on-disk index → feature row + queue row."""
    import sqlite3

    f1 = tmp_path / "fake_plastic_trees.flac"
    f1.write_bytes(b"x")
    f2 = tmp_path / "unknown.flac"
    f2.write_bytes(b"x")

    _patch_mutagen(monkeypatch, {
        str(f1): {"artist": ["Radiohead"], "album": ["The Bends"], "title": ["Fake Plastic Trees"]},
        str(f2): {"artist": ["Random"], "album": ["Whatever"], "title": ["Nothing"]},
    })

    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript("""
        CREATE TABLE tracks (item_key TEXT PRIMARY KEY, artist TEXT, album TEXT, title TEXT);
        CREATE TABLE track_audio_features (
            item_key TEXT PRIMARY KEY, file_path TEXT, bpm REAL
        );
        CREATE TABLE audio_features_queue (
            item_key TEXT PRIMARY KEY, file_path TEXT, status TEXT, attempts INTEGER DEFAULT 0,
            error_message TEXT, created_at TEXT, processed_at TEXT
        );
        INSERT INTO tracks VALUES
            ('1', 'Radiohead', 'The Bends', 'Fake Plastic Trees'),
            ('2', 'Pearl Jam', 'Ten', 'Black');  -- not on disk
    """)
    conn.commit()

    with patch.object(path_resolver, "scan_library",
                      return_value={
                          ("radiohead", "the bends", "fake plastic trees"): str(f1),
                      }):
        result = path_resolver.resolve_paths_for_tracks(conn, tmp_path)

    assert result["scanned"] == 2
    assert result["matched"] == 1
    assert result["unresolved"] == 1

    matched = conn.execute(
        "SELECT file_path FROM track_audio_features WHERE item_key='1'"
    ).fetchone()
    assert matched["file_path"] == str(f1)

    queued = conn.execute(
        "SELECT status FROM audio_features_queue WHERE item_key='1'"
    ).fetchone()
    assert queued["status"] == "pending"

    unresolved = conn.execute(
        "SELECT status FROM audio_features_queue WHERE item_key='2'"
    ).fetchone()
    assert unresolved["status"] == "unresolved"


def test_resolve_paths_skip_when_music_root_missing(tmp_path, monkeypatch):
    import sqlite3
    conn = sqlite3.connect(":memory:")
    result = path_resolver.resolve_paths_for_tracks(conn, tmp_path / "does_not_exist")
    assert result == {"scanned": 0, "matched": 0, "unresolved": 0}


@pytest.mark.parametrize("artist,album,title", [
    ("Radiohead", "The Bends", "Fake Plastic Trees"),
    ("RADIOHEAD", "the BENDS", "FAKE PLASTIC TREES"),
])
def test_resolve_paths_normalises_case(artist, album, title, tmp_path, monkeypatch):
    """Roon and tag-side casing should not affect matching."""
    import sqlite3
    f1 = tmp_path / "x.flac"
    f1.write_bytes(b"x")

    _patch_mutagen(monkeypatch, {
        str(f1): {"artist": [artist], "album": [album], "title": [title]},
    })

    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript("""
        CREATE TABLE tracks (item_key TEXT PRIMARY KEY, artist TEXT, album TEXT, title TEXT);
        CREATE TABLE track_audio_features (item_key TEXT PRIMARY KEY, file_path TEXT, bpm REAL);
        CREATE TABLE audio_features_queue (
            item_key TEXT PRIMARY KEY, file_path TEXT, status TEXT, attempts INTEGER DEFAULT 0,
            error_message TEXT, created_at TEXT, processed_at TEXT
        );
        INSERT INTO tracks VALUES ('1', 'Radiohead', 'The Bends', 'Fake Plastic Trees');
    """)
    conn.commit()

    with patch.object(path_resolver, "scan_library",
                      return_value={
                          (path_resolver._normalise(artist),
                           path_resolver._normalise(album),
                           path_resolver._normalise(title)): str(f1),
                      }):
        result = path_resolver.resolve_paths_for_tracks(conn, tmp_path)

    assert result["matched"] == 1
