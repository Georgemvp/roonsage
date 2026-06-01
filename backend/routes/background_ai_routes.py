"""Background AI enrichment endpoints.

  GET  /api/background-ai/vibes-status              — tagged vs. total track count
  POST /api/background-ai/start-vibes               — trigger vibe/context tagging
  GET  /api/background-ai/lyrics-themes-status      — themed vs. total lyrics count
  POST /api/background-ai/start-lyrics-themes       — trigger lyrics theme extraction
  GET  /api/background-ai/discovery-description/{t} — cached description for a section
  POST /api/background-ai/describe-playlist         — generate playlist description on demand
"""

import asyncio
import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.background_tasks import task_tracker
from backend.db import get_db_connection
from backend.llm_client import is_background_ai_enabled, is_free_provider

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/background-ai", tags=["background-ai"])


# ---------------------------------------------------------------------------
# Settings UI: config toggle + unified status dashboard
# ---------------------------------------------------------------------------

class BgAIConfigUpdate(BaseModel):
    enabled: bool


@router.get("/config")
async def get_bg_ai_config() -> dict:
    """Current background AI config for the settings toggle."""
    from backend.llm_client import get_llm_client  # noqa: PLC0415
    client = get_llm_client()
    return {
        "enabled": is_background_ai_enabled() if is_background_ai_enabled() is not None else is_free_provider(),
        "is_free_provider": is_free_provider(),
        "provider": getattr(client, "provider", None) if client else None,
        "night_start": 1,
        "night_end": 7,
    }


@router.post("/config")
async def set_bg_ai_config(req: BgAIConfigUpdate) -> dict:
    """Persist the background AI on/off toggle to config.user.yaml."""
    from backend.config import save_user_config  # noqa: PLC0415
    save_user_config({"background_ai": {"enabled": req.enabled}})
    return {"enabled": req.enabled}


@router.get("/status")
async def background_ai_status() -> dict:
    """Unified status for all background AI tasks — used by the settings dashboard."""
    conn = get_db_connection()
    try:
        total_tracks   = conn.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        tagged_vibes   = conn.execute("SELECT COUNT(*) FROM track_vibes").fetchone()[0]
        with_lyrics    = conn.execute(
            "SELECT COUNT(*) FROM lyrics_data WHERE lyrics IS NOT NULL AND lyrics != ''"
        ).fetchone()[0]
        themed         = conn.execute("SELECT COUNT(*) FROM track_lyrics_themes").fetchone()[0]
        n_desc         = conn.execute("SELECT COUNT(*) FROM discovery_descriptions").fetchone()[0]
        n_cluster_ai   = conn.execute("SELECT COUNT(*) FROM cluster_ai_labels").fetchone()[0]
        suggestion_row = conn.execute(
            "SELECT generated_at FROM template_suggestions_cache WHERE id = 1"
        ).fetchone()
        n_narratives   = conn.execute("SELECT COUNT(*) FROM song_path_narratives").fetchone()[0]
    finally:
        conn.close()

    all_tasks = task_tracker.get_all()

    def _task(task_id: str) -> dict | None:
        return next((t for t in all_tasks if t["task_id"] == task_id), None)

    from backend.llm_client import get_llm_client  # noqa: PLC0415
    client = get_llm_client()

    return {
        "enabled": is_background_ai_enabled() if is_background_ai_enabled() is not None else is_free_provider(),
        "is_free_provider": is_free_provider(),
        "provider": getattr(client, "provider", None) if client else None,
        "tasks": {
            "vibe_tagging": {
                "label": "Vibe & Context Tagging",
                "schedule": "Continu (overdag elke 90s, 's nachts elke 8s)",
                "progress": {"done": tagged_vibes, "total": total_tracks},
                "task": _task("vibe_tagging"),
            },
            "lyrics_themes": {
                "label": "Lyrics Thema-extractie",
                "schedule": "Continu (overdag elke 2min, 's nachts elke 15s)",
                "progress": {"done": themed, "total": with_lyrics},
                "task": _task("lyrics_themes"),
            },
            "discovery_descriptions": {
                "label": "Discovery Omschrijvingen",
                "schedule": "Dagelijks",
                "progress": {"done": n_desc, "total": 3},
                "task": _task("discovery_descriptions_refresh"),
            },
            "cluster_labels": {
                "label": "Cluster AI Labels",
                "schedule": "Na clustering",
                "progress": {"done": n_cluster_ai, "total": None},
                "task": _task("cluster_labels"),
            },
            "template_suggestions": {
                "label": "Template Suggesties",
                "schedule": "Wekelijks",
                "progress": {"done": 1 if suggestion_row else 0, "total": 1},
                "task": _task("template_suggestions"),
            },
            "song_path_narratives": {
                "label": "Pad Narratieven",
                "schedule": "Op aanvraag",
                "progress": {"done": n_narratives, "total": None},
                "task": None,
            },
        },
    }


