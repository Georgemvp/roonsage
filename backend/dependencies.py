"""Shared dependency helpers for FastAPI route modules."""

import os
import secrets
import time
from collections import defaultdict

from fastapi import HTTPException, Request
from backend.models import ConfigResponse
from backend.llm_client import (
    get_max_tracks_for_model,
    get_max_albums_for_model,
    get_model_cost,
)
from backend.version import get_version

# =============================================================================
# Optional HTTP Basic Auth
# =============================================================================

# Set MEDIASAGE_PASSWORD to enable basic auth on all endpoints.
# Leave unset (default) for backward-compatible open access.
MEDIASAGE_PASSWORD: str | None = os.environ.get("MEDIASAGE_PASSWORD") or None

# =============================================================================
# In-memory rate limiter for LLM endpoints
# =============================================================================

_rate_limits: dict[str, list[float]] = defaultdict(list)
_RATE_WINDOW = 3600  # seconds (1 hour)
_RATE_MAX = 30       # max LLM generations per IP per window


def check_rate_limit(request: Request) -> None:
    """FastAPI dependency: enforce per-IP rate limit for LLM endpoints."""
    ip = request.client.host if request.client else "unknown"
    now = time.time()
    # Evict timestamps outside the current window
    _rate_limits[ip] = [t for t in _rate_limits[ip] if now - t < _RATE_WINDOW]
    if len(_rate_limits[ip]) >= _RATE_MAX:
        raise HTTPException(
            status_code=429,
            detail="Rate limit exceeded. Try again later.",
        )
    _rate_limits[ip].append(now)


def _is_llm_configured(config) -> bool:
    """Check if an LLM provider is configured (API key for cloud, URL for local)."""
    if config.llm.provider == "ollama" and config.llm.ollama_url:
        return True
    if config.llm.provider == "custom" and config.llm.custom_url:
        return True
    return bool(config.llm.api_key)


def _build_config_response(config, roon_client) -> ConfigResponse:
    """Build a ConfigResponse from the current config and Roon client state."""
    generation_model = config.llm.model_generation
    analysis_model = config.llm.model_analysis
    max_tracks = get_max_tracks_for_model(generation_model, config=config.llm)
    max_albums = get_max_albums_for_model(generation_model, config=config.llm)

    is_local = config.llm.provider in ("ollama", "custom")
    gen_costs = get_model_cost(generation_model, config.llm)
    analysis_costs = get_model_cost(analysis_model, config.llm)

    return ConfigResponse(
        version=get_version(),
        roon_host=config.roon.host,
        roon_port=config.roon.port,
        roon_connected=roon_client.is_connected() if roon_client else False,
        roon_token_set=bool(config.roon.token),
        llm_provider=config.llm.provider,
        llm_configured=_is_llm_configured(config),
        llm_api_key_set=bool(config.llm.api_key),
        model_analysis=analysis_model,
        model_generation=generation_model,
        max_tracks_to_ai=max_tracks,
        max_albums_to_ai=max_albums,
        cost_per_million_input=gen_costs["input"],
        cost_per_million_output=gen_costs["output"],
        analysis_cost_per_million_input=analysis_costs["input"],
        analysis_cost_per_million_output=analysis_costs["output"],
        defaults=config.defaults,
        ollama_url=config.llm.ollama_url,
        ollama_context_window=config.llm.ollama_context_window,
        custom_url=config.llm.custom_url,
        custom_context_window=config.llm.custom_context_window,
        is_local_provider=is_local,
        provider_from_env=os.environ.get("LLM_PROVIDER") is not None,
    )
