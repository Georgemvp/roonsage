"""Circadian audio-feature profile (v13.4).

Builds a 24-hour map of the user's listening patterns in audio-feature space.
For each hour of day, we average the audio features (energy, danceability,
valence, instrumentalness, acousticness) of every track listened to at that
hour across all of ``listening_history``.

The resulting profile drives:

  * ``get_circadian_playlist(hour)`` — finds the library tracks whose audio
    fingerprint sits closest to the hour's target features.
  * ``get_adaptive_targets(zone_id)`` — shifts the hourly targets *away* from
    feature ranges that historically caused skips in that zone.

We deliberately compute the profile on-demand instead of caching it — the
SQL is cheap (a single GROUP BY hour over ``listening_history`` joined to
``track_audio_features``) and the underlying data changes every play.
"""

from __future__ import annotations

import logging
import math
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

# Subset of FEATURE_COLUMNS used for circadian mapping. BPM is excluded
# because typical-night-vs-morning *energy* matters far more than tempo —
# the late-night ambient track at 90 bpm and the morning ambient at 90 bpm
# should still cluster together.
CIRCADIAN_FEATURES: tuple[str, ...] = (
    "energy",
    "danceability",
    "valence",
    "instrumentalness",
    "acousticness",
)

MIN_SAMPLES_PER_HOUR = 3
# If fewer than this many hours have direct data we degrade to a single
# library-wide profile rather than interpolating wildly.
MIN_HOURS_WITH_DATA = 4


# ---------------------------------------------------------------------------
# Profile computation
# ---------------------------------------------------------------------------


def _avg_features_for_history(
    conn: sqlite3.Connection, where_clause: str, params: tuple
) -> dict[str, Any]:
    """Return (avg features dict, count) over a listening_history slice."""
    cols = ", ".join(f"AVG(taf.{c}) AS avg_{c}" for c in CIRCADIAN_FEATURES)
    sql = f"""
        SELECT {cols}, COUNT(*) AS n
          FROM listening_history lh
          JOIN tracks t
            ON LOWER(lh.track_title) = LOWER(t.title)
           AND LOWER(lh.artist) = LOWER(t.artist)
          JOIN track_audio_features taf
            ON taf.item_key = t.item_key
         WHERE {where_clause}
    """  # noqa: S608
    row = conn.execute(sql, params).fetchone()
    if row is None:
        return {"features": None, "n": 0}
    n = int(row["n"] or 0)
    if n == 0:
        return {"features": None, "n": 0}
    feats = {c: float(row[f"avg_{c}"] or 0.0) for c in CIRCADIAN_FEATURES}
    return {"features": feats, "n": n}


def _global_average(conn: sqlite3.Connection) -> dict[str, float] | None:
    """Fallback profile: average features over ALL listened tracks."""
    data = _avg_features_for_history(conn, "lh.skipped = 0", ())
    return data["features"]


def _interpolate_missing(
    profile: dict[int, dict[str, float] | None],
) -> dict[int, dict[str, float]]:
    """Fill empty hours by averaging the nearest hours that DO have data.

    The interpolation runs *circularly* — hour 23's neighbours are 22 and 0.
    Hours without data degrade to the mean of the two nearest populated hours
    on the circular ring; if no hour has data, all 24 hours come back zeroed.
    """
    populated = [(h, v) for h, v in profile.items() if v is not None]
    if not populated:
        return {h: {c: 0.0 for c in CIRCADIAN_FEATURES} for h in range(24)}

    pop_hours = sorted(h for h, _ in populated)

    def _circular_dist(a: int, b: int) -> int:
        d = abs(a - b)
        return min(d, 24 - d)

    out: dict[int, dict[str, float]] = {}
    for h in range(24):
        if profile.get(h) is not None:
            out[h] = dict(profile[h])  # type: ignore[arg-type]
            continue
        # find the two closest populated hours
        nearest = sorted(pop_hours, key=lambda p: _circular_dist(p, h))[:2]
        if len(nearest) == 1:
            out[h] = dict(profile[nearest[0]])  # type: ignore[arg-type]
        else:
            a, b = nearest
            d_a = _circular_dist(a, h) or 1
            d_b = _circular_dist(b, h) or 1
            total = d_a + d_b
            wa, wb = d_b / total, d_a / total  # closer = larger weight
            blended = {}
            for c in CIRCADIAN_FEATURES:
                blended[c] = (
                    wa * profile[a][c] + wb * profile[b][c]  # type: ignore[index]
                )
            out[h] = blended
    return out