@router.get("/vibes-status")
async def vibes_status() -> dict:
    conn = get_db_connection()
    try:
        total = conn.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
        tagged = conn.execute("SELECT COUNT(*) FROM track_vibes").fetchone()[0]
    finally:
        conn.close()

    running_task = next(
        (t for t in task_tracker.get_all() if t["task_id"] == "vibe_tagging"), None
    )
    return {
        "enabled": is_background_ai_enabled(),
        "total": total,
        "tagged": tagged,
        "untagged": max(0, total - tagged),
        "task": running_task,
    }


@router.post("/start-vibes")
async def start_vibes() -> dict:
    if not is_background_ai_enabled():
        raise HTTPException(
            status_code=403,
            detail="Background AI uitgeschakeld voor betaalde providers.",
        )

    running = next(
        (t for t in task_tracker.get_all()
         if t["task_id"] == "vibe_tagging" and t["status"] == "running"),
        None,
    )
    if running:
        return {"started": False, "message": "Vibe tagging is al bezig."}

    from backend.background_ai import enrich_vibes_batch  # noqa: PLC0415

    asyncio.create_task(enrich_vibes_batch(), name="vibe_tagging")
    logger.info("Vibe tagging gestart via API")
    return {"started": True, "message": "Vibe tagging gestart."}


# ---------------------------------------------------------------------------
# Lyrics theme extraction
# ---------------------------------------------------------------------------

@router.get("/lyrics-themes-status")
async def lyrics_themes_status() -> dict:
    conn = get_db_connection()
    try:
        with_lyrics = conn.execute(
            "SELECT COUNT(*) FROM lyrics_data WHERE lyrics IS NOT NULL AND lyrics != ''"
        ).fetchone()[0]
        themed = conn.execute("SELECT COUNT(*) FROM track_lyrics_themes").fetchone()[0]
    finally:
        conn.close()

    running_task = next(
        (t for t in task_tracker.get_all() if t["task_id"] == "lyrics_themes"), None
    )
    return {
        "enabled": is_background_ai_enabled(),
        "with_lyrics": with_lyrics,
        "themed": themed,
        "unthemed": max(0, with_lyrics - themed),
        "task": running_task,
    }


@router.post("/start-lyrics-themes")
async def start_lyrics_themes() -> dict:
    if not is_background_ai_enabled():
        raise HTTPException(
            status_code=403,
            detail="Background AI uitgeschakeld voor betaalde providers.",
        )

    running = next(
        (t for t in task_tracker.get_all()
         if t["task_id"] == "lyrics_themes" and t["status"] == "running"),
        None,
    )
    if running:
        return {"started": False, "message": "Lyrics theme extractie is al bezig."}

    from backend.background_ai import extract_lyrics_themes_batch  # noqa: PLC0415

    asyncio.create_task(extract_lyrics_themes_batch(), name="lyrics_themes")
    logger.info("Lyrics theme extractie gestart via API")
    return {"started": True, "message": "Lyrics theme extractie gestart."}


# ---------------------------------------------------------------------------
# Discovery descriptions
# ---------------------------------------------------------------------------

class DiscoveryDescribeRequest(BaseModel):
    section_type: str
    tracks: list[dict]


@router.post("/generate-discovery-description")
async def generate_discovery_description_endpoint(req: DiscoveryDescribeRequest) -> dict:
    """Trigger AI description generation for a discovery section (fire-and-forget)."""
    from backend.background_ai import generate_discovery_description  # noqa: PLC0415

    asyncio.create_task(
        generate_discovery_description(req.section_type, req.tracks),
        name=f"discovery_desc_{req.section_type}",
    )
    return {"queued": True, "section_type": req.section_type}


