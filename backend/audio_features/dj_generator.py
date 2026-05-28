"""DJ-style set builder using audio features.

Constructs an ordered track list that follows a BPM curve and respects
harmonic mixing rules (Camelot wheel neighbours). The algorithm is greedy
with one-step lookahead — fast enough to call from a request handler:

  1. Pull a candidate pool from ``tracks`` ⋈ ``track_audio_features`` filtered
     by a ±6 BPM window around [start_bpm, end_bpm], genres, and live exclusion.
     A single query is run (no double-query for mood); valence soft-preference
     is handled entirely by the per-position scorer.
  2. Compute per-position target BPM, energy, and valence from the chosen curve
     and mood profiles.
  3. For each position:
        a. Prefer candidates within ±5 BPM of the target (bisect-based soft
           BPM pre-filter); fall back to the full remaining pool if fewer than
           5 pass.  When ``allow_half_step`` is True, also match tracks whose
           half or double BPM lands within ±5 of the target.
        b. Apply the hard artist cap (max 2 per artist; 3 if pool is small).
        c. Score remaining candidates on BPM, energy, valence, harmonic key,
           and a sliding-window artist-recency penalty (last 8 tracks).
        d. Randomise among the top-N best (N scales with pool size, 5–12).
"""

from __future__ import annotations

import bisect
import logging
import math
import random
from typing import Any, Literal

from backend.audio_features import camelot
from backend.db import get_connection

logger = logging.getLogger(__name__)

EnergyCurve = Literal[
    "flat", "ramp_up", "ramp_down", "peak", "valley",
    "crescendo", "sunrise", "explosion", "afterparty", "wave", "marathon", "rollercoaster",
]

AVG_TRACK_MINUTES = 4.0

# Mood → (valence_min, valence_max, energy_bias).
MOOD_PROFILES: dict[str, tuple[float, float, float]] = {
    "euforisch":     (0.80, 1.00,  0.40),
    "feestelijk":    (0.70, 1.00,  0.25),
    "opgewonden":    (0.60, 0.90,  0.35),
    "energiek":      (0.45, 0.85,  0.30),
    "vrolijk":       (0.65, 0.95,  0.15),
    "blij":          (0.60, 0.95,  0.05),
    "krachtig":      (0.15, 0.55,  0.35),
    "intens":        (0.10, 0.50,  0.20),
    "serieus":       (0.20, 0.55, -0.05),
    "nostalgisch":   (0.35, 0.65, -0.05),
    "romantisch":    (0.50, 0.85, -0.15),
    "chill":         (0.35, 0.70, -0.20),
    "zacht":         (0.45, 0.80, -0.30),
    "dromerig":      (0.25, 0.65, -0.25),
    "rustig":        (0.40, 0.75, -0.35),
    "meditatief":    (0.30, 0.65, -0.40),
    "melancholisch": (0.00, 0.40, -0.10),
    "donker":        (0.00, 0.30,  0.15),
}


def _curve_values(curve: EnergyCurve, n: int) -> list[float]:
    """Return ``n`` energy targets in [0, 1] following the requested shape."""
    if n <= 0:
        return []
    if n == 1:
        return [0.6]
    xs = [i / (n - 1) for i in range(n)]
    if curve == "flat":
        return [0.55 for _ in xs]
    if curve == "ramp_up":
        return [0.35 + 0.55 * x for x in xs]
    if curve == "ramp_down":
        return [0.85 - 0.55 * x for x in xs]
    if curve == "peak":
        return [0.35 + 0.55 * math.sin(math.pi * x) for x in xs]
    if curve == "valley":
        return [0.85 - 0.55 * math.sin(math.pi * x) for x in xs]
    if curve == "crescendo":
        return [0.25 + 0.65 * x ** 2 for x in xs]
    if curve == "sunrise":
        return [0.18 + 0.65 * math.sqrt(x) for x in xs]
    if curve == "explosion":
        return [0.30 + max(0.0, (x - 0.75) / 0.25) * 0.60 for x in xs]
    if curve == "afterparty":
        return [max(0.15, 0.90 - 0.65 * x ** 0.6) for x in xs]
    if curve == "wave":
        return [0.50 + 0.35 * math.sin(4 * math.pi * x) for x in xs]
    if curve == "marathon":
        return [0.45 + 0.40 * max(0.0, (x - 0.70) / 0.30) for x in xs]
    if curve == "rollercoaster":
        return [0.35 + 0.55 * abs(math.sin(3 * math.pi * x)) for x in xs]
    return [0.55 for _ in xs]


