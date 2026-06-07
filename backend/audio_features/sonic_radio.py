"""Sonic Radio (v13.3): endless adaptive radio mode tied to a Roon zone.

Builds on Sonic Fingerprint: the user's musical DNA seeds the initial queue,
and as tracks play we slowly drift the fingerprint toward what's actually
being heard (weighted: 0.8·original + 0.2·session). Skips dial the influence
of the skipped track back down so the radio adapts to negative feedback as
well as positive.

The class is a *pure orchestrator* — it never talks to Roon directly. The
zone-monitor hook (``backend.roon_intelligence``) calls ``next_tracks`` to
top up the queue and ``skip_feedback`` when a track is skipped.

Sessions are kept in-process (``_ACTIVE_SESSIONS`` dict, keyed by zone_id).
Restarting the backend ends every radio session — by design, so a half-stale
fingerprint doesn't keep biasing playback.
"""

from __future__ import annotations

import logging
import math
import re
import sqlite3
import threading
import time
from typing import Any

from backend.audio_features.clustering import FEATURE_COLUMNS

logger = logging.getLogger(__name__)

# Strip version markers like "(Live, Leverkusen, 2022)", "- 2011 Remastered",
# "(Acoustic)" so studio + alternate releases of the same song dedup together.
_VERSION_KEYWORDS = (
    r"live|remaster(?:ed)?|acoustic|unplugged|demo|radio\s*edit|"
    r"single\s*version|album\s*version|mono|stereo|remix|extended|edit|"
    r"version|bonus(?:\s*track)?|alternate(?:\s*take)?|session|sessions"
)
# Parenthetical / bracketed suffix that mentions a version keyword anywhere.
_PAREN_VERSION_RE = re.compile(
    rf"\s*[\(\[][^)\]]*(?:{_VERSION_KEYWORDS})[^)\]]*[)\]]\s*$",
    re.IGNORECASE,
)
# Trailing " - <anything containing version keyword>".
_DASH_VERSION_RE = re.compile(
    rf"\s*[\-–]\s*[^\-–]*?(?:{_VERSION_KEYWORDS})\b.*$",
    re.IGNORECASE,
)


def _canonical_song_id(artist: str, title: str) -> tuple[str, str]:
    """Return (primary_artist, base_title) used to dedup across versions.

    - Primary artist = first comma-separated part (drops featured artists).
    - Base title strips trailing parenthetical/dash version suffixes.
    """
    primary = (artist or "").split(",")[0].strip().lower()
    base = title or ""
    # Strip repeatedly: e.g. "Foo (Live) (Remastered)".
    for _ in range(2):
        new = _PAREN_VERSION_RE.sub("", base)
        new = _DASH_VERSION_RE.sub("", new)
        if new == base:
            break
        base = new
    return primary, base.strip().lower()


# Defaults (tweakable via SonicRadio config).
DEFAULT_DISCOVERY_RATIO = 0.3
DEFAULT_QUEUE_AHEAD = 5
DEFAULT_REFRESH_INTERVAL = 10  # tracks between fingerprint recomputes
FINGERPRINT_DRIFT_WEIGHT_ORIGINAL = 0.8
FINGERPRINT_DRIFT_WEIGHT_SESSION = 0.2
SKIP_PENALTY = 0.5  # multiplier applied to a skipped track's contribution

# ---------------------------------------------------------------------------
# Feature loading helpers
# ---------------------------------------------------------------------------


def _load_normalised_features(conn: sqlite3.Connection) -> tuple[
    list[str], list[list[float]], dict[str, dict[str, Any]], list[int]
]:
    """Pull every analyzed track + a normalised feature matrix.

    Returns
    -------
    (keys, normalised_matrix, metadata_by_key, play_counts)
        ``keys`` and ``play_counts`` are parallel lists; ``metadata_by_key``
        maps item_key → ``{title, artist, album}``.
    """
    cols = ", ".join(f"taf.{c}" for c in FEATURE_COLUMNS)
    where = " AND ".join(f"taf.{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    rows = conn.execute(
        f"""
        SELECT taf.item_key, {cols},
               t.title, t.artist, t.album,
               COALESCE(pc.cnt, 0) AS play_count
        FROM track_audio_features taf
        JOIN tracks t ON taf.item_key = t.item_key
        LEFT JOIN (
            SELECT LOWER(track_title) AS norm_title, LOWER(artist) AS norm_artist,
                   COUNT(*) AS cnt
            FROM listening_history
            GROUP BY LOWER(track_title), LOWER(artist)
        ) pc ON LOWER(t.title) = pc.norm_title AND LOWER(t.artist) = pc.norm_artist
        WHERE {where}
        """,
    ).fetchall()

    if not rows:
        return [], [], {}, []

    raw = [[float(r[c]) for c in FEATURE_COLUMNS] for r in rows]
    mins = [min(col) for col in zip(*raw, strict=False)]
    maxs = [max(col) for col in zip(*raw, strict=False)]
    norm: list[list[float]] = []
    for vec in raw:
        norm.append(
            [
                (v - mins[i]) / (maxs[i] - mins[i]) if maxs[i] > mins[i] else 0.0
                for i, v in enumerate(vec)
            ]
        )

    keys = [r["item_key"] for r in rows]
    metadata = {
        r["item_key"]: {
            "title": r["title"],
            "artist": r["artist"],
            "album": r["album"],
            "features": [float(r[c]) for c in FEATURE_COLUMNS],
        }
        for r in rows
    }
    play_counts = [int(r["play_count"]) for r in rows]
    return keys, norm, metadata, play_counts


