"""Saved Song Alchemy profiles + Surprise Me automation (v13.4).

A Song Alchemy *profile* is a frozen target-feature vector — the mean of the
ADD tracks and the mean of the SUBTRACT tracks, computed once and stored. The
profile can be re-applied later without re-selecting tracks, and bound to a
specific Roon zone for one-tap regeneration.

The ``surprise_me`` helper builds an *implicit* profile from a zone's recent
play / skip pattern: the last few finished tracks become ADD, recent skipped
tracks become SUBTRACT (falling back to the lowest-energy of the recent plays
when there are no skips). It returns the same shape as
``compute_alchemy_from_target`` so the call sites are interchangeable.
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import sqlite3

from backend.audio_features.alchemy import (
    SUBTRACT_WEIGHT,
    _cosine_similarity,
    _load_feature_matrix,
    _mean_vector,
)
from backend.audio_features.clustering import FEATURE_COLUMNS

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Schema bootstrap — called lazily so production DB migrations stay centralised
# in backend/db.py but profile tables can be created on first call from tests.
# ---------------------------------------------------------------------------


def _ensure_table(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS alchemy_profiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            zone_id TEXT,
            add_features TEXT NOT NULL,       -- JSON: {feature: value, ...}
            subtract_features TEXT,           -- JSON or NULL
            add_track_ids TEXT,               -- JSON list of source item_keys
            subtract_track_ids TEXT,          -- JSON list of source item_keys
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_alchemy_profiles_zone
            ON alchemy_profiles(zone_id);
        """
    )
    conn.commit()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _features_dict(vec: list[float]) -> dict[str, float]:
    return dict(zip(FEATURE_COLUMNS, vec, strict=False))


def _vec_from_dict(d: dict[str, float]) -> list[float]:
    return [float(d.get(c, 0.0)) for c in FEATURE_COLUMNS]


def _row_to_profile(row: sqlite3.Row) -> dict[str, Any]:
    raw = dict(row)
    for jcol in ("add_features", "subtract_features", "add_track_ids", "subtract_track_ids"):
        v = raw.get(jcol)
        if isinstance(v, str) and v:
            try:
                raw[jcol] = json.loads(v)
            except Exception:
                raw[jcol] = None
    return raw


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------


