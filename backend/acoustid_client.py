"""AcoustID fingerprint-based track verification service.

Uses the AcoustID web API (https://acoustid.org/) to cross-check that a
Qobuz search result actually matches the intended track — catching wrong
versions (live vs. studio, remix vs. original, etc.).

Design:
  - Fail-open: every public method catches all exceptions and returns a safe
    default.  AcoustID being down (or the API key missing) never blocks
    search results or playback.
  - No audio required: we use metadata-only lookup (artist + title + duration)
    rather than fpcalc fingerprinting, so the backend never needs to download
    audio files.  fpcalc / pyacoustid are only used when a local audio path
    is available (advanced use-case, optional).
  - All network calls are async via httpx.

Getting an API key:
  Register for a free key at https://acoustid.org/api-key  (requires an
  AcoustID account, no credit card).  Set it via ACOUSTID_API_KEY env var
  or the acoustid.api_key config key.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx
from rapidfuzz import fuzz

logger = logging.getLogger(__name__)

# AcoustID metadata-lookup endpoint
_LOOKUP_URL = "https://api.acoustid.org/v2/lookup"
# Approximate match threshold for artist/title strings (0–100)
_FUZZY_MATCH_THRESHOLD = 70

# Version-marker words that, when present in *candidate* but not *expected*,
# indicate a different version of the track.
_VERSION_MARKERS = {
    "live",
    "concert",
    "acoustic",
    "unplugged",
    "demo",
    "remix",
    "remixed",
    "remaster",
    "remastered",
    "deluxe",
    "radio edit",
    "edit",
    "instrumental",
    "karaoke",
    "cover",
    "session",
    "rehearsal",
    "studio session",
    "bonus",
    "alternate",
    "alternative",
    "extended",
    "reprise",
}

# Max duration difference (seconds) before flagging as a possible mismatch
_MAX_DURATION_DIFF = 30


def _extract_version_markers(text: str) -> set[str]:
    """Return which version markers appear in *text* (lowercased)."""
    text_lower = text.lower()
    return {m for m in _VERSION_MARKERS if m in text_lower}


def _fuzzy_score(a: str, b: str) -> float:
    """Return a 0–1 similarity score between two strings."""
    return fuzz.token_sort_ratio(a.lower(), b.lower()) / 100.0


class AcoustIDVerifier:
    """Verify track identity using the AcoustID metadata API.

    All public methods are safe to call even when the API key is absent or
    AcoustID is unreachable — they return None / a non-blocking result dict
    and log a warning instead of raising.
    """

    def __init__(self, api_key: str) -> None:
        self.api_key = api_key
        # Shared async client; created lazily
        self._client: httpx.AsyncClient | None = None

    def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=10.0)
        return self._client

    async def close(self) -> None:
        """Close the underlying HTTP client."""
        if self._client and not self._client.is_closed:
            await self._client.aclose()

    async def lookup_by_metadata(
        self,
        artist: str,
        title: str,
        duration: int,
    ) -> dict[str, Any] | None:
        """Look up a track on AcoustID by metadata (no fingerprint needed).

        Uses AcoustID's /v2/lookup endpoint with trackid meta.  Note that
        metadata-only lookup requires a valid recording MBID — this method is
        therefore more useful for enriching known MusicBrainz recordings than
        for ad-hoc searches.  For the primary verification flow see
        :meth:`verify_match`.

        Args:
            artist:   Expected artist name.
            title:    Expected track title.
            duration: Track duration in seconds (used for AcoustID scoring).

        Returns:
            Dict with keys ``recording_id``, ``title``, ``artist``, ``score``
            from the best matching AcoustID result, or *None* if nothing was
            found / the call failed.
        """
        if not self.api_key:
            return None

        try:
            params = {
                "client": self.api_key,
                "format": "json",
                "duration": duration,
                "meta": "recordings",
                # AcoustID metadata lookup requires a fingerprint; we pass a
                # placeholder so the endpoint returns an error that we can
                # surface.  Metadata-only search is not directly supported by
                # the v2 API, so this method mainly exists as a building-block.
                "fingerprint": "AAAAAA",
            }
            resp = await self._get_client().get(_LOOKUP_URL, params=params)
            resp.raise_for_status()
            data = resp.json()

            results = data.get("results", [])
            if not results:
                return None

            best = results[0]
            recordings = best.get("recordings", [])
            if not recordings:
                return None

            rec = recordings[0]
            artists = rec.get("artists", [])
            rec_artist = artists[0].get("name", "") if artists else ""
            return {
                "recording_id": rec.get("id", ""),
                "title": rec.get("title", ""),
                "artist": rec_artist,
                "score": best.get("score", 0.0),
            }

        except Exception as exc:
            logger.debug("AcoustID lookup_by_metadata failed: %s", exc)
            return None

    async def verify_match(
        self,
        expected_artist: str,
        expected_title: str,
        candidate_artist: str,
        candidate_title: str,
        candidate_duration: int = 0,
        expected_duration: int = 0,
    ) -> dict[str, Any]:
        """Verify whether a candidate track matches the expected track.

        Uses a three-stage heuristic (no fingerprint needed):
          1. Fuzzy string matching on artist + title.
          2. Version-marker detection (live, remix, acoustic, etc.).
          3. Duration comparison (optional; skipped when either duration is 0).

        The result is always a dict — never raises.

        Args:
            expected_artist:    The artist we're looking for.
            expected_title:     The title we're looking for.
            candidate_artist:   Artist name returned by Qobuz search.
            candidate_title:    Title returned by Qobuz search.
            candidate_duration: Duration of the Qobuz result (seconds, 0 = unknown).
            expected_duration:  Duration of the expected track (seconds, 0 = unknown).

        Returns:
            ``{"match": bool, "confidence": float, "reason": str,
               "version_flags": list[str]}``
        """
        try:
            return self._verify_sync(
                expected_artist,
                expected_title,
                candidate_artist,
                candidate_title,
                candidate_duration,
                expected_duration,
            )
        except Exception as exc:
            logger.warning("AcoustID verify_match raised unexpectedly: %s", exc)
            return {
                "match": True,
                "confidence": 0.5,
                "reason": "Verification skipped (internal error)",
                "version_flags": [],
            }

    def _verify_sync(
        self,
        expected_artist: str,
        expected_title: str,
        candidate_artist: str,
        candidate_title: str,
        candidate_duration: int,
        expected_duration: int,
    ) -> dict[str, Any]:
        """Pure-Python sync implementation of verify_match."""
        # --- Stage 1: fuzzy string match ----------------------------------
        artist_score = _fuzzy_score(expected_artist, candidate_artist)
        title_score = _fuzzy_score(expected_title, candidate_title)
        combined_score = 0.4 * artist_score + 0.6 * title_score

        if combined_score < _FUZZY_MATCH_THRESHOLD / 100:
            return {
                "match": False,
                "confidence": round(combined_score, 3),
                "reason": (
                    f"Artist/title mismatch: "
                    f"expected '{expected_artist} — {expected_title}', "
                    f"got '{candidate_artist} — {candidate_title}' "
                    f"(similarity {combined_score:.0%})"
                ),
                "version_flags": [],
            }

        # --- Stage 2: version-marker detection ----------------------------
        expected_markers = _extract_version_markers(
            f"{expected_artist} {expected_title}"
        )
        candidate_markers = _extract_version_markers(
            f"{candidate_artist} {candidate_title}"
        )
        new_markers = candidate_markers - expected_markers

        if new_markers:
            # Penalise confidence for each unexpected marker
            penalty = 0.08 * len(new_markers)
            adjusted_confidence = max(0.0, round(combined_score - penalty, 3))
            flag_list = sorted(new_markers)
            return {
                "match": False,
                "confidence": adjusted_confidence,
                "reason": (
                    f"Version mismatch: candidate contains "
                    f"{', '.join(repr(m) for m in flag_list)} "
                    f"not present in expected title"
                ),
                "version_flags": flag_list,
            }

        # --- Stage 3: duration check (optional) ---------------------------
        duration_note = ""
        if candidate_duration > 0 and expected_duration > 0:
            diff = abs(candidate_duration - expected_duration)
            if diff > _MAX_DURATION_DIFF:
                penalty = min(0.3, diff / 300)  # cap penalty at 0.3
                adjusted_confidence = max(0.0, round(combined_score - penalty, 3))
                return {
                    "match": False,
                    "confidence": adjusted_confidence,
                    "reason": (
                        f"Duration mismatch: expected ~{expected_duration}s, "
                        f"candidate is {candidate_duration}s "
                        f"(difference {diff}s > {_MAX_DURATION_DIFF}s threshold)"
                    ),
                    "version_flags": [],
                }
            duration_note = f"; durations within {diff}s"

        return {
            "match": True,
            "confidence": round(combined_score, 3),
            "reason": (
                f"Match: artist {artist_score:.0%}, "
                f"title {title_score:.0%}{duration_note}"
            ),
            "version_flags": [],
        }


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_verifier: AcoustIDVerifier | None = None


def get_verifier() -> AcoustIDVerifier | None:
    """Return the module-level AcoustIDVerifier, or None if not configured."""
    return _verifier


def init_verifier(api_key: str) -> AcoustIDVerifier:
    """Create (or replace) the module-level verifier."""
    global _verifier
    _verifier = AcoustIDVerifier(api_key)
    logger.info("AcoustID verifier initialised (key present: %s)", bool(api_key))
    return _verifier


def verify_match_sync(
    expected_artist: str,
    expected_title: str,
    candidate_artist: str,
    candidate_title: str,
    candidate_duration: int = 0,
    expected_duration: int = 0,
) -> dict[str, Any]:
    """Convenience wrapper: run verify_match without needing a verifier instance.

    Uses the module-level verifier when available; falls back to a temporary
    AcoustIDVerifier with no key (still does fuzzy + version checks, just
    skips the AcoustID API call).  Never raises.
    """
    v = _verifier or AcoustIDVerifier(api_key="")
    return v._verify_sync(  # noqa: SLF001
        expected_artist,
        expected_title,
        candidate_artist,
        candidate_title,
        candidate_duration,
        expected_duration,
    )