def _initial_fingerprint(
    conn: sqlite3.Connection, top_n: int = 100
) -> list[float] | None:
    """Average normalised feature vector of the user's top-played tracks."""
    from backend.audio_features.sonic_fingerprint import (  # noqa: PLC0415
        get_sonic_fingerprint,
    )
    fp = get_sonic_fingerprint(conn, top_n=top_n)
    if "error" in fp:
        return None
    return list(fp["fingerprint"])


def _cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=False))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def _discovery_track_keys(conn: sqlite3.Connection) -> set[str]:
    """Item keys that qualify as "discovery" picks per the spec.

    Spec says: prefer Undiscovered Albums + Forgotten Favorites tracks. We
    don't currently expose an "undiscovered albums" section, so we use the
    tracks from ``get_forgotten_favorites`` plus ``get_deep_cuts`` as a
    proxy. Both surface unplayed-or-rarely-played tracks from artists the
    user already cares about.
    """
    try:
        from backend.discovery import (  # noqa: PLC0415
            get_deep_cuts,
            get_forgotten_favorites,
        )
    except Exception:
        return set()
    try:
        cuts = get_deep_cuts() or []
        forgotten = get_forgotten_favorites() or []
    except Exception:
        return set()
    return {row.get("item_key") for row in cuts + forgotten if row.get("item_key")}


# ---------------------------------------------------------------------------
# SonicRadio class
# ---------------------------------------------------------------------------


_ACTIVE_SESSIONS: dict[str, SonicRadio] = {}
_SESSIONS_LOCK = threading.Lock()