def _bpm_targets(start_bpm: float, end_bpm: float, n: int, curve: EnergyCurve = "ramp_up") -> list[float]:
    if n <= 1:
        return [start_bpm]
    raw = _curve_values(curve, n)
    v_min, v_max = min(raw), max(raw)
    if v_max == v_min:
        return [(start_bpm + end_bpm) / 2] * n
    bpm_low = min(start_bpm, end_bpm)
    bpm_high = max(start_bpm, end_bpm)
    return [bpm_low + (v - v_min) / (v_max - v_min) * (bpm_high - bpm_low) for v in raw]


def _valence_targets(start_mood: str | None, end_mood: str | None, n: int) -> list[float] | None:
    if start_mood is None:
        return None
    p_start = MOOD_PROFILES.get(start_mood)
    if p_start is None:
        return None
    v_start = (p_start[0] + p_start[1]) / 2.0
    p_end = MOOD_PROFILES.get(end_mood) if end_mood else None
    v_end = (p_end[0] + p_end[1]) / 2.0 if p_end else v_start
    if n <= 1:
        return [v_start]
    return [v_start + (v_end - v_start) * i / (n - 1) for i in range(n)]


def _energy_bias(start_mood: str | None, end_mood: str | None, n: int) -> list[float]:
    if start_mood is None:
        return [0.0] * n
    b_start = MOOD_PROFILES.get(start_mood, (0, 0, 0))[2]
    b_end = MOOD_PROFILES.get(end_mood, (0, 0, 0))[2] if end_mood else b_start
    if n <= 1:
        return [b_start]
    return [b_start + (b_end - b_start) * i / (n - 1) for i in range(n)]


_ARTIST_RECENCY_WINDOW = 8


def _effective_bpm(bpm: float, target: float) -> float:
    """Return bpm, bpm/2, or bpm*2 — whichever is closest to target."""
    candidates = [bpm, bpm * 2.0, bpm / 2.0]
    return min(candidates, key=lambda b: abs(b - target))


# Pre-computed Camelot compatible-key sets (cached per key string).
_compat_cache: dict[str, frozenset[str]] = {}


def _compat_set(key: str) -> frozenset[str]:
    if key not in _compat_cache:
        _compat_cache[key] = frozenset(camelot.compatible(key))
    return _compat_cache[key]


def _score_candidate(
    cand: dict[str, Any],
    *,
    target_bpm: float,
    target_energy: float,
    prev_camelot: str | None,
    recent_artists: list[str],
    target_valence: float | None = None,
    allow_half_step: bool = True,
) -> float:
    """Lower is better."""
    raw_bpm = cand.get("bpm") or target_bpm
    bpm = _effective_bpm(raw_bpm, target_bpm) if allow_half_step else raw_bpm
    energy = cand.get("energy") or 0.5
    cam = cand.get("camelot") or ""

    bpm_pen = abs(bpm - target_bpm) / 4.0
    energy_pen = abs(energy - target_energy)

    artist_pen = 0.0
    if cand["artist"] in recent_artists[-3:]:
        artist_pen = 0.6
    elif cand["artist"] in recent_artists:
        artist_pen = 0.2

    harmonic_bonus = 0.0
    if prev_camelot and cam:
        if cam == prev_camelot:
            harmonic_bonus = -0.05
        elif cam in _compat_set(prev_camelot):
            harmonic_bonus = -0.25

    valence_pen = 0.0
    if target_valence is not None:
        v = cand.get("valence")
        if v is not None:
            valence_pen = abs(v - target_valence) * 1.0

    return 1.2 * bpm_pen + 0.8 * energy_pen + valence_pen + artist_pen + harmonic_bonus


def _run_query(sql: str, params: list[Any]) -> list[dict[str, Any]]:
    """Execute a candidate query and deduplicate on (title, artist)."""
    with get_connection() as conn:
        rows = conn.execute(sql, params).fetchall()
    seen: set[tuple[str, str]] = set()
    result: list[dict[str, Any]] = []
    for row in rows:
        d = dict(row)
        key = (d["title"].lower(), d["artist"].lower())
        if key not in seen:
            seen.add(key)
            result.append(d)
    return result


