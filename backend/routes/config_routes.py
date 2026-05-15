"""Configuration and Ollama endpoints."""

import asyncio
import os

from fastapi import APIRouter, HTTPException, Query

from backend.config import ConfigSaveError, get_config, update_config_values
from backend.llm_client import (
    get_ollama_model_info,
    get_ollama_status,
    init_llm_client,
    list_ollama_models,
)
from backend.models import (
    ConfigResponse,
    HealthResponse,
    OllamaModelInfo,
    OllamaModelsResponse,
    OllamaStatus,
    UpdateConfigRequest,
)
from backend.roon_client import get_roon_client, init_roon_client
from backend.dependencies import _is_llm_configured, _build_config_response

router = APIRouter(prefix="/api", tags=["config"])


@router.get("/health", response_model=HealthResponse)
async def health_check() -> HealthResponse:
    """Check application health status."""
    config = get_config()
    roon_client = get_roon_client()

    return HealthResponse(
        status="healthy",
        roon_connected=roon_client.is_connected() if roon_client else False,
        llm_configured=_is_llm_configured(config),
    )


@router.get("/config", response_model=ConfigResponse)
async def get_configuration() -> ConfigResponse:
    """Get current configuration (without secrets)."""
    return _build_config_response(get_config(), get_roon_client())


@router.post("/config", response_model=ConfigResponse)
async def update_configuration(request: UpdateConfigRequest) -> ConfigResponse:
    """Update configuration values."""
    updates = {
        k: v
        for k, v in request.model_dump().items()
        if v is not None
    }

    if not updates:
        raise HTTPException(status_code=400, detail="No configuration values provided")

    current_config = get_config()
    prev_roon_host = current_config.roon.host
    prev_roon_port = current_config.roon.port

    try:
        config = update_config_values(updates)
    except ConfigSaveError as e:
        raise HTTPException(status_code=500, detail=str(e))

    roon_connection_changed = (
        config.roon.host != prev_roon_host
        or config.roon.port != prev_roon_port
        or "roon_token" in updates
    )
    if roon_connection_changed:
        init_roon_client(
            config.roon.host,
            config.roon.port,
            config.roon.core_id,
            config.roon.token,
        )

    if any(k in updates for k in ["llm_provider", "llm_api_key", "model_analysis", "model_generation", "ollama_url", "custom_url"]):
        init_llm_client(config.llm)

    return _build_config_response(config, get_roon_client())


@router.get("/ollama/status", response_model=OllamaStatus)
async def ollama_status(
    url: str | None = Query(None, description="Ollama URL (optional, defaults to config)")
) -> OllamaStatus:
    """Check Ollama connection status."""
    config = get_config()
    ollama_url = url or config.llm.ollama_url
    return await asyncio.to_thread(get_ollama_status, ollama_url)


@router.get("/ollama/models", response_model=OllamaModelsResponse)
async def ollama_models(
    url: str | None = Query(None, description="Ollama URL (optional, defaults to config)")
) -> OllamaModelsResponse:
    """List available Ollama models."""
    config = get_config()
    ollama_url = url or config.llm.ollama_url
    return await asyncio.to_thread(list_ollama_models, ollama_url)


@router.get("/ollama/model-info", response_model=OllamaModelInfo | None)
async def ollama_model_info(
    model: str = Query(..., description="Model name"),
    url: str | None = Query(None, description="Ollama URL (optional, defaults to config)")
) -> OllamaModelInfo | None:
    """Get detailed info about an Ollama model."""
    config = get_config()
    ollama_url = url or config.llm.ollama_url
    info = await asyncio.to_thread(get_ollama_model_info, ollama_url, model)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Model '{model}' not found")
    return info
