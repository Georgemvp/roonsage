"""Configuration and Ollama endpoints."""

import asyncio

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import JSONResponse

from backend.config import ConfigSaveError, get_config, get_qobuz_config, update_config_values
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
from backend.qobuz_api import init_qobuz_api_client
from backend.dependencies import _is_llm_configured, _build_config_response
from backend import library_cache

router = APIRouter(prefix="/api", tags=["config"])


@router.get("/health", response_model=HealthResponse)
async def health_check():
    """Check application health status. Returns 503 when critical dependencies are down."""
    config = get_config()
    roon_client = get_roon_client()
    roon_ok = roon_client.is_connected() if roon_client else False
    llm_ok = _is_llm_configured(config)
    db_ok = False
    try:
        conn = library_cache.get_db_connection()
        conn.execute("SELECT 1")
        conn.close()
        db_ok = True
    except Exception:
        pass

    status = "healthy" if (roon_ok and llm_ok and db_ok) else "degraded"
    response = HealthResponse(
        status=status,
        roon_connected=roon_ok,
        llm_configured=llm_ok,
        database_ok=db_ok,
    )

    if status == "degraded":
        return JSONResponse(content=response.model_dump(), status_code=503)
    return response


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

    if any(k in updates for k in ["qobuz_app_id", "qobuz_email", "qobuz_password"]):
        qobuz_cfg = get_qobuz_config()
        init_qobuz_api_client(
            qobuz_cfg.get("app_id", ""),
            qobuz_cfg.get("email", ""),
            qobuz_cfg.get("password", ""),
        )

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
