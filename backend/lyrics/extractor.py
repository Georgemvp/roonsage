"""Pull embedded lyrics from common audio container tags.

Supports:
* MP3 (ID3v2 ``USLT`` frames; first one wins).
* FLAC + OGG-Vorbis (``LYRICS`` Vorbis comment).
* M4A / MP4 (``©lyr`` atom).

Returns ``None`` when no lyrics are embedded. Bare ``mutagen`` calls — no
network, no scraping.
"""

from __future__ import annotations

import logging
from pathlib import Path

logger = logging.getLogger(__name__)


def extract_lyrics(audio_path: str | Path) -> str | None:
    """Return embedded lyrics text, or None if the file has none."""
    path = Path(audio_path)
    if not path.exists():
        return None

    suffix = path.suffix.lower()
    try:
        if suffix == ".mp3":
            return _extract_mp3(path)
        if suffix in {".flac", ".ogg", ".opus"}:
            return _extract_vorbis(path)
        if suffix in {".m4a", ".mp4", ".aac"}:
            return _extract_mp4(path)
        # Fall back: try mutagen's auto-detection.
        return _extract_generic(path)
    except Exception as exc:
        logger.debug("lyrics extract failed for %s: %s", path, exc)
        return None


def _extract_mp3(path: Path) -> str | None:
    from mutagen.id3 import ID3, ID3NoHeaderError  # noqa: PLC0415

    try:
        tags = ID3(str(path))
    except ID3NoHeaderError:
        return None
    for frame in tags.getall("USLT"):
        text = (frame.text or "").strip()
        if text:
            return text
    # Some encoders use SYLT (synced lyrics); flatten timestamps out.
    for frame in tags.getall("SYLT"):
        text = " ".join(t for _, t in (frame.text or []) if t)
        if text:
            return text
    return None


def _extract_vorbis(path: Path) -> str | None:
    from mutagen import File  # noqa: PLC0415

    audio = File(str(path))
    if audio is None or not hasattr(audio, "tags") or audio.tags is None:
        return None
    for key in ("LYRICS", "UNSYNCEDLYRICS", "lyrics"):
        vals = audio.tags.get(key)
        if vals:
            text = "\n".join(v for v in vals if v).strip()
            if text:
                return text
    return None


def _extract_mp4(path: Path) -> str | None:
    from mutagen.mp4 import MP4  # noqa: PLC0415

    audio = MP4(str(path))
    vals = audio.tags.get("©lyr") if audio.tags else None
    if vals:
        text = "\n".join(v for v in vals if v).strip()
        return text or None
    return None


def _extract_generic(path: Path) -> str | None:
    from mutagen import File  # noqa: PLC0415

    audio = File(str(path))
    if audio is None:
        return None
    for attr in ("USLT", "LYRICS", "©lyr"):
        try:
            vals = audio.tags.get(attr) if audio.tags else None
        except Exception:
            vals = None
        if not vals:
            continue
        if isinstance(vals, list):
            text = "\n".join(str(v) for v in vals if v).strip()
        else:
            text = str(vals).strip()
        if text:
            return text
    return None
