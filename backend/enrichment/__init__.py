"""Modular enrichment sources — registry-based, SoulSync-style.

Each source plugin implements an async ``lookup(artist, title) -> SourceResult``
function.  The orchestrator in ``enrichment_worker`` continues to use the
inline MusicBrainz + Last.fm calls for raw throughput; this package adds a
sidecar registry that powers:

  * the per-source manual-match preview UI
  * the audit endpoint listing which sources contributed to each track
  * future drop-in additions (Discogs, AudioDB, Genius) without touching the
    worker loop.

Sources are intentionally tiny — a single ``lookup`` callable plus metadata.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any


@dataclass
class SourceResult:
    """The normalised payload every source must return.

    ``tags`` is the only required field; other keys are best-effort. ``raw``
    holds the source-specific response for debugging / advanced UIs.
    """

    source: str
    tags: list[str] = field(default_factory=list)
    mbid: str | None = None
    release_date: str | None = None
    country: str | None = None
    listeners: int | None = None
    playcount: int | None = None
    raw: dict[str, Any] | None = None
    error: str | None = None


SourceLookup = Callable[[str, str], Awaitable[SourceResult]]


@dataclass
class Source:
    """A registered enrichment source.

    ``enabled_check`` lets a source declare itself unavailable at runtime (no
    API key, feature flag off, …) so the registry doesn't hand the user a
    broken "manual match" preview button.
    """

    name: str
    label: str
    description: str
    lookup: SourceLookup
    enabled_check: Callable[[], bool] = field(default=lambda: True)


_REGISTRY: dict[str, Source] = {}


def register(source: Source) -> Source:
    """Register a source; later calls overwrite, useful for tests."""
    _REGISTRY[source.name] = source
    return source


def get(name: str) -> Source | None:
    return _REGISTRY.get(name)


def list_sources() -> list[Source]:
    return list(_REGISTRY.values())


def list_enabled() -> list[Source]:
    return [s for s in _REGISTRY.values() if _safe_enabled(s)]


def _safe_enabled(source: Source) -> bool:
    try:
        return bool(source.enabled_check())
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Default registrations — wired here so a single import primes the registry.
# ---------------------------------------------------------------------------


async def _lookup_musicbrainz(artist: str, title: str) -> SourceResult:
    """Thin adapter around backend.musicbrainz_client.lookup_recording."""
    try:
        from backend.musicbrainz_client import get_mb_client  # noqa: PLC0415

        client = get_mb_client()
        mbid, tags, release_date, country = await client.lookup_recording(
            artist, title, fetch_tags=True
        )
        return SourceResult(
            source="musicbrainz",
            tags=tags or [],
            mbid=mbid,
            release_date=release_date,
            country=country,
        )
    except Exception as exc:  # fail-open: never raise
        return SourceResult(source="musicbrainz", error=str(exc))


def _mb_enabled() -> bool:
    from backend.config import get_enrichment_skip_mb  # noqa: PLC0415

    return not get_enrichment_skip_mb()


async def _lookup_lastfm(artist: str, title: str) -> SourceResult:
    """Thin adapter around the existing LF helper in enrichment_worker."""
    try:
        from backend.enrichment_worker import _fetch_lastfm  # noqa: PLC0415

        tags, listeners, playcount = await _fetch_lastfm(artist, title)
        return SourceResult(
            source="lastfm",
            tags=list(tags or []),
            listeners=listeners,
            playcount=playcount,
        )
    except Exception as exc:
        return SourceResult(source="lastfm", error=str(exc))


def _lf_enabled() -> bool:
    from backend.lastfm_client import get_lf_client  # noqa: PLC0415

    client = get_lf_client()
    return bool(client and client.is_configured())


register(
    Source(
        name="musicbrainz",
        label="MusicBrainz",
        description="Recording lookup + community tags (1 req/s).",
        lookup=_lookup_musicbrainz,
        enabled_check=_mb_enabled,
    )
)

register(
    Source(
        name="lastfm",
        label="Last.fm",
        description="Track / artist tags + listener counts (5 req/s).",
        lookup=_lookup_lastfm,
        enabled_check=_lf_enabled,
    )
)
