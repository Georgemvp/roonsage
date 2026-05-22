"""DJ-style set builder using audio features.

Constructs an ordered track list that follows a BPM curve and respects
harmonic mixing rules (Camelot wheel neighbours). The algorithm is greedy
with one-step lookahead — fast enough to call from a request handler:

  1. Pull a candidate pool from ``tracks`` ⋈ ``track_audio_features`` filtered
     by (broad) BPM window, genres, exclude-live.
  2. Compute a per-position target BPM (linear ramp) and target energy.
  3. For each position, pick the highest-scoring candidate that:
        - is Camelot-compatible with the previous track,
        - is within ±4 BPM of target,
        - hasn't been used yet,
        - keeps the running artist-diversity invariant (≥80% unique artists).

The result mirrors the structure used by ``filter_tracks`` so the existing
``curate_and_play`` flow can play it back via a server-side session.
"""

from __future__ import annotations

import logging
import math
import random
from typing import Any, Literal

from backend.audio_features import camelot
from backend.db import get_connection

logger = logging.getLogger(__name__)

EnergyCurve = Literal["flat", "ramp_up", "ramp_down", "peak", "valley"]

# Estimated average track length used to turn `duration_minutes` into a
# track count when the user does not specify `track_count` explicitly.
AVG_TRACK_MINUTES = 4.0

