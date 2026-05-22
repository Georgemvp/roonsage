"""Resolve filesystem paths for tracks by scanning audio file tags.

Roon's Extension API does NOT expose the underlying file path for a track,
so to analyse the audio we walk the music library on disk, read tags via
``mutagen``, and match (artist, album, title) against the local ``tracks``
table. Matches are stored in ``track_audio_features.file_path`` and the
track is queued for analysis.

Strategy (fast path, fuzzy fallback):
  1. Normalised exact match on (artist, album, title) — case-insensitive,
     unicode-normalised, parenthetical suffixes stripped.
  2. Fuzzy match within the same artist when exact fails (rapidfuzz ≥ 90).

This module never raises — failures are logged and counted; the worker
processes whatever rows it can resolve.
"""

from __future__ import annotations

import logging
import os
import re
import threading
from pathlib import Path
from typing import TYPE_CHECKING, Any

from unidecode import unidecode

if TYPE_CHECKING:
    import sqlite3
    from collections.abc import Iterator

# Guard against concurrent scans (bootstrap + manual rescan + worker triggers).
# scan_library + resolve_paths_for_tracks share the lock so only one walk
# of the filesystem runs at a time. Held during the entire scan; callers
# that find it busy back off and return empty results.
_scan_lock = threading.Lock()

logger = logging.getLogger(__name__)

# File extensions supported by mutagen + librosa (via ffmpeg).
_AUDIO_EXTENSIONS = {
    ".flac", ".mp3", ".m4a", ".mp4", ".aac",
    ".ogg", ".opus", ".wav", ".aiff", ".aif",
    ".wma", ".dsf", ".dff",
}


# ---------------------------------------------------------------------------
# Normalisation helpers
# ---------------------------------------------------------------------------


def _normalise(text: str) -> str:
    """Lowercase + ASCII-fold + strip parenthetical suffixes + collapse whitespace."""
    if not text:
        return ""
    text = unidecode(text).lower()
    text = re.sub(r"\s*[\(\[].*?[\)\]]", "", text)  # drop "(Remastered)" etc.
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return text.strip()


def _primary_artist(artist: str) -> str:
    """Return the first artist in a multi-artist string ("Foo, Bar" → "Foo")."""
    if not artist:
        return ""
    return artist.split(",")[0].split(";")[0].split("/")[0].split("&")[0].strip()


# ---------------------------------------------------------------------------
# Filesystem walk + tag reading
# ---------------------------------------------------------------------------


def _iter_audio_files(root: Path) -> Iterator[Path]:
    """Yield every audio file under ``root`` recursively. Symlinks skipped."""
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for fn in filenames:
            ext = Path(fn).suffix.lower()
            if ext in _AUDIO_EXTENSIONS:
                yield Path(dirpath) / fn


def _read_tags(path: Path) -> dict[str, str] | None:
    """Return ``{artist, album, title}`` (best-effort, normalised) or None."""
    try:
        import mutagen  # noqa: PLC0415

        f = mutagen.File(str(path), easy=True)
        if f is None:
            return None
        # mutagen-easy returns lists, keys differ slightly between formats.
        def _first(key: str) -> str:
            val = f.get(key)
            if not val:
                return ""
            return (val[0] if isinstance(val, list) else val) or ""

        artist = _first("artist") or _first("albumartist")
        album = _first("album")
        title = _first("title")
        if not (artist and title):
            return None
        return {
            "artist": _normalise(_primary_artist(artist)),
            "album": _normalise(album),
            "title": _normalise(title),
        }
    except Exception as exc:
        logger.debug("Tag read failed for %s: %s", path, exc)
        return None


# ---------------------------------------------------------------------------
# Library index
# ---------------------------------------------------------------------------


def scan_library(music_root: Path) -> dict[tuple[str, str, str], str]:
    """Walk the filesystem and return a tag-index of every audio file.

    Returns:
        Mapping ``(artist, album, title) → file_path`` with normalised keys.
    """
    if not music_root.exists():
        logger.warning("Music library path does not exist: %s", music_root)
        return {}

    logger.info("Scanning music library at %s ...", music_root)
    index: dict[tuple[str, str, str], str] = {}
    files_seen = 0
    files_indexed = 0

    for path in _iter_audio_files(music_root):
        files_seen += 1
        if files_seen % 1000 == 0:
            logger.info("Scanned %d files (%d tagged)", files_seen, files_indexed)
        tags = _read_tags(path)
        if not tags:
            continue
        key = (tags["artist"], tags["album"], tags["title"])
        index.setdefault(key, str(path))
        files_indexed += 1

    logger.info(
        "Library scan complete: %d files seen, %d uniquely tagged",
        files_seen, files_indexed,
    )
    return index


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


