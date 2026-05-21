"""Setup / onboarding endpoints."""

import asyncio
import logging
import os

import httpx
from fastapi import APIRouter

from backend import library_cache
from backend.config import (
    ConfigSaveError,
    get_config,
    load_user_yaml_config,
    save_user_config,
    update_config_values,
)
from backend.dependencies import _is_llm_configured
from backend.llm_client import get_ollama_status, init_llm_client
from backend.models import (
    SetupCompleteResponse,
    SetupStatusResponse,
    SyncProgress,
    ValidateAIRequest,
    ValidateAIResponse,
    ValidateRoonRequest,
    ValidateRoonResponse,
)
from backend.qobuz_api import get_qobuz_api_client
from backend.roon_client import RoonClient as RoonClientInstance
from backend.roon_client import get_roon_client, init_roon_client

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/setup", tags=["setup"])


@router.get("/status", response_model=SetupStatusResponse)
async def setup_status() -> SetupStatusResponse:
    """Get onboarding checklist state for the setup wizard."""
    config = get_config()
    roon_client = get_roon_client()

    # Check data dir writable by actually creating+deleting a temp file
    data_dir = library_cache.DATA_DIR
    data_dir_writable = False
    try:
        data_dir.mkdir(parents=True, exist_ok=True)
        test_file = data_dir / ".write_test"
        test_file.write_text("test")
        test_file.unlink()
        data_dir_writable = True
    except OSError:
        pass

    roon_connected = roon_client.is_connected() if roon_client else False
    roon_error = roon_client.get_error() if roon_client and not roon_connected else None

    llm_configured = _is_llm_configured(config)
    llm_from_env = any(
        os.environ.get(k)
        for k in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "OLLAMA_URL", "CUSTOM_LLM_URL")
    )

    library_synced = (
        library_cache.has_cached_tracks() and not library_cache.is_cache_stale()
    )
    sync_state = library_cache.get_sync_state()
    sync_progress = None
    if sync_state["sync_progress"]:
        sync_progress = SyncProgress(
            phase=sync_state["sync_progress"]["phase"],
            current=sync_state["sync_progress"]["current"],
            total=sync_state["sync_progress"]["total"],
        )

    user_config = load_user_yaml_config()
    setup_complete = user_config.get("setup", {}).get("complete", False)

    # Inline Qobuz availability check — runs in a thread to avoid blocking the
    # event loop.  Deliberately skips _browse_lock so it never blocks behind a
    # long library-sync operation; for a status endpoint the occasional race is
    # acceptable.
    qobuz_available = False
    if roon_connected and roon_client and roon_client._api:
        def _check_qobuz_inline() -> bool:
            try:
                browse_result = roon_client._api.browse_browse({
                    "hierarchy": "browse",
                    "pop_all": True,
                })
                if not browse_result:
                    logger.warning("Qobuz inline check: browse_browse returned None")
                    return False
                count = browse_result.get("list", {}).get("count", 0)
                logger.info("Qobuz inline check: browse root count=%d", count)
                if count == 0:
                    return False
                loaded = roon_client._api.browse_load({
                    "hierarchy": "browse",
                    "count": count,
                })
                items = loaded.get("items", []) if loaded else []
                logger.info(
                    "Qobuz inline check: root items=%s",
                    [i.get("title") for i in items],
                )
                for item in items:
                    if "qobuz" in (item.get("title") or "").lower():
                        logger.info("Qobuz inline check: FOUND '%s'", item.get("title"))
                        return True
                logger.info("Qobuz inline check: not found in root items")
                return False
            except Exception as _e:
                logger.warning("Qobuz inline check exception: %s", _e, exc_info=True)
                return False

        try:
            qobuz_available = await asyncio.to_thread(_check_qobuz_inline)
        except Exception as _qe:
            logger.warning("Qobuz availability thread failed: %s", _qe, exc_info=True)

    qobuz_api_client = get_qobuz_api_client()
    qobuz_save_available = qobuz_api_client is not None and qobuz_api_client.is_authenticated()

    return SetupStatusResponse(
        data_dir_writable=data_dir_writable,
        process_uid=getattr(os, "getuid", lambda: 0)(),
        process_gid=getattr(os, "getgid", lambda: 0)(),
        data_dir=str(data_dir),
        roon_connected=roon_connected,
        roon_error=roon_error,
        roon_from_env=bool(os.environ.get("ROON_HOST")),
        llm_configured=llm_configured,
        llm_provider=config.llm.provider,
        llm_from_env=llm_from_env,
        library_synced=library_synced,
        track_count=sync_state["track_count"],
        synced_at=sync_state.get("synced_at"),
        is_syncing=sync_state["is_syncing"],
        sync_progress=sync_progress,
        setup_complete=setup_complete,
        qobuz_available=qobuz_available,
        qobuz_save_available=qobuz_save_available,
    )