@router.get("/discovery-description/{section_type}")
async def get_discovery_description(section_type: str) -> dict:
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT tagline, description, generated_at FROM discovery_descriptions WHERE section_type = ?",
            (section_type,),
        ).fetchone()
    finally:
        conn.close()

    if not row:
        return {"section_type": section_type, "tagline": None, "description": None}
    return {
        "section_type": section_type,
        "tagline": row["tagline"],
        "description": row["description"],
        "generated_at": row["generated_at"],
    }


# ---------------------------------------------------------------------------
# On-demand playlist description
# ---------------------------------------------------------------------------

class PlaylistDescribeRequest(BaseModel):
    title: str
    tracks: list[dict]
    origin: str = ""
    result_id: str | None = None


@router.post("/describe-playlist")
async def describe_playlist(req: PlaylistDescribeRequest) -> dict:
    if not is_background_ai_enabled():
        raise HTTPException(
            status_code=403,
            detail="Background AI uitgeschakeld voor betaalde providers.",
        )

    from backend.background_ai import generate_playlist_description  # noqa: PLC0415

    result = await generate_playlist_description(
        title=req.title,
        tracks=req.tracks,
        origin=req.origin,
        result_id=req.result_id,
    )
    if not result:
        raise HTTPException(status_code=500, detail="Beschrijving genereren mislukt.")
    return result


# ---------------------------------------------------------------------------
# Cluster AI labels
# ---------------------------------------------------------------------------

@router.get("/cluster-ai-labels")
async def get_cluster_ai_labels() -> dict:
    """All AI-generated cluster labels."""
    conn = get_db_connection()
    try:
        rows = conn.execute(
            "SELECT cluster_id, label, description, color_hint, generated_at "
            "FROM cluster_ai_labels ORDER BY cluster_id"
        ).fetchall()
    finally:
        conn.close()
    return {
        "labels": [
            {
                "cluster_id": r["cluster_id"],
                "label": r["label"],
                "description": r["description"],
                "color_hint": r["color_hint"],
                "generated_at": r["generated_at"],
            }
            for r in rows
        ]
    }


@router.post("/generate-cluster-labels")
async def generate_cluster_labels_endpoint() -> dict:
    """Trigger AI label generation for all clusters (fire-and-forget)."""
    if not is_background_ai_enabled():
        raise HTTPException(status_code=403, detail="Background AI uitgeschakeld.")

    from backend.background_ai import generate_cluster_labels  # noqa: PLC0415

    asyncio.create_task(generate_cluster_labels(), name="cluster_labels")
    return {"queued": True}


# ---------------------------------------------------------------------------
# Song path narrative
# ---------------------------------------------------------------------------

@router.get("/song-path-narrative/{cache_key}")
async def get_song_path_narrative(cache_key: str) -> dict:
    """Return cached song-path narrative (empty fields if not yet generated)."""
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT narrative, arc_type, key_transition, generated_at "
            "FROM song_path_narratives WHERE cache_key = ?",
            (cache_key,),
        ).fetchone()
    finally:
        conn.close()

    if not row:
        return {"cache_key": cache_key, "narrative": None, "arc_type": None,
                "key_transition": None}
    return {
        "cache_key": cache_key,
        "narrative": row["narrative"],
        "arc_type": row["arc_type"],
        "key_transition": row["key_transition"],
        "generated_at": row["generated_at"],
    }


# ---------------------------------------------------------------------------
# Template suggestions
# ---------------------------------------------------------------------------

@router.get("/template-suggestions")
async def get_template_suggestions() -> dict:
    """Cached AI-generated template suggestions."""
    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT suggestions, generated_at FROM template_suggestions_cache WHERE id = 1"
        ).fetchone()
    finally:
        conn.close()

    if not row:
        return {"suggestions": [], "generated_at": None}
    import json as _json  # noqa: PLC0415
    return {
        "suggestions": _json.loads(row["suggestions"]),
        "generated_at": row["generated_at"],
    }


@router.post("/generate-template-suggestions")
async def start_template_suggestions() -> dict:
    """Trigger template suggestion generation (fire-and-forget)."""
    if not is_background_ai_enabled():
        raise HTTPException(status_code=403, detail="Background AI uitgeschakeld.")

    from backend.background_ai import generate_template_suggestions  # noqa: PLC0415

    asyncio.create_task(generate_template_suggestions(), name="template_suggestions")
    return {"queued": True}