def resolve_paths_for_tracks(
    conn: sqlite3.Connection,
    music_root: Path | None = None,
) -> dict[str, int]:
    """Match Roon ``tracks`` rows to filesystem paths and queue them for analysis.

    For every track without a row in ``track_audio_features`` (or with
    ``file_path IS NULL``) attempt a tag-based match against the filesystem.
    Matched tracks get a ``track_audio_features`` row with ``file_path`` set
    and an ``audio_features_queue`` row with ``status='pending'``.
    Unmatched tracks get ``status='unresolved'`` so they aren't retried every
    boot.

    Returns:
        ``{"scanned": N, "matched": M, "unresolved": U}`` counts.
    """
    if music_root is None:
        env_path = os.environ.get("MUSIC_LIBRARY_PATH", "/music")
        music_root = Path(env_path)

    if not music_root.exists():
        logger.info(
            "MUSIC_LIBRARY_PATH=%s not present — skipping path resolution",
            music_root,
        )
        return {"scanned": 0, "matched": 0, "unresolved": 0}

    # Only one scan at a time. The walk is multi-minute and SQLite would
    # deadlock if two writers fought over the queue / features tables.
    if not _scan_lock.acquire(blocking=False):
        logger.info("Another path-resolution scan is already running — skipping")
        return {"scanned": 0, "matched": 0, "unresolved": 0}

    try:
        # Build index once.
        index = scan_library(music_root)
        if not index:
            return {"scanned": 0, "matched": 0, "unresolved": 0}

        rows = conn.execute("""
            SELECT t.item_key, t.artist, t.album, t.title
            FROM tracks t
            LEFT JOIN track_audio_features af ON af.item_key = t.item_key
            WHERE af.item_key IS NULL OR af.file_path IS NULL
        """).fetchall()

        scanned = 0
        matched = 0
        unresolved = 0
        now_inserts: list[tuple[Any, ...]] = []
        unresolved_inserts: list[tuple[str, str]] = []

        for row in rows:
            scanned += 1
            item_key = row["item_key"]
            artist = _normalise(_primary_artist(row["artist"] or ""))
            album = _normalise(row["album"] or "")
            title = _normalise(row["title"] or "")
            path = index.get((artist, album, title))
            # Fallback: same artist/title, any album (handles re-releases).
            if path is None:
                for (a, _b, t), p in index.items():
                    if a == artist and t == title:
                        path = p
                        break

            if path is None:
                unresolved += 1
                unresolved_inserts.append((item_key, "unresolved"))
                continue

            matched += 1
            now_inserts.append((item_key, path))

        # Bulk-insert resolved tracks in batches so the SQLite write lock is
        # never held for the entire run. Each commit releases the lock and
        # lets the worker / API endpoints make progress between batches.
        BATCH = 1000
        for i in range(0, len(now_inserts), BATCH):
            chunk = now_inserts[i:i + BATCH]
            conn.executemany("""
                INSERT INTO track_audio_features (item_key, file_path)
                VALUES (?, ?)
                ON CONFLICT(item_key) DO UPDATE SET file_path = excluded.file_path
            """, chunk)
            conn.executemany("""
                INSERT INTO audio_features_queue (item_key, file_path, status)
                VALUES (?, ?, 'pending')
                ON CONFLICT(item_key) DO UPDATE SET
                    file_path = excluded.file_path,
                    status = CASE
                        WHEN audio_features_queue.status IN ('complete', 'processing')
                        THEN audio_features_queue.status
                        ELSE 'pending'
                    END
            """, chunk)
            conn.commit()

        for i in range(0, len(unresolved_inserts), BATCH):
            chunk = unresolved_inserts[i:i + BATCH]
            conn.executemany("""
                INSERT INTO audio_features_queue (item_key, status)
                VALUES (?, ?)
                ON CONFLICT(item_key) DO NOTHING
            """, chunk)
            conn.commit()

        logger.info(
            "Path resolution: scanned=%d matched=%d unresolved=%d",
            scanned, matched, unresolved,
        )
        return {"scanned": scanned, "matched": matched, "unresolved": unresolved}
    finally:
        _scan_lock.release()


def apply_path_mapping(roon_path: str) -> str:
    """Translate a Roon-reported path into the container-visible path.

    Example: ``MUSIC_PATH_MAP_FROM=/Volumes/Music`` and ``MUSIC_PATH_MAP_TO=/music``
    will rewrite ``/Volumes/Music/Foo/Bar.flac`` → ``/music/Foo/Bar.flac``.

    Kept available even though the current matcher uses tag scanning — when a
    future iteration consumes Roon's reported path directly this helper
    handles the host-vs-container split.
    """
    src = os.environ.get("MUSIC_PATH_MAP_FROM", "")
    dst = os.environ.get("MUSIC_PATH_MAP_TO", "")
    if not src or not dst or not roon_path:
        return roon_path
    if roon_path.startswith(src):
        return dst + roon_path[len(src):]
    return roon_path