def get_circadian_profile(conn: sqlite3.Connection) -> dict[str, Any]:
    """Return the user's 24-hour audio-feature profile.

    Output::

        {
          "feature_columns": [...],
          "hours": {0: {energy: 0.2, ...}, ..., 23: {...}},
          "sample_counts": {0: 3, 1: 0, ...},
          "interpolated_hours": [1, 4, 5],
          "total_samples": 312,
          "degraded": false  # True when fewer than MIN_HOURS_WITH_DATA hours have data
        }
    """
    hours_raw: dict[int, dict[str, float] | None] = {h: None for h in range(24)}
    counts: dict[int, int] = {h: 0 for h in range(24)}

    for h in range(24):
        data = _avg_features_for_history(
            conn,
            "lh.hour_of_day = ? AND lh.skipped = 0",
            (h,),
        )
        if data["n"] >= MIN_SAMPLES_PER_HOUR:
            hours_raw[h] = data["features"]
            counts[h] = int(data["n"])
        else:
            counts[h] = int(data["n"])  # keep raw count for transparency

    populated_hours = sum(1 for v in hours_raw.values() if v is not None)
    degraded = populated_hours < MIN_HOURS_WITH_DATA

    if degraded:
        fallback = _global_average(conn)
        if fallback is None:
            hours = {h: {c: 0.0 for c in CIRCADIAN_FEATURES} for h in range(24)}
        else:
            hours = {h: dict(fallback) for h in range(24)}
    else:
        hours = _interpolate_missing(hours_raw)

    interpolated = [h for h, v in hours_raw.items() if v is None]

    return {
        "feature_columns": list(CIRCADIAN_FEATURES),
        "hours": hours,
        "sample_counts": counts,
        "interpolated_hours": interpolated,
        "total_samples": sum(counts.values()),
        "degraded": degraded,
    }


# ---------------------------------------------------------------------------
# Playlist generation
# ---------------------------------------------------------------------------


def _load_feature_matrix(conn: sqlite3.Connection):
    """Pull every analysed track with all CIRCADIAN_FEATURES populated.

    Deduplicates on (LOWER(title), LOWER(artist)) so duplicate ``tracks`` rows
    (a known artifact of Roon's unstable item_keys across resyncs — see
    ``project_db_resync_limitation``) don't clog the playlist with copies of
    the same recording.
    """
    where = " AND ".join(f"taf.{c} IS NOT NULL" for c in CIRCADIAN_FEATURES)
    cols = ", ".join(f"MIN(taf.{c}) AS {c}" for c in CIRCADIAN_FEATURES)
    rows = conn.execute(
        f"""
        SELECT MIN(t.item_key) AS item_key,
               MIN(t.title)    AS title,
               MIN(t.artist)   AS artist,
               MIN(t.album)    AS album,
               MIN(t.year)     AS year,
               MIN(t.genres)   AS genres,
               {cols}
        FROM track_audio_features taf
        JOIN tracks t ON t.item_key = taf.item_key
        WHERE {where}
        GROUP BY LOWER(t.title), LOWER(t.artist)
        """
    ).fetchall()

    keys = [r["item_key"] for r in rows]
    matrix = [[float(r[c]) for c in CIRCADIAN_FEATURES] for r in rows]
    metadata = [
        {
            "item_key": r["item_key"],
            "title": r["title"],
            "artist": r["artist"],
            "album": r["album"],
            "year": r["year"],
            "genres": r["genres"],
            **{c: r[c] for c in CIRCADIAN_FEATURES},
        }
        for r in rows
    ]
    return keys, matrix, metadata


def _euclidean(a: list[float], b: list[float]) -> float:
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b, strict=False)))


