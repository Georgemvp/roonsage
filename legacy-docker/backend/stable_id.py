"""Stable, content-based track identity.

Roon Browse ``item_key``s change across Core sessions, so they cannot key the
expensive derived tables (audio features, CLAP/lyrics embeddings, enrichment,
mood). ``stable_id`` is a deterministic hash of the normalised
``(artist, album, title, duration_bucket)`` tuple — it survives re-syncs, so a
full-replace of ``tracks`` no longer orphans computed data.

The normalisation MUST stay byte-for-byte stable: changing it shifts every id
and silently re-orphans all derived rows. ``STABLE_ID_VERSION`` is bumped only
on a deliberate, migration-backed change. The normalise/primary-artist helpers
mirror ``audio_features.path_resolver`` (which already content-matches tracks to
on-disk files), keeping a single definition of track identity.
"""

from __future__ import annotations

import hashlib
import re

from unidecode import unidecode

STABLE_ID_VERSION = 1

# 5-second duration buckets disambiguate distinct tracks that share
# artist/album/title (e.g. an album reissue with a bonus take of the same name).
_DURATION_BUCKET_SECONDS = 5


def normalise(text: str) -> str:
    """Lowercase + ASCII-fold + collapse to alphanumerics.

    Unlike ``path_resolver._normalise`` this deliberately does NOT strip
    parenthetical suffixes: a stable_id must stay *unique per recording*, so
    "Song (Piano Version)" and "Song (Guitar Version)" — which have different
    audio — must hash differently. (Collapsing versions is a cosmetic display
    concern handled separately in the UI dedupe, not an identity concern.)
    """
    if not text:
        return ""
    text = unidecode(text).lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return text.strip()


def primary_artist(artist: str) -> str:
    """Return the first artist in a multi-artist string ("Foo, Bar" -> "Foo")."""
    if not artist:
        return ""
    return artist.split(",")[0].split(";")[0].split("/")[0].split("&")[0].strip()


def compute_stable_id(
    artist: str | None,
    album: str | None,
    title: str | None,
    duration_ms: int | None = 0,
) -> str:
    """Deterministic content hash for a track. Stable across Roon sessions."""
    bucket = 0
    if duration_ms:
        bucket = round((duration_ms / 1000) / _DURATION_BUCKET_SECONDS)
    # Full (normalised) artist string, not just the primary artist: classical
    # recordings share composer+title+album and are only distinguished by the
    # performer/conductor later in the artist string. Roon returns a stable
    # artist string per file, so this stays consistent across sessions.
    parts = (
        normalise(artist or ""),
        normalise(album or ""),
        normalise(title or ""),
        str(bucket),
    )
    raw = "\x1f".join(parts)
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]
    return f"v{STABLE_ID_VERSION}:{digest}"
