"""Background AI task status endpoint."""

from fastapi import APIRouter

from backend.background_tasks import task_tracker
from backend.llm_client import get_llm_client, is_background_ai_enabled

router = APIRouter()


@router.get("/api/background-tasks")
async def get_background_tasks() -> dict:
    enabled = is_background_ai_enabled()
    client = get_llm_client()
    return {
        "enabled": enabled,
        "provider": client.provider if client else None,
        "tasks": task_tracker.get_all() if enabled else [],
    }