def get_circadian_playlist(
    conn: sqlite3.Connection,
    *,
    hour: int,
    limit: int = 25,
) -> dict[str, Any]:
    """Pick library tracks closest to the target audio profile for ``hour``.

    Uses Euclidean distance on the (normalised) CIRCADIAN_FEATURES vector.
    Each feature already lives in 0..1 in our schema, so the components are
    already commensurate.
    """
    hour = int(hour) % 24

    profile = get_circadian_profile(conn)
    target_dict = profile["hours"][hour]
    target = [target_dict[c] for c in CIRCADIAN_FEATURES]

    keys, matrix, metadata = _load_feature_matrix(conn)
    if not keys:
        return {
            "error": "No analysed tracks available — run audio-features analyzer first.",
            "hour": hour,
            "target": target_dict,
            "feature_columns": list(CIRCADIAN_FEATURES),
            "results": [],
            "n_pool": 0,
        }

    scored: list[tuple[float, int]] = [
        (_euclidean(target, matrix[i]), i) for i in range(len(matrix))
    ]
    scored.sort()  # ascending distance — closest first

    results: list[dict[str, Any]] = []
    for dist, i in scored[:limit]:
        item = dict(metadata[i])
        # 1 = perfect match, 0 = furthest away (sqrt(N_features) is the worst-case
        # distance when every feature is in [0,1]).
        max_dist = math.sqrt(len(CIRCADIAN_FEATURES))
        match = max(0.0, 1.0 - dist / max_dist)
        item["match"] = round(float(match), 4)
        item["distance"] = round(float(dist), 4)
        results.append(item)

    return {
        "hour": hour,
        "target": target_dict,
        "feature_columns": list(CIRCADIAN_FEATURES),
        "results": results,
        "n_pool": len(matrix),
        "degraded": profile["degraded"],
        "interpolated": hour in profile["interpolated_hours"],
    }


# ---------------------------------------------------------------------------
# Adaptive targets (skip-aware)
# ---------------------------------------------------------------------------


def get_adaptive_targets(
    conn: sqlite3.Connection,
    *,
    zone_name: str | None = None,
) -> dict[str, Any]:
    """Adjust each hour's target away from feature ranges that cause skips.

    For each hour we compute:
      * play_features    = average of *finished* tracks at that hour.
      * skip_features    = average of *skipped*  tracks at that hour.
      * adjusted_target  = play_features + 0.4 × (play_features − skip_features)
                           (clipped to [0,1]).

    Hours without skip data fall back to ``play_features``. Hours without
    any data fall back to the interpolated baseline from ``get_circadian_profile``.
    """
    baseline = get_circadian_profile(conn)["hours"]

    adjusted: dict[int, dict[str, float]] = {}
    skip_counts: dict[int, int] = {h: 0 for h in range(24)}

    if zone_name:
        zone_filter = "AND LOWER(lh.zone_name) LIKE LOWER(?)"
        zone_param: tuple = (f"%{zone_name}%",)
    else:
        zone_filter = ""
        zone_param = ()

    for h in range(24):
        play_data = _avg_features_for_history(
            conn,
            f"lh.hour_of_day = ? AND lh.skipped = 0 {zone_filter}",
            (h, *zone_param),
        )
        skip_data = _avg_features_for_history(
            conn,
            f"lh.hour_of_day = ? AND lh.skipped = 1 {zone_filter}",
            (h, *zone_param),
        )
        skip_counts[h] = int(skip_data["n"])

        play_feats = play_data["features"]
        skip_feats = skip_data["features"]

        if play_feats is None:
            adjusted[h] = dict(baseline[h])
            continue
        if skip_feats is None:
            adjusted[h] = dict(play_feats)
            continue

        target = {}
        for c in CIRCADIAN_FEATURES:
            diff = play_feats[c] - skip_feats[c]
            v = play_feats[c] + 0.4 * diff
            target[c] = max(0.0, min(1.0, v))
        adjusted[h] = target

    return {
        "feature_columns": list(CIRCADIAN_FEATURES),
        "hours": adjusted,
        "skip_counts": skip_counts,
        "zone_name": zone_name,
    }


__all__ = [
    "CIRCADIAN_FEATURES",
    "get_adaptive_targets",
    "get_circadian_playlist",
    "get_circadian_profile",
]