def list_profiles(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    _ensure_table(conn)
    rows = conn.execute(
        "SELECT * FROM alchemy_profiles ORDER BY updated_at DESC, id DESC"
    ).fetchall()
    return [_row_to_profile(r) for r in rows]


def get_profile(conn: sqlite3.Connection, profile_id: int) -> dict[str, Any] | None:
    _ensure_table(conn)
    row = conn.execute(
        "SELECT * FROM alchemy_profiles WHERE id = ?", (profile_id,)
    ).fetchone()
    if row is None:
        return None
    return _row_to_profile(row)


def delete_profile(conn: sqlite3.Connection, profile_id: int) -> bool:
    _ensure_table(conn)
    cur = conn.execute("DELETE FROM alchemy_profiles WHERE id = ?", (profile_id,))
    conn.commit()
    return cur.rowcount > 0


def save_profile(
    conn: sqlite3.Connection,
    *,
    name: str,
    zone_id: str | None,
    add_track_ids: list[str],
    subtract_track_ids: list[str] | None = None,
) -> dict[str, Any]:
    """Compute the averaged ADD/SUBTRACT vectors and persist as a named profile.

    Existing profiles with the same name are replaced (UPSERT via
    ``INSERT OR REPLACE`` — preserves the autoincrement id only if absent).
    """
    if not name or not name.strip():
        raise ValueError("Profile name is required")
    if not add_track_ids:
        raise ValueError("At least one ADD track is required")

    _ensure_table(conn)

    subtract_track_ids = subtract_track_ids or []
    keys, matrix, _meta = _load_feature_matrix(conn)
    if not keys:
        raise RuntimeError("No analysed tracks — cannot compute profile")

    key_to_idx = {k: i for i, k in enumerate(keys)}
    missing = [k for k in (add_track_ids + subtract_track_ids) if k not in key_to_idx]
    if missing:
        raise KeyError(f"Tracks not analyzed: {missing}")

    add_vecs = [matrix[key_to_idx[k]] for k in add_track_ids]
    sub_vecs = [matrix[key_to_idx[k]] for k in subtract_track_ids]

    add_mean = _mean_vector(add_vecs)
    sub_mean = _mean_vector(sub_vecs) if sub_vecs else None

    now = _now_iso()

    existing = conn.execute(
        "SELECT id FROM alchemy_profiles WHERE name = ?", (name.strip(),)
    ).fetchone()

    add_json = json.dumps(_features_dict(add_mean))
    sub_json = json.dumps(_features_dict(sub_mean)) if sub_mean is not None else None
    add_ids_json = json.dumps(list(add_track_ids))
    sub_ids_json = json.dumps(list(subtract_track_ids))

    if existing:
        profile_id = int(existing["id"])
        conn.execute(
            """UPDATE alchemy_profiles
                  SET zone_id = ?, add_features = ?, subtract_features = ?,
                      add_track_ids = ?, subtract_track_ids = ?, updated_at = ?
                WHERE id = ?""",
            (zone_id, add_json, sub_json, add_ids_json, sub_ids_json, now, profile_id),
        )
    else:
        cur = conn.execute(
            """INSERT INTO alchemy_profiles
                   (name, zone_id, add_features, subtract_features,
                    add_track_ids, subtract_track_ids, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (name.strip(), zone_id, add_json, sub_json,
             add_ids_json, sub_ids_json, now, now),
        )
        profile_id = int(cur.lastrowid)

    conn.commit()
    return get_profile(conn, profile_id) or {}


# ---------------------------------------------------------------------------
# Generation from a saved profile
# ---------------------------------------------------------------------------


def _rank_by_target(
    matrix: list[list[float]],
    metadata: list[dict[str, Any]],
    keys: list[str],
    target: list[float],
    *,
    excluded: set[str],
    limit: int,
) -> list[dict[str, Any]]:
    scored: list[tuple[float, int]] = []
    for i, vec in enumerate(matrix):
        if keys[i] in excluded:
            continue
        scored.append((_cosine_similarity(target, vec), i))
    scored.sort(reverse=True)

    out: list[dict[str, Any]] = []
    for score, i in scored[:limit]:
        item = dict(metadata[i])
        item["similarity"] = round(float(score), 4)
        out.append(item)
    return out


def generate_from_profile(
    conn: sqlite3.Connection,
    profile_id: int,
    limit: int = 25,
) -> dict[str, Any]:
    """Apply a saved profile to the library and return the top-N closest tracks."""
    _ensure_table(conn)
    profile = get_profile(conn, profile_id)
    if profile is None:
        raise KeyError(f"Profile {profile_id} not found")

    add_features = profile.get("add_features") or {}
    sub_features = profile.get("subtract_features") or {}

    add_vec = _vec_from_dict(add_features)
    sub_vec = _vec_from_dict(sub_features) if sub_features else [0.0] * len(FEATURE_COLUMNS)
    target = [add_vec[d] - SUBTRACT_WEIGHT * sub_vec[d] for d in range(len(FEATURE_COLUMNS))]

    keys, matrix, metadata = _load_feature_matrix(conn)
    if not keys:
        return {
            "profile_id": profile_id,
            "profile_name": profile.get("name"),
            "target": _features_dict(target),
            "result_mean": None,
            "feature_columns": list(FEATURE_COLUMNS),
            "results": [],
            "n_pool": 0,
        }

    excluded = set(profile.get("add_track_ids") or []) | set(
        profile.get("subtract_track_ids") or []
    )

    results = _rank_by_target(
        matrix, metadata, keys, target, excluded=excluded, limit=limit
    )

    if results:
        key_to_idx = {k: i for i, k in enumerate(keys)}
        result_vecs = [matrix[key_to_idx[r["item_key"]]] for r in results]
        result_mean = _mean_vector(result_vecs)
    else:
        result_mean = [0.0] * len(FEATURE_COLUMNS)

    return {
        "profile_id": profile_id,
        "profile_name": profile.get("name"),
        "zone_id": profile.get("zone_id"),
        "target": _features_dict(target),
        "result_mean": _features_dict(result_mean),
        "feature_columns": list(FEATURE_COLUMNS),
        "results": results,
        "n_pool": len(matrix) - len(excluded),
    }


# ---------------------------------------------------------------------------
# Surprise Me — implicit profile from zone listening history
# ---------------------------------------------------------------------------


SURPRISE_RECENT_N = 5
SURPRISE_LOOKBACK_HOURS = 72


def _recent_listening_for_zone(
    conn: sqlite3.Connection, zone_name: str | None
) -> list[dict[str, Any]]:
    """Return recent listening_history rows for a zone (most recent first).

    ``zone_name`` is matched substring-insensitive against ``zone_name`` in
    listening_history. Pass ``None`` to fetch across all zones.
    """
    if zone_name:
        rows = conn.execute(
            """
            SELECT *
            FROM listening_history
            WHERE LOWER(zone_name) LIKE LOWER(?)
              AND timestamp >= datetime('now', ?)
            ORDER BY timestamp DESC
            LIMIT 50
            """,
            (f"%{zone_name}%", f"-{SURPRISE_LOOKBACK_HOURS} hours"),
        ).fetchall()
    else:
        rows = conn.execute(
            """
            SELECT *
            FROM listening_history
            WHERE timestamp >= datetime('now', ?)
            ORDER BY timestamp DESC
            LIMIT 50
            """,
            (f"-{SURPRISE_LOOKBACK_HOURS} hours",),
        ).fetchall()
    return [dict(r) for r in rows]


def _match_history_to_item_keys(
    conn: sqlite3.Connection, history_rows: list[dict[str, Any]]
) -> list[tuple[dict[str, Any], str]]:
    """Resolve listening_history rows to (row, item_key).

    Joins via case-insensitive title+artist match against tracks. Rows that
    can't be matched, or whose track lacks fully-populated audio features,
    are skipped.
    """
    if not history_rows:
        return []

    out: list[tuple[dict[str, Any], str]] = []
    where = " AND ".join(f"taf.{c} IS NOT NULL" for c in FEATURE_COLUMNS)
    sql = f"""
        SELECT t.item_key
          FROM tracks t
          JOIN track_audio_features taf ON taf.item_key = t.item_key
         WHERE LOWER(t.title) = LOWER(?)
           AND LOWER(t.artist) = LOWER(?)
           AND {where}
         LIMIT 1
    """
    for row in history_rows:
        title = row.get("track_title") or ""
        artist = row.get("artist") or ""
        if not title or not artist:
            continue
        match = conn.execute(sql, (title, artist)).fetchone()
        if match is None:
            continue
        out.append((row, match["item_key"]))
    return out


def surprise_me(
    conn: sqlite3.Connection,
    zone_name: str | None,
    *,
    limit: int = 25,
) -> dict[str, Any]:
    """Build a surprise playlist from recent plays / skips in a zone.

    Algorithm:
      1. Pull the last ~50 listening_history rows for the zone (72h window).
      2. ADD pool = last 5 *finished* tracks (skipped=0). SUBTRACT pool = last
         5 *skipped* tracks (skipped=1).
      3. If there are no skips, the lowest-energy half of the recent plays
         becomes SUBTRACT — pushing the mix in the direction of the higher-
         energy plays. This keeps the result interesting on a zone that the
         user never skips on.
      4. Average the feature vectors, build the alchemy target, cosine-rank
         the library.
    """
    history = _recent_listening_for_zone(conn, zone_name)
    matched = _match_history_to_item_keys(conn, history)
    if not matched:
        return {
            "error": (
                "Not enough recent listening with audio features for "
                f"zone {zone_name!r} — surprise needs a few finished tracks first."
            ),
            "zone_name": zone_name,
            "n_history": len(history),
        }

    # Load the normalised library matrix once — ADD/SUBTRACT vectors must
    # come from the same min-max space we're ranking against, otherwise the
    # target lives in a different vector space than the candidates.
    keys, matrix, metadata = _load_feature_matrix(conn)
    if not keys:
        return {
            "error": "No analysed tracks available to surprise from.",
            "zone_name": zone_name,
            "n_history": len(history),
        }
    key_to_idx = {k: i for i, k in enumerate(keys)}

    plays: list[tuple[list[float], str]] = []
    skips: list[tuple[list[float], str]] = []
    for row, ikey in matched:
        if ikey not in key_to_idx:
            continue  # track exists but isn't in the current analysed pool
        vec = matrix[key_to_idx[ikey]]
        if row.get("skipped"):
            skips.append((vec, ikey))
        else:
            plays.append((vec, ikey))

    if not plays:
        return {
            "error": "No finished plays in the recent window — only skips.",
            "zone_name": zone_name,
            "n_history": len(history),
        }

    add_vecs = [v for v, _ in plays[:SURPRISE_RECENT_N]]
    add_ids = [k for _, k in plays[:SURPRISE_RECENT_N]]

    if skips:
        sub_vecs = [v for v, _ in skips[:SURPRISE_RECENT_N]]
        sub_ids = [k for _, k in skips[:SURPRISE_RECENT_N]]
        sub_reason = "recent_skips"
    else:
        # No skip data — push *away* from the lowest-energy half of the
        # recent plays so the result has a bit more pull.
        energy_idx = FEATURE_COLUMNS.index("energy") if "energy" in FEATURE_COLUMNS else 0
        sorted_by_energy = sorted(plays, key=lambda pair: pair[0][energy_idx])
        cutoff = max(1, len(sorted_by_energy) // 2)
        sub_vecs = [v for v, _ in sorted_by_energy[:cutoff]]
        sub_ids = [k for _, k in sorted_by_energy[:cutoff]]
        sub_reason = "low_energy_plays_fallback"

    add_mean = _mean_vector(add_vecs)
    sub_mean = _mean_vector(sub_vecs) if sub_vecs else [0.0] * len(FEATURE_COLUMNS)
    target = [add_mean[d] - SUBTRACT_WEIGHT * sub_mean[d] for d in range(len(FEATURE_COLUMNS))]

    excluded = set(add_ids) | set(sub_ids)
    results = _rank_by_target(
        matrix, metadata, keys, target, excluded=excluded, limit=limit
    )

    if results:
        key_to_idx = {k: i for i, k in enumerate(keys)}
        result_vecs = [matrix[key_to_idx[r["item_key"]]] for r in results]
        result_mean = _mean_vector(result_vecs)
    else:
        result_mean = [0.0] * len(FEATURE_COLUMNS)

    return {
        "zone_name": zone_name,
        "n_history": len(history),
        "n_plays": len(plays),
        "n_skips": len(skips),
        "subtract_source": sub_reason,
        "add_track_ids": add_ids,
        "subtract_track_ids": sub_ids,
        "target": _features_dict(target),
        "result_mean": _features_dict(result_mean),
        "feature_columns": list(FEATURE_COLUMNS),
        "results": results,
        "n_pool": len(matrix) - len(excluded),
    }


# ---------------------------------------------------------------------------
# Convenience: zone lookup helper (used by automation + REST)
# ---------------------------------------------------------------------------


def find_zone_id_by_name(zones: list[dict[str, Any]], zone_name: str) -> str | None:
    """Case-insensitive substring zone-name → zone_id lookup."""
    if not zone_name:
        return None
    needle = zone_name.lower()
    for z in zones:
        if needle in (z.get("display_name") or "").lower():
            return z.get("zone_id")
    return None


__all__ = [
    "FEATURE_COLUMNS",
    "delete_profile",
    "find_zone_id_by_name",
    "generate_from_profile",
    "get_profile",
    "list_profiles",
    "save_profile",
    "surprise_me",
]