class SonicRadio:
    """Per-zone endless radio session driven by the user's sonic fingerprint."""

    def __init__(
        self,
        zone_id: str,
        db_path: str | None = None,
        config: dict[str, Any] | None = None,
    ) -> None:
        cfg = config or {}
        self.zone_id = zone_id
        self.db_path = db_path
        self.discovery_ratio: float = float(cfg.get("discovery_ratio", DEFAULT_DISCOVERY_RATIO))
        self.queue_ahead: int = int(cfg.get("queue_ahead", DEFAULT_QUEUE_AHEAD))
        self.refresh_interval: int = int(cfg.get("refresh_interval", DEFAULT_REFRESH_INTERVAL))

        self._original_fingerprint: list[float] | None = None
        self._session_fingerprint: list[float] | None = None
        self._current_fingerprint: list[float] | None = None
        # Item-keys played this session (no-repeat) and skipped (penalised).
        self._played_keys: list[str] = []
        self._skipped_keys: set[str] = set()
        # Per-key contribution weight to the session fingerprint (1.0 default,
        # halved on skip — see SKIP_PENALTY).
        self._session_weights: dict[str, float] = {}
        # Stats
        self._n_skipped = 0
        self._genres_seen: set[str] = set()
        self._duration_seconds = 0
        self._started_at = time.time()
        # Most recently generated batch — exposed via stats() for the UI.
        self._upcoming_metadata: list[dict[str, Any]] = []
        # Lock so concurrent next_tracks / skip_feedback don't race.
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ #
    # Public surface
    # ------------------------------------------------------------------ #

    async def start(self, seed_item_key: str | None = None) -> dict[str, Any]:
        """Compute the initial fingerprint and return the first batch of tracks.

        If *seed_item_key* is given the first batch is biased directly toward
        that track's audio features (raw cosine target) rather than the user's
        overall fingerprint.  After the first batch the current fingerprint
        resets to the original so subsequent picks drift back to the user's
        taste.
        """
        with self._open_conn() as conn:
            self._original_fingerprint = _initial_fingerprint(conn)
            if not self._original_fingerprint:
                raise RuntimeError(
                    "Sonic Radio: not enough listening history with audio features "
                    "to build a fingerprint."
                )
            if seed_item_key:
                # Load raw features so the seed fingerprint is in the same
                # space as the per-track feature vectors used in next_tracks.
                keys, _norm, metadata, _pc = _load_normalised_features(conn)
                if seed_item_key in metadata:
                    self._current_fingerprint = list(metadata[seed_item_key]["features"])
                else:
                    self._current_fingerprint = list(self._original_fingerprint)
            else:
                self._current_fingerprint = list(self._original_fingerprint)

        first_batch = await self.next_tracks(self.queue_ahead)

        # After the seeded first batch, reset so future picks follow the user's
        # overall fingerprint and the radio doesn't get stuck near the seed.
        if seed_item_key and self._original_fingerprint:
            self._current_fingerprint = list(self._original_fingerprint)

        return {
            "zone_id": self.zone_id,
            "discovery_ratio": self.discovery_ratio,
            "queue_ahead": self.queue_ahead,
            "refresh_interval": self.refresh_interval,
            "tracks": first_batch,
            "fingerprint": self._original_fingerprint,
        }

    async def next_tracks(self, count: int) -> list[dict[str, Any]]:
        """Return the next ``count`` tracks, refreshing the fingerprint if due."""
        if count <= 0:
            return []
        with self._lock:
            with self._open_conn() as conn:
                # Time to drift the fingerprint?
                if (
                    self._original_fingerprint is not None
                    and self._played_keys
                    and len(self._played_keys) % self.refresh_interval == 0
                ):
                    self._recompute_session_fingerprint(conn)

                keys, _, metadata, play_counts = _load_normalised_features(conn)
                if not keys:
                    return []

                fp = self._current_fingerprint or self._original_fingerprint or [
                    0.5
                ] * len(FEATURE_COLUMNS)

                # Build candidate list excluding already-played tracks.
                played = set(self._played_keys)
                # Also exclude same song across versions (studio/live/remaster).
                played_at: set[tuple[str, str]] = {
                    _canonical_song_id(metadata[k]["artist"], metadata[k]["title"])
                    for k in self._played_keys
                    if k in metadata
                }
                # Rank: cosine similarity to the current fingerprint.
                similarities: list[tuple[float, int]] = []
                for i, key in enumerate(keys):
                    if key in played:
                        continue
                    at = _canonical_song_id(metadata[key]["artist"], metadata[key]["title"])
                    if at in played_at:
                        continue
                    fv = metadata[key]["features"]
                    sim = _cosine(fv, fp)
                    similarities.append((sim, i))
                similarities.sort(key=lambda x: -x[0])

                # Deduplicate by canonical (artist, title) so the studio +
                # live/remaster versions of the same song don't both appear.
                seen_at: set[tuple[str, str]] = set()
                deduped: list[tuple[float, int]] = []
                for sim, i in similarities:
                    at = _canonical_song_id(
                        metadata[keys[i]]["artist"], metadata[keys[i]]["title"]
                    )
                    if at not in seen_at:
                        seen_at.add(at)
                        deduped.append((sim, i))

                pool_size = max(count * 5, 50)
                top_pool = deduped[:pool_size]

                familiar_idx: list[int] = []
                unplayed_idx: list[int] = []
                for _sim, i in top_pool:
                    (unplayed_idx if play_counts[i] == 0 else familiar_idx).append(i)

                # Discovery boost: prefer Discovery Engine picks within the
                # unplayed bucket (Forgotten Favorites + Deep Cuts).
                discovery_keys = _discovery_track_keys(conn)
                if discovery_keys:
                    unplayed_idx.sort(
                        key=lambda i: 0 if keys[i] in discovery_keys else 1
                    )

                n_discovery = max(0, min(count, round(self.discovery_ratio * count)))
                n_familiar = max(0, count - n_discovery)

                chosen: list[int] = []
                # Fill discovery slot first; fall back to familiar if needed.
                for i in unplayed_idx:
                    if len(chosen) >= n_discovery:
                        break
                    chosen.append(i)
                for i in familiar_idx:
                    if len(chosen) >= n_discovery + n_familiar:
                        break
                    chosen.append(i)
                # Fill any shortfall from the remaining sorted pool.
                if len(chosen) < count:
                    chosen_set = set(chosen)
                    for _, i in top_pool:
                        if i in chosen_set:
                            continue
                        chosen.append(i)
                        if len(chosen) >= count:
                            break

                # Record + decorate.
                result: list[dict[str, Any]] = []
                for i in chosen[:count]:
                    key = keys[i]
                    self._played_keys.append(key)
                    self._session_weights.setdefault(key, 1.0)
                    meta = metadata[key]
                    result.append(
                        {
                            "item_key": key,
                            "title": meta["title"],
                            "artist": meta["artist"],
                            "album": meta["album"],
                            "is_discovery": play_counts[i] == 0,
                            "from_discovery_section": key in discovery_keys,
                        }
                    )
                self._upcoming_metadata = list(result)
                return result

    async def skip_feedback(self, track_id: str) -> dict[str, Any]:
        """Penalise ``track_id`` so its features influence the session less."""
        with self._lock:
            if track_id not in self._played_keys:
                # Allow registering a skip even if the track wasn't in the
                # logged history yet (e.g. fast-skipped before next_tracks).
                self._played_keys.append(track_id)
            self._skipped_keys.add(track_id)
            self._session_weights[track_id] = (
                self._session_weights.get(track_id, 1.0) * SKIP_PENALTY
            )
            self._n_skipped += 1
            # Immediate drift so the next pick already reflects the skip.
            with self._open_conn() as conn:
                self._recompute_session_fingerprint(conn)
            return {
                "track_id": track_id,
                "n_skipped": self._n_skipped,
                "weight": self._session_weights[track_id],
            }

    async def stop(self) -> dict[str, Any]:
        """Return final session stats and forget this zone's session."""
        stats = self.stats()
        with _SESSIONS_LOCK:
            _ACTIVE_SESSIONS.pop(self.zone_id, None)
        return stats

    def stats(self) -> dict[str, Any]:
        return {
            "zone_id": self.zone_id,
            "tracks_played": len(self._played_keys),
            "played_count": len(self._played_keys),
            "tracks_skipped": self._n_skipped,
            "duration_seconds": int(time.time() - self._started_at),
            "genres_covered": sorted(self._genres_seen),
            "discovery_ratio": self.discovery_ratio,
            "fingerprint_drift": self._fingerprint_drift_distance(),
            "upcoming": self._upcoming_metadata[:10],
            "mood": "neutraal",
        }

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #

    def _open_conn(self):
        """Return a managed sqlite3 connection (closed by the context exit)."""
        from contextlib import contextmanager  # noqa: PLC0415

        @contextmanager
        def _cm():
            if self.db_path is None:
                from backend.db import get_db_connection  # noqa: PLC0415
                conn = get_db_connection()
            else:
                conn = sqlite3.connect(self.db_path, timeout=30.0)
                conn.row_factory = sqlite3.Row
            try:
                yield conn
            finally:
                conn.close()

        return _cm()

    def _recompute_session_fingerprint(self, conn: sqlite3.Connection) -> None:
        """Blend the original fingerprint with the session-so-far weighted average."""
        if not self._played_keys or self._original_fingerprint is None:
            return
        keys, norm, _, _ = _load_normalised_features(conn)
        if not keys:
            return
        idx_by_key = {k: i for i, k in enumerate(keys)}
        n_dim = len(FEATURE_COLUMNS)

        weighted_sum = [0.0] * n_dim
        total_weight = 0.0
        for key in self._played_keys:
            if key not in idx_by_key:
                continue
            vec = norm[idx_by_key[key]]
            weight = self._session_weights.get(key, 1.0)
            for d in range(n_dim):
                weighted_sum[d] += vec[d] * weight
            total_weight += weight
        if total_weight == 0:
            return

        session_fp = [v / total_weight for v in weighted_sum]
        self._session_fingerprint = session_fp
        original = self._original_fingerprint or [0.5] * n_dim
        self._current_fingerprint = [
            FINGERPRINT_DRIFT_WEIGHT_ORIGINAL * original[d]
            + FINGERPRINT_DRIFT_WEIGHT_SESSION * session_fp[d]
            for d in range(n_dim)
        ]

    def _fingerprint_drift_distance(self) -> float:
        """Euclidean distance between original and current fingerprint."""
        if (
            self._original_fingerprint is None
            or self._current_fingerprint is None
        ):
            return 0.0
        return math.sqrt(
            sum(
                (a - b) ** 2
                for a, b in zip(
                    self._original_fingerprint,
                    self._current_fingerprint,
                    strict=False,
                )
            )
        )


# ---------------------------------------------------------------------------
# Module-level session registry helpers
# ---------------------------------------------------------------------------


def get_session(zone_id: str) -> SonicRadio | None:
    with _SESSIONS_LOCK:
        return _ACTIVE_SESSIONS.get(zone_id)


def register_session(session: SonicRadio) -> None:
    with _SESSIONS_LOCK:
        _ACTIVE_SESSIONS[session.zone_id] = session


def list_sessions() -> list[dict[str, Any]]:
    with _SESSIONS_LOCK:
        return [s.stats() for s in _ACTIVE_SESSIONS.values()]


def stop_all_sessions() -> None:
    with _SESSIONS_LOCK:
        _ACTIVE_SESSIONS.clear()