@router.post("/validate-roon", response_model=ValidateRoonResponse)
async def setup_validate_roon(request: ValidateRoonRequest) -> ValidateRoonResponse:
    """Validate Roon connection and save on success.

    The Roon registration handshake (``RoonApi(blocking_init=True)``) blocks
    until the user enables the extension in Roon → Settings → Extensions.
    The RoonClient constructor delegates that handshake to a background
    daemon thread and returns immediately, so we must wait here for the
    thread to finish before reading its state — otherwise we always return
    "Connection failed" while the handshake is still in flight.
    """
    try:
        temp_client = await asyncio.to_thread(
            RoonClientInstance,
            request.roon_host,
            request.roon_port,
        )
    except Exception as e:
        return ValidateRoonResponse(success=False, error=str(e))

    await temp_client.wait_until_ready(timeout=60.0)

    if temp_client.needs_authorization():
        return ValidateRoonResponse(
            success=False,
            needs_authorization=True,
            error=temp_client.get_error()
            or "Open Roon → Settings → Extensions and enable RoonSage, then click Connect again.",
        )

    if not temp_client.is_connected():
        return ValidateRoonResponse(
            success=False,
            error=temp_client.get_error()
            or "Connection timed out — make sure Roon Core is reachable and try again.",
        )

    core_name = temp_client.get_core_name()
    token = temp_client.get_token() or ""
    core_id = temp_client.get_core_id() or ""

    try:
        update_config_values({
            "roon_host": request.roon_host,
            "roon_port": request.roon_port,
            "roon_token": token,
            "roon_core_id": core_id,
        })
    except ConfigSaveError as e:
        return ValidateRoonResponse(success=False, error=str(e))

    init_roon_client(request.roon_host, request.roon_port, core_id, token)

    return ValidateRoonResponse(
        success=True,
        core_name=core_name,
    )


@router.post("/validate-ai", response_model=ValidateAIResponse)
async def setup_validate_ai(request: ValidateAIRequest) -> ValidateAIResponse:
    """Validate AI provider credentials and save on success."""
    provider = request.provider
    provider_name = {
        "anthropic": "Anthropic (Claude)",
        "openai": "OpenAI (GPT)",
        "gemini": "Google (Gemini)",
        "ollama": "Ollama (Local)",
        "custom": "Custom (OpenAI-compatible)",
    }.get(provider, provider)

    try:
        if provider == "gemini":
            import google.genai as genai
            client = genai.Client(api_key=request.api_key)
            await asyncio.to_thread(lambda: list(client.models.list()))

        elif provider == "openai":
            import openai
            client = openai.OpenAI(api_key=request.api_key)
            await asyncio.to_thread(lambda: list(client.models.list()))

        elif provider == "anthropic":
            import anthropic
            client = anthropic.Anthropic(api_key=request.api_key)
            await asyncio.to_thread(
                client.messages.create,
                model="claude-haiku-4-5",
                max_tokens=1,
                messages=[{"role": "user", "content": "hi"}],
            )

        elif provider == "ollama":
            status = await asyncio.to_thread(get_ollama_status, request.ollama_url or "http://localhost:11434")
            if not status.connected:
                return ValidateAIResponse(
                    success=False,
                    error=status.error or "Cannot connect to Ollama",
                    provider_name=provider_name,
                )

        elif provider == "custom":
            if not request.custom_url:
                return ValidateAIResponse(
                    success=False, error="Custom URL is required", provider_name=provider_name
                )
            headers = {}
            if request.api_key:
                headers["Authorization"] = f"Bearer {request.api_key}"
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(f"{request.custom_url.rstrip('/')}/models", headers=headers)
                resp.raise_for_status()

        else:
            return ValidateAIResponse(
                success=False, error=f"Unknown provider: {provider}", provider_name=provider_name
            )

    except Exception as e:
        error_msg = str(e)
        if "401" in error_msg or "Unauthorized" in error_msg or "AuthenticationError" in error_msg:
            error_msg = "Invalid API key"
        elif "Could not resolve" in error_msg or "Connection" in error_msg.lower():
            error_msg = f"Cannot connect to {provider_name}"
        return ValidateAIResponse(success=False, error=error_msg, provider_name=provider_name)

    config_updates = {"llm_provider": provider}
    if request.api_key:
        config_updates["llm_api_key"] = request.api_key
    if provider == "ollama" and request.ollama_url:
        config_updates["ollama_url"] = request.ollama_url
    if provider == "custom" and request.custom_url:
        config_updates["custom_url"] = request.custom_url

    try:
        config = update_config_values(config_updates)
        init_llm_client(config.llm)
    except ConfigSaveError as e:
        return ValidateAIResponse(success=False, error=str(e), provider_name=provider_name)

    return ValidateAIResponse(success=True, provider_name=provider_name)