def _load_candidates(
    *,
    start_bpm: float,
    end_bpm: float,
    genres: list[str] | None,
    exclude_live: bool,
    decades: list[str] | None,
    allow_half_step: bool = True,
    recent_keys: set[str] | None = None,
) -> list[dict[str, Any]]:
    """Return tracks with audio features within the broad BPM window.

    A single query is issued — no double-query for mood.  Valence filtering
    is handled by the per-position scorer so we never need a second round-trip.
    When ``allow_half_step`` is True the BPM window is doubled to also capture
    tracks that will be played at half- or double-time.
    """
    margin = 6.0
    low  = min(start_bpm, end_bpm) - margin
    high = max(start_bpm, end_bpm) + margin

    if allow_half_step:
        # Expand the window to also capture half/double-time matches.
        half_low  = low  / 2.0
        half_high = high / 2.0
        double_low  = low  * 2.0
        double_high = high * 2.0

    conditions = ["af.bpm IS NOT NULL"]
    if allow_half_step:
        conditions.append(
            f"(af.bpm >= {low} AND af.bpm <= {high}"
            f" OR af.bpm >= {half_low} AND af.bpm <= {half_high}"
            f" OR af.bpm >= {double_low} AND af.bpm <= {double_high})"
        )
        params: list[Any] = []
    else:
        conditions.append("af.bpm >= ? AND af.bpm <= ?")
        params = [low, high]

    if exclude_live:
        conditions.append("t.is_live = 0")

    if decades:
        decade_conds = []
        for d in decades:
            try:
                start_yr = int(d.rstrip("s"))
                decade_conds.append("(t.year >= ? AND t.year <= ?)")
                params.extend([start_yr, start_yr + 9])
            except ValueError:
                continue
        if decade_conds:
            conditions.append(f"({' OR '.join(decade_conds)})")

    where = " AND ".join(conditions)

    if genres:
        ph = ",".join("?" for _ in genres)
        sql = f"""
            SELECT DISTINCT t.item_key, t.title, t.artist, t.album, t.year,
                            t.duration_ms,
                            af.bpm, af.camelot, af.energy, af.danceability, af.valence
            FROM tracks t
            JOIN track_audio_features af ON af.item_key = t.item_key
            JOIN track_genres tg ON tg.track_key = t.item_key
            WHERE {where} AND LOWER(tg.genre) IN ({ph})
        """
        params.extend(g.lower() for g in genres)
    else:
        sql = f"""
            SELECT t.item_key, t.title, t.artist, t.album, t.year,
                   t.duration_ms,
                   af.bpm, af.camelot, af.energy, af.danceability, af.valence
            FROM tracks t
            JOIN track_audio_features af ON af.item_key = t.item_key
            WHERE {where}
        """

    pool = _run_query(sql, params)

    if recent_keys:
        pool = [c for c in pool if c["item_key"] not in recent_keys]

    return pool


def _get_recent_keys(days: int = 7) -> set[str]:
    """Return item_keys played in the last ``days`` days."""
    sql = """
        SELECT DISTINCT item_key FROM listening_history
        WHERE timestamp >= datetime('now', ?)
          AND item_key IS NOT NULL
    """
    with get_connection() as conn:
        rows = conn.execute(sql, [f"-{days} days"]).fetchall()
    return {row["item_key"] for row in rows}


