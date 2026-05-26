"""DJ-set template management for RoonSage.

Mirrors backend/templates.py but stores DJ-specific parameters (BPM range,
energy curve, mood arc) instead of an LLM prompt. Used by the DJ Set view
for one-click set generation and by the automation engine to build a DJ
set on a schedule and push it to a Qobuz playlist.

Built-in templates live in data/dj_templates.yaml; user templates in
data/user_dj_templates.yaml.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel

logger = logging.getLogger(__name__)

_REPO_ROOT = Path(__file__).parent.parent
_BUILTIN_PATH = _REPO_ROOT / "data" / "dj_templates.yaml"
_USER_PATH = _REPO_ROOT / "data" / "user_dj_templates.yaml"


# Keep in sync with backend/audio_features/dj_generator.EnergyCurve.
_VALID_CURVES = {
    "flat", "ramp_up", "ramp_down", "peak", "valley",
    "crescendo", "sunrise", "explosion", "afterparty",
    "wave", "marathon", "rollercoaster",
}


class DJTemplate(BaseModel):
    """A DJ-set generation template."""

    id: str
    name: str
    description: str = ""
    icon: str = "🎚️"
    category: str = "General"

    duration_minutes: int = 60
    track_count: int | None = None
    start_bpm: float = 110.0
    end_bpm: float = 128.0
    energy_curve: str = "ramp_up"
    start_mood: str | None = None
    end_mood: str | None = None
    genres: list[str] = []
    decades: list[str] = []
    exclude_live: bool = True

    is_builtin: bool = True

    model_config = {"extra": "ignore"}


def _load_yaml(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
        return data.get("templates", [])
    except Exception as exc:
        logger.warning("Failed to load DJ templates from %s: %s", path, exc)
        return []


def _save_yaml(templates: list[DJTemplate], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = [t.model_dump(exclude={"is_builtin"}) for t in templates]
    with path.open("w", encoding="utf-8") as fh:
        yaml.safe_dump({"templates": raw}, fh, allow_unicode=True, sort_keys=False)


def _raw_to_template(raw: dict[str, Any], is_builtin: bool = True) -> DJTemplate | None:
    try:
        curve = raw.get("energy_curve", "ramp_up")
        if curve not in _VALID_CURVES:
            logger.warning("DJ template %r has unknown energy_curve %r — falling back to 'ramp_up'",
                           raw.get("id"), curve)
            curve = "ramp_up"
        return DJTemplate(
            id=raw["id"],
            name=raw["name"],
            description=raw.get("description", ""),
            icon=raw.get("icon", "🎚️"),
            category=raw.get("category", "General"),
            duration_minutes=int(raw.get("duration_minutes", 60)),
            track_count=raw.get("track_count"),
            start_bpm=float(raw.get("start_bpm", 110.0)),
            end_bpm=float(raw.get("end_bpm", 128.0)),
            energy_curve=curve,
            start_mood=raw.get("start_mood"),
            end_mood=raw.get("end_mood"),
            genres=list(raw.get("genres") or []),
            decades=list(raw.get("decades") or []),
            exclude_live=bool(raw.get("exclude_live", True)),
            is_builtin=is_builtin,
        )
    except Exception as exc:
        logger.warning("Skipping malformed DJ template %r: %s", raw.get("id"), exc)
        return None


def get_all_dj_templates() -> list[DJTemplate]:
    """Return built-in DJ templates followed by user-created ones."""
    builtin = [_raw_to_template(r, is_builtin=True) for r in _load_yaml(_BUILTIN_PATH)]
    user = [_raw_to_template(r, is_builtin=False) for r in _load_yaml(_USER_PATH)]
    return [t for t in builtin + user if t is not None]


def get_dj_template(template_id: str) -> DJTemplate | None:
    for t in get_all_dj_templates():
        if t.id == template_id:
            return t
    return None


def save_user_dj_template(template: DJTemplate) -> DJTemplate:
    """Persist a user-created DJ template.

    Raises ValueError if the ID conflicts with a built-in template.
    """
    builtin_ids = {t.id for t in get_all_dj_templates() if t.is_builtin}
    if template.id in builtin_ids:
        raise ValueError(f"DJ template ID '{template.id}' conflicts with a built-in template")

    user_templates = [t for t in get_all_dj_templates() if not t.is_builtin]

    replaced = False
    updated: list[DJTemplate] = []
    for t in user_templates:
        if t.id == template.id:
            updated.append(template)
            replaced = True
        else:
            updated.append(t)
    if not replaced:
        updated.append(template)

    _save_yaml(updated, _USER_PATH)
    return template


def delete_user_dj_template(template_id: str) -> bool:
    """Delete a user-created DJ template. Returns True if removed, False if not found.

    Raises ValueError if attempting to delete a built-in template.
    """
    all_templates = get_all_dj_templates()
    target = next((t for t in all_templates if t.id == template_id), None)
    if target is None:
        return False
    if target.is_builtin:
        raise ValueError(f"Cannot delete built-in DJ template '{template_id}'")
    user_templates = [t for t in all_templates if not t.is_builtin and t.id != template_id]
    _save_yaml(user_templates, _USER_PATH)
    return True