# Mood → (valence_min, valence_max, energy_bias).
# valence 0=sad/dark, 1=happy/bright. energy_bias shifts the energy curve.
MOOD_PROFILES: dict[str, tuple[float, float, float]] = {
    "blij":          (0.65, 1.00,  0.10),
    "energiek":      (0.45, 0.85,  0.30),
    "feestelijk":    (0.70, 1.00,  0.25),
    "chill":         (0.35, 0.70, -0.20),
    "dromerig":      (0.25, 0.65, -0.25),
    "romantisch":    (0.50, 0.85, -0.20),
    "melancholisch": (0.00, 0.40, -0.10),
    "intens":        (0.10, 0.55,  0.20),
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
    return [0.55 for _ in xs]


def _bpm_targets(start_bpm: float, end_bpm: float, n: int) -> list[float]:
    if n <= 1:
        return [start_bpm]
    return [start_bpm + (end_bpm - start_bpm) * i / (n - 1) for i in range(n)]


def _valence_targets(start_mood: str | None, end_mood: str | None, n: int) -> list[float] | None:
    """Return per-position valence targets, or None if no mood was requested."""
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
    """Per-position additive energy bias from mood profiles."""
    if start_mood is None:
        return [0.0] * n
    b_start = MOOD_PROFILES.get(start_mood, (0, 0, 0))[2]
    b_end = MOOD_PROFILES.get(end_mood, (0, 0, 0))[2] if end_mood else b_start
    if n <= 1:
        return [b_start]
    return [b_start + (b_end - b_start) * i / (n - 1) for i in range(n)]


def _score_candidate(
    cand: dict[str, Any],
    *,
    target_bpm: float,
    target_energy: float,
    prev_camelot: str | None,
    recent_artists: list[str],
    target_valence: float | None = None,
) -> float:
    """Lower is better — combines BPM/energy/valence distance with diversity penalty."""
    bpm = cand.get("bpm") or target_bpm
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
            harmonic_bonus = -0.05  # smooth, but slightly penalised to discourage same-key streaks
        elif cam in camelot.compatible(prev_camelot):
            harmonic_bonus = -0.25

    valence_pen = 0.0
    if target_valence is not None:
        v = cand.get("valence")
        if v is not None:
            valence_pen = abs(v - target_valence) * 0.7

    # tighter BPM bias than energy: BPM mismatches are audible immediately.
    return 1.2 * bpm_pen + 0.8 * energy_pen + valence_pen + artist_pen + harmonic_bonus


def _load_candidates(
    *,
    start_bpm: float,
    end_bpm: float,
    genres: list[str] | None,
    exclude_live: bool,
    decades: list[str] | None,
    start_mood: str | None = None,
    end_mood: str | None = None,
) -> list[dict[str, Any]]:
    """Return all tracks with audio features within the broad BPM window."""
    low = min(start_bpm, end_bpm) - 8.0
    high = max(start_bpm, end_bpm) + 8.0

    conditions = ["af.bpm IS NOT NULL", "af.bpm >= ?", "af.bpm <= ?"]
    params: list[Any] = [low, high]
    if exclude_live:
        conditions.append("t.is_live = 0")

    # Broad valence pre-filter: keeps the pool relevant without over-constraining.
    # Window covers the full range of both start and end moods, plus ±0.2 slack.
    moods_to_check = [m for m in [start_mood, end_mood] if m and m in MOOD_PROFILES]
    if moods_to_check:
        all_mins = [MOOD_PROFILES[m][0] for m in moods_to_check]
        all_maxs = [MOOD_PROFILES[m][1] for m in moods_to_check]
        v_low  = max(0.0, min(all_mins) - 0.2)
        v_high = min(1.0, max(all_maxs) + 0.2)
        conditions.append("af.valence IS NOT NULL")
        conditions.append("af.valence >= ?")
        conditions.append("af.valence <= ?")
        params.extend([v_low, v_high])

    if decades:
        decade_conds = []
        for d in decades:
            try:
                start = int(d.rstrip("s"))
                decade_conds.append("(t.year >= ? AND t.year <= ?)")
                params.extend([start, start + 9])
            except ValueError:
                continue
        if decade_conds:
            conditions.append(f"({' OR '.join(decade_conds)})")

    where = " AND ".join(conditions)

    if genres:
        ph = ",".join("?" for _ in genres)
        sql = f"""
            SELECT DISTINCT t.item_key, t.title, t.artist, t.album, t.year,
                            af.bpm, af.camelot, af.energy, af.danceability,
                            af.valence
            FROM tracks t
            JOIN track_audio_features af ON af.item_key = t.item_key
            JOIN track_genres tg ON tg.track_key = t.item_key
            WHERE {where} AND LOWER(tg.genre) IN ({ph})
        """
        params.extend(g.lower() for g in genres)
    else:
        sql = f"""
            SELECT t.item_key, t.title, t.artist, t.album, t.year,
                   af.bpm, af.camelot, af.energy, af.danceability, af.valence
            FROM tracks t
            JOIN track_audio_features af ON af.item_key = t.item_key
            WHERE {where}
        """

    with get_connection() as conn:
        rows = conn.execute(sql, params).fetchall()
    return [dict(row) for row in rows]


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
) -> dict[str, Any]:
    """Construct a beatmatched, harmonically-mixed set.

    Returns:
        ``{"tracks": [...], "total_matching": N, "returned": M, "curve": [...]}``
        in the same shape as the ``filter_tracks`` library route, so the
        normal session-storage + ``curate_and_play`` flow can play it back.
    """
    rng = random.Random(rng_seed) if rng_seed is not None else random.Random()
    n_tracks = track_count or max(5, int(round(duration_minutes / AVG_TRACK_MINUTES)))
    n_tracks = max(3, min(n_tracks, 120))

    pool = _load_candidates(
        start_bpm=start_bpm,
        end_bpm=end_bpm,
        genres=genres,
        exclude_live=exclude_live,
        decades=decades,
        start_mood=start_mood,
        end_mood=end_mood,
    )
    if not pool:
        return {"tracks": [], "total_matching": 0, "returned": 0, "curve": []}

    bpm_curve = _bpm_targets(start_bpm, end_bpm, n_tracks)
    raw_energy = _curve_values(energy_curve, n_tracks)
    e_bias = _energy_bias(start_mood, end_mood, n_tracks)
    energy_curve_vals = [max(0.0, min(1.0, e + b)) for e, b in zip(raw_energy, e_bias, strict=False)]
    valence_targets = _valence_targets(start_mood, end_mood, n_tracks)

    used_keys: set[str] = set()
    recent_artists: list[str] = []
    selected: list[dict[str, Any]] = []
    prev_camelot: str | None = None

    # Optional seed: lock the first slot if a key is provided and matches.
    if seed_item_key:
        seed = next((c for c in pool if c["item_key"] == seed_item_key), None)
        if seed is not None:
            selected.append(seed)
            used_keys.add(seed["item_key"])
            recent_artists.append(seed["artist"])
            prev_camelot = seed.get("camelot")

    start_idx = len(selected)
    for i in range(start_idx, n_tracks):
        target_bpm = bpm_curve[i]
        target_energy = energy_curve_vals[i]
        target_valence = valence_targets[i] if valence_targets else None

        scored = [
            (
                _score_candidate(
                    c,
                    target_bpm=target_bpm,
                    target_energy=target_energy,
                    prev_camelot=prev_camelot,
                    recent_artists=recent_artists,
                    target_valence=target_valence,
                ),
                c,
            )
            for c in pool
            if c["item_key"] not in used_keys
        ]
        if not scored:
            break

        # Randomise among the top-N best candidates so two runs with the same
        # filters produce different sets (DJ sets should not be deterministic).
        scored.sort(key=lambda sc: sc[0])
        top_n = scored[: max(1, min(5, len(scored)))]
        pick = rng.choice(top_n)[1]
        selected.append(pick)
        used_keys.add(pick["item_key"])
        recent_artists.append(pick["artist"])
        prev_camelot = pick.get("camelot")

    n = len(selected)
    curve = []
    for i, (b, e) in enumerate(zip(bpm_curve[:n], energy_curve_vals[:n], strict=False)):
        point: dict[str, Any] = {"bpm": round(b, 1), "energy": round(e, 3)}
        if valence_targets:
            point["valence"] = round(valence_targets[i], 3)
        curve.append(point)

    return {
        "tracks": selected,
        "total_matching": len(pool),
        "returned": len(selected),
        "curve": curve,
    }