def build_dj_set(
    *,
    duration_minutes: int = 60,
    track_count: int | None = None,
    start_bpm: float = 110.0,
    end_bpm: float = 128.0,
    energy_curve: EnergyCurve = "ramp_up",
    genres: list[str] | None = None,
    decades: list[str] | None = None,
    exclude_live: bool = True,
    seed_item_key: str | None = None,
    rng_seed: int | None = None,
    start_mood: str | None = None,
    end_mood: str | None = None,
    max_per_artist: int | None = None,
    allow_half_step: bool = True,
    skip_recent: bool = False,
) -> dict[str, Any]:
    """Construct a beatmatched, harmonically-mixed set.

    Returns:
        ``{"tracks": [...], "total_matching": N, "returned": M, "curve": [...],
           "total_duration_ms": T}``
    """
    rng = random.Random(rng_seed) if rng_seed is not None else random.Random()
    n_tracks = track_count or max(5, int(round(duration_minutes / AVG_TRACK_MINUTES)))
    n_tracks = max(3, min(n_tracks, 120))

    recent_keys = _get_recent_keys() if skip_recent else None

    pool = _load_candidates(
        start_bpm=start_bpm,
        end_bpm=end_bpm,
        genres=genres,
        exclude_live=exclude_live,
        decades=decades,
        allow_half_step=allow_half_step,
        recent_keys=recent_keys,
    )
    if not pool:
        return {"tracks": [], "total_matching": 0, "returned": 0, "curve": [], "total_duration_ms": 0}

    # Pre-sort pool by BPM for fast bisect-based soft filter.
    pool_sorted = sorted(pool, key=lambda c: c.get("bpm") or 0.0)
    pool_bpms   = [c.get("bpm") or 0.0 for c in pool_sorted]

    bpm_curve = _bpm_targets(start_bpm, end_bpm, n_tracks, energy_curve)
    raw_energy = _curve_values(energy_curve, n_tracks)
    e_bias = _energy_bias(start_mood, end_mood, n_tracks)
    energy_curve_vals = [max(0.0, min(1.0, e + b)) for e, b in zip(raw_energy, e_bias, strict=True)]
    valence_targets = _valence_targets(start_mood, end_mood, n_tracks)

    used_keys: set[str] = set()
    recent_artists: list[str] = []
    selected: list[dict[str, Any]] = []
    prev_camelot: str | None = None
    artist_counts: dict[str, int] = {}

    if max_per_artist is not None:
        artist_cap = max(1, max_per_artist)
    else:
        artist_cap = 2 if len(pool) >= 2 * n_tracks else 3

    if seed_item_key:
        seed = next((c for c in pool if c["item_key"] == seed_item_key), None)
        if seed is not None:
            selected.append(seed)
            used_keys.add(seed["item_key"])
            recent_artists.append(seed["artist"])
            artist_counts[seed["artist"]] = artist_counts.get(seed["artist"], 0) + 1
            prev_camelot = seed.get("camelot")

    top_n_size = max(5, min(12, len(pool) // 20))

    _BPM_SOFT = 5.0
    _BPM_SOFT_MIN = 5

    start_idx = len(selected)
    for i in range(start_idx, n_tracks):
        target_bpm = bpm_curve[i]
        target_energy = energy_curve_vals[i]
        target_valence = valence_targets[i] if valence_targets else None
        window = recent_artists[-_ARTIST_RECENCY_WINDOW:]

        # Bisect-based BPM soft filter on sorted pool (fast for large pools).
        lo_idx = bisect.bisect_left(pool_bpms, target_bpm - _BPM_SOFT)
        hi_idx = bisect.bisect_right(pool_bpms, target_bpm + _BPM_SOFT)
        bpm_close = pool_sorted[lo_idx:hi_idx]

        # Also include half/double-time matches when allow_half_step is on.
        if allow_half_step:
            for factor in (2.0, 0.5):
                adj = target_bpm * factor
                lo2 = bisect.bisect_left(pool_bpms, adj - _BPM_SOFT)
                hi2 = bisect.bisect_right(pool_bpms, adj + _BPM_SOFT)
                bpm_close = bpm_close + pool_sorted[lo2:hi2]

        candidates = bpm_close if len(bpm_close) >= _BPM_SOFT_MIN else pool_sorted

        scored = [
            (
                _score_candidate(
                    c,
                    target_bpm=target_bpm,
                    target_energy=target_energy,
                    prev_camelot=prev_camelot,
                    recent_artists=window,
                    target_valence=target_valence,
                    allow_half_step=allow_half_step,
                ),
                c,
            )
            for c in candidates
            if c["item_key"] not in used_keys
            and artist_counts.get(c["artist"], 0) < artist_cap
        ]

        if not scored:
            scored = [
                (
                    _score_candidate(
                        c,
                        target_bpm=target_bpm,
                        target_energy=target_energy,
                        prev_camelot=prev_camelot,
                        recent_artists=window,
                        target_valence=target_valence,
                        allow_half_step=allow_half_step,
                    ),
                    c,
                )
                for c in pool_sorted
                if c["item_key"] not in used_keys
            ]
        if not scored:
            break

        scored.sort(key=lambda sc: sc[0])
        top_n = scored[: max(1, min(top_n_size, len(scored)))]
        pick = rng.choice(top_n)[1]
        selected.append(pick)
        used_keys.add(pick["item_key"])
        recent_artists.append(pick["artist"])
        artist_counts[pick["artist"]] = artist_counts.get(pick["artist"], 0) + 1
        prev_camelot = pick.get("camelot")

    n = len(selected)
    curve = []
    for i, (b, e) in enumerate(zip(bpm_curve[:n], energy_curve_vals[:n], strict=True)):
        point: dict[str, Any] = {"bpm": round(b, 1), "energy": round(e, 3)}
        if valence_targets:
            point["valence"] = round(valence_targets[i], 3)
        curve.append(point)

    total_duration_ms = sum(
        (t.get("duration_ms") or 0) or int(AVG_TRACK_MINUTES * 60_000)
        for t in selected
    )

    return {
        "tracks": selected,
        "total_matching": len(pool),
        "returned": len(selected),
        "curve": curve,
        "total_duration_ms": total_duration_ms,
    }