@router.post("/complete", response_model=SetupCompleteResponse)
async def setup_complete() -> SetupCompleteResponse:
    """Mark onboarding as complete."""
    try:
        save_user_config({"setup": {"complete": True}})
    except Exception as e:
        logger.warning("Failed to save setup complete flag: %s", e)
    return SetupCompleteResponse(success=True)


@router.post("/validate-listenbrainz")
async def validate_listenbrainz(request: dict) -> dict:
    """Validate ListenBrainz token and optionally save to config.

    Request body: {"token": str, "username": str}
    """
    from backend.listenbrainz_client import ListenBrainzClient  # noqa: PLC0415

    token = request.get("token", "")
    username = request.get("username", "")

    if not token:
        return {"valid": False, "error": "Token is required"}

    client = ListenBrainzClient(token=token, username=username)
    try:
        result = await client.validate_token()
    finally:
        await client.close()

    if result.get("valid"):
        # Save to config
        try:
            save_user_config({"listenbrainz": {"token": token, "username": username}})
        except Exception as save_exc:
            logger.warning("Failed to save LB config: %s", save_exc)
        # Re-init the singleton client
        try:
            from backend.listenbrainz_client import init_lb_client  # noqa: PLC0415
            from backend.listenbrainz_sync import init_sync_instance  # noqa: PLC0415
            lb = init_lb_client(token, username)
            init_sync_instance(lb)
        except Exception as init_exc:
            logger.warning("Failed to re-init LB client: %s", init_exc)

    return result


@router.post("/validate-lastfm")
async def validate_lastfm(request: dict) -> dict:
    """Validate Last.fm credentials and optionally save to config.

    Request body: {"api_key": str, "api_secret": str, "username": str}

    Tests that the API key is valid by fetching user info via user.getInfo.
    Does NOT require a session key — validates read-only credentials only.
    The session key is obtained via the auth flow endpoints.
    """
    from backend.lastfm_client import LastFmClient  # noqa: PLC0415

    api_key    = request.get("api_key", "")
    api_secret = request.get("api_secret", "")
    username   = request.get("username", "")

    if not api_key:
        return {"valid": False, "error": "API key is required"}
    if not api_secret:
        return {"valid": False, "error": "API secret is required"}
    if not username:
        return {"valid": False, "error": "Username is required"}

    client = LastFmClient(
        api_key=api_key,
        api_secret=api_secret,
        username=username,
    )
    try:
        result = await client.validate()
    finally:
        await client.close()

    if result.get("valid"):
        # Save credentials (but NOT session_key — that requires the auth flow)
        try:
            save_user_config({
                "lastfm": {
                    "api_key":    api_key,
                    "api_secret": api_secret,
                    "username":   username,
                }
            })
        except Exception as save_exc:
            logger.warning("Failed to save Last.fm config: %s", save_exc)
        # Re-init the singleton client (session_key loaded from existing config)
        try:
            from backend.config import get_lastfm_config  # noqa: PLC0415
            from backend.lastfm_client import init_lf_client  # noqa: PLC0415
            from backend.lastfm_sync import init_lf_sync_instance  # noqa: PLC0415
            existing_cfg = get_lastfm_config()
            lf = init_lf_client(
                api_key=api_key,
                api_secret=api_secret,
                session_key=existing_cfg.get("session_key", ""),
                username=username,
            )
            init_lf_sync_instance(lf)
        except Exception as init_exc:
            logger.warning("Failed to re-init Last.fm client: %s", init_exc)

    return result
