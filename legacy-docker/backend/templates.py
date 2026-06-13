"""Playlist template management for RoonSage.

Built-in templates are loaded from data/playlist_templates.yaml.
User-created templates are stored in data/user_templates.yaml and layered
on top of the built-in set.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).parent.parent
_BUILTIN_PATH = _REPO_ROOT / "data" / "playlist_templates.yaml"
_USER_PATH = _REPO_ROOT / "data" / "user_templates.yaml"


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class TemplateFilters(BaseModel):
    """Optional filters pre-applied when a template is used."""

    genres: list[str] = []
    decades: list[str] = []
    exclude_live: bool = True
    source_mode: str = "library"   # "library", "hybrid", or "qobuz"
    qobuz_percentage: int = 30


class PlaylistTemplate(BaseModel):
    """A playlist generation template."""

    id: str
    name: str
    description: str = ""
    icon: str = "🎵"
    category: str = "General"
    prompt: str
    filters: TemplateFilters = Field(default_factory=TemplateFilters)
    track_count: int = 25
    is_builtin: bool = True

    model_config = {"extra": "ignore"}


# ---------------------------------------------------------------------------
# Loader helpers
# ---------------------------------------------------------------------------


def _load_yaml(path: Path) -> list[dict[str, Any]]:
    """Load a YAML template file and return the list of raw dicts."""
    if not path.exists():
        return []
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
        return data.get("templates", [])
    except Exception as exc:
        logger.warning("Failed to load templates from %s: %s", path, exc)
        return []


def _save_yaml(templates: list[PlaylistTemplate], path: Path) -> None:
    """Persist a list of user templates to YAML."""
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = [t.model_dump(exclude={"is_builtin"}) for t in templates]
    with path.open("w", encoding="utf-8") as fh:
        yaml.safe_dump({"templates": raw}, fh, allow_unicode=True, sort_keys=False)


def _raw_to_template(raw: dict[str, Any], is_builtin: bool = True) -> PlaylistTemplate | None:
    """Convert a raw YAML dict to a PlaylistTemplate, returning None on error."""
    try:
        # Normalise filters sub-dict — accept partial or missing
        filters_raw = raw.get("filters") or {}
        # source_mode / qobuz_percentage may live at top level (template shortcut)
        if "source_mode" in raw:
            filters_raw.setdefault("source_mode", raw["source_mode"])
        if "qobuz_percentage" in raw:
            filters_raw.setdefault("qobuz_percentage", raw["qobuz_percentage"])
        return PlaylistTemplate(
            id=raw["id"],
            name=raw["name"],
            description=raw.get("description", ""),
            icon=raw.get("icon", "🎵"),
            category=raw.get("category", "General"),
            prompt=raw["prompt"].strip() if isinstance(raw["prompt"], str) else raw["prompt"],
            filters=TemplateFilters(**filters_raw),
            track_count=raw.get("track_count", 25),
            is_builtin=is_builtin,
        )
    except Exception as exc:
        logger.warning("Skipping malformed template %r: %s", raw.get("id"), exc)
        return None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def get_all_templates() -> list[PlaylistTemplate]:
    """Return built-in templates followed by user-created templates."""
    builtin = [_raw_to_template(r, is_builtin=True) for r in _load_yaml(_BUILTIN_PATH)]
    user = [_raw_to_template(r, is_builtin=False) for r in _load_yaml(_USER_PATH)]
    return [t for t in builtin + user if t is not None]


def get_template(template_id: str) -> PlaylistTemplate | None:
    """Return a single template by ID, or None if not found."""
    for t in get_all_templates():
        if t.id == template_id:
            return t
    return None


def save_user_template(template: PlaylistTemplate) -> PlaylistTemplate:
    """Persist a user-created template.  Raises ValueError if ID conflicts with built-in."""
    builtin_ids = {t.id for t in get_all_templates() if t.is_builtin}
    if template.id in builtin_ids:
        raise ValueError(f"Template ID '{template.id}' conflicts with a built-in template")

    user_templates = [t for t in get_all_templates() if not t.is_builtin]

    # Replace existing user template with same ID, or append
    replaced = False
    updated: list[PlaylistTemplate] = []
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


def delete_user_template(template_id: str) -> bool:
    """Delete a user-created template.  Returns True if deleted, False if not found.

    Raises ValueError if attempting to delete a built-in template.
    """
    all_templates = get_all_templates()
    target = next((t for t in all_templates if t.id == template_id), None)
    if target is None:
        return False
    if target.is_builtin:
        raise ValueError(f"Cannot delete built-in template '{template_id}'")

    user_templates = [t for t in all_templates if not t.is_builtin and t.id != template_id]
    _save_yaml(user_templates, _USER_PATH)
    return True
