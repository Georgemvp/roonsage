"""Configuration loading with environment variable priority."""

import os
from pathlib import Path
from typing import Any

import yaml
from dotenv import load_dotenv

from backend.models import AppConfig, DefaultsConfig, LLMConfig, RoonConfig

# Load .env file (if it exists) - env vars take priority
load_dotenv()

# User config file path (for UI-saved settings)
USER_CONFIG_PATH = Path("data/config.user.yaml")

# In-memory cache for config.user.yaml — invalidated on every save
_user_config_cache: dict[str, Any] | None = None


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """Recursively merge override into base."""
    result = base.copy()
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def remove_empty_values(d: dict[str, Any]) -> dict[str, Any]:
    """Remove keys with empty string or None values, recursively."""
    result: dict[str, Any] = {}
    for k, v in d.items():
        if isinstance(v, dict):
            nested = remove_empty_values(v)
            if nested:  # Only include non-empty dicts
                result[k] = nested
        elif v not in (None, ""):
            result[k] = v
    return result


# Default model mappings per provider
MODEL_DEFAULTS = {
    "anthropic": {
        "analysis": "claude-sonnet-4-5",
        "generation": "claude-haiku-4-5",
    },
    "openai": {
        "analysis": "gpt-4.1",
        "generation": "gpt-4.1-mini",
    },
    "gemini": {
        "analysis": "gemini-2.5-flash",
        "generation": "gemini-2.5-flash-lite",
    },
    "ollama": {
        "analysis": "",  # Populated from Ollama API
        "generation": "",
    },
    "custom": {
        "analysis": "",  # User-specified
        "generation": "",
    },
}


def load_yaml_config(config_path: Path | None = None) -> dict[str, Any]:
    """Load configuration from YAML file."""
    if config_path is None:
        config_path = Path("config.yaml")

    if not config_path.exists():
        return {}

    with open(config_path) as f:
        return yaml.safe_load(f) or {}


def load_user_yaml_config() -> dict[str, Any]:
    """Load user configuration from config.user.yaml.

    Returns the in-memory cached copy when available.  The cache is
    invalidated by :func:`save_user_config` and :func:`invalidate_config_cache`.
    """
    global _user_config_cache
    if _user_config_cache is not None:
        return _user_config_cache
    if not USER_CONFIG_PATH.exists():
        _user_config_cache = {}
        return _user_config_cache
    with open(USER_CONFIG_PATH) as f:
        _user_config_cache = yaml.safe_load(f) or {}
    return _user_config_cache


def invalidate_config_cache() -> None:
    """Invalidate both the user-config and the global AppConfig cache.

    Call this whenever external code modifies config.user.yaml directly,
    or after a save that does *not* go through :func:`save_user_config`.
    """
    global _user_config_cache, _config
    _user_config_cache = None
    _config = None


class ConfigSaveError(Exception):
    """Raised when configuration cannot be saved."""
    pass


def save_user_config(updates: dict[str, Any]) -> None:
    """Save user configuration to config.user.yaml.

    Only saves non-empty values. Preserves existing user config.
    Invalidates the in-memory cache so the next read reflects the new file.

    Raises:
        ConfigSaveError: If file cannot be written (permissions, disk full, etc.)
    """
    global _user_config_cache
    existing = load_user_yaml_config()
    merged = deep_merge(existing, updates)
    cleaned = remove_empty_values(merged)

    try:
        with open(USER_CONFIG_PATH, "w") as f:
            yaml.dump(cleaned, f, default_flow_style=False)
        os.chmod(USER_CONFIG_PATH, 0o600)
    except PermissionError:
        raise ConfigSaveError(
            f"Permission denied writing to {USER_CONFIG_PATH}. "
            "Check that the data directory is writable. "
            "For Docker, ensure the volume is mounted with correct permissions "
            "(e.g., user directive or chown to UID 1000)."
        ) from None
    except OSError as e:
        raise ConfigSaveError(
            f"Failed to save configuration to {USER_CONFIG_PATH}: {e}. "
            "Check disk space and directory permissions."
        ) from e
    finally:
        # Invalidate cache regardless of success/failure so stale data is never served
        _user_config_cache = None


def get_env_or_yaml(
    env_key: str, yaml_value: Any, default: Any = None
) -> Any:
    """Get value from environment variable or fall back to YAML value."""
    env_value = os.environ.get(env_key)
    if env_value is not None:
        return env_value
    if yaml_value is not None:
        return yaml_value
    return default


def load_config(config_path: Path | None = None) -> AppConfig:
    """Load configuration with priority chain.

    Priority order:
    1. Environment variables (highest)
    2. config.user.yaml (UI-saved settings)
    3. config.yaml file
    4. Default values (lowest)
    """
    yaml_config = load_yaml_config(config_path)
    user_config = load_user_yaml_config()

    # Merge: user config overrides base yaml config
    yaml_config = deep_merge(yaml_config, user_config)

    # Extract nested config sections
    roon_yaml = yaml_config.get("roon", {})
    llm_yaml = yaml_config.get("llm", {})
    defaults_yaml = yaml_config.get("defaults", {})

    # Determine LLM provider - explicit setting or auto-detect from API keys
    explicit_provider = get_env_or_yaml(
        "LLM_PROVIDER", llm_yaml.get("provider"), None
    )

    # Check which API keys are available
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY") or llm_yaml.get("api_key", "")
    openai_key = os.environ.get("OPENAI_API_KEY") or llm_yaml.get("api_key", "")
    gemini_key = os.environ.get("GEMINI_API_KEY") or llm_yaml.get("api_key", "")

    # Auto-detect provider if not explicitly set
    if explicit_provider:
        provider = explicit_provider
    elif gemini_key:
        provider = "gemini"
    elif openai_key:
        provider = "openai"
    elif anthropic_key:
        provider = "anthropic"
    else:
        provider = "gemini"  # Default

    # Get API key based on provider
    if provider == "anthropic":
        api_key = anthropic_key
    elif provider == "openai":
        api_key = openai_key
    elif provider == "gemini":
        api_key = gemini_key
    elif provider == "custom":
        api_key = os.environ.get("CUSTOM_LLM_API_KEY") or llm_yaml.get("api_key", "")
    else:
        api_key = llm_yaml.get("api_key", "")

    # Get model defaults for the provider
    provider_defaults = MODEL_DEFAULTS.get(provider, MODEL_DEFAULTS["gemini"])

    # Build configuration
    roon_port_str = get_env_or_yaml("ROON_PORT", roon_yaml.get("port"), 9330)
    roon_config = RoonConfig(
        host=get_env_or_yaml("ROON_HOST", roon_yaml.get("host"), ""),
        port=int(roon_port_str) if isinstance(roon_port_str, str) else roon_port_str,
        core_id=get_env_or_yaml("ROON_CORE_ID", roon_yaml.get("core_id"), ""),
        token=get_env_or_yaml("ROON_TOKEN", roon_yaml.get("token"), ""),
        extension_id=get_env_or_yaml("ROON_EXTENSION_ID", roon_yaml.get("extension_id"), "com.roonsage.roon"),
        display_name=get_env_or_yaml("ROON_DISPLAY_NAME", roon_yaml.get("display_name"), "RoonSage"),
        display_version=get_env_or_yaml("ROON_DISPLAY_VERSION", roon_yaml.get("display_version"), "1.0.0"),
    )

    # Get local provider settings
    ollama_url = get_env_or_yaml(
        "OLLAMA_URL", llm_yaml.get("ollama_url"), "http://localhost:11434"
    )
    ollama_context_window_str = get_env_or_yaml(
        "OLLAMA_CONTEXT_WINDOW", llm_yaml.get("ollama_context_window"), 32768
    )
    ollama_context_window = int(ollama_context_window_str) if isinstance(
        ollama_context_window_str, str
    ) else ollama_context_window_str
    custom_url = get_env_or_yaml(
        "CUSTOM_LLM_URL", llm_yaml.get("custom_url"), ""
    )
    custom_context_window_str = get_env_or_yaml(
        "CUSTOM_CONTEXT_WINDOW", llm_yaml.get("custom_context_window"), 32768
    )
    # Handle string from env var
    custom_context_window = int(custom_context_window_str) if isinstance(
        custom_context_window_str, str
    ) else custom_context_window_str

    # Determine model names with proper fallback chain
    # When env var overrides to a DIFFERENT provider, use that provider's defaults
    # (prevents using custom provider's model names with gemini provider, etc.)
    env_provider = os.environ.get("LLM_PROVIDER")
    yaml_provider = llm_yaml.get("provider")
    provider_changed_by_env = env_provider and env_provider != yaml_provider

    if provider_changed_by_env:
        # Env var switched to different provider - use new provider's defaults
        # (unless model env vars are also explicitly set)
        model_analysis = os.environ.get("LLM_MODEL_ANALYSIS") or provider_defaults["analysis"]
        model_generation = os.environ.get("LLM_MODEL_GENERATION") or provider_defaults["generation"]
    else:
        # Same provider or no env override - YAML models take precedence
        model_analysis = get_env_or_yaml(
            "LLM_MODEL_ANALYSIS",
            llm_yaml.get("model_analysis"),
            provider_defaults["analysis"],
        )
        model_generation = get_env_or_yaml(
            "LLM_MODEL_GENERATION",
            llm_yaml.get("model_generation"),
            provider_defaults["generation"],
        )

    llm_config = LLMConfig(
        provider=provider,
        api_key=api_key,
        model_analysis=model_analysis,
        model_generation=model_generation,
        smart_generation=llm_yaml.get("smart_generation", False),
        ollama_url=ollama_url,
        ollama_context_window=ollama_context_window,
        custom_url=custom_url,
        custom_context_window=custom_context_window,
    )

    defaults_config = DefaultsConfig(
        track_count=defaults_yaml.get("track_count", 25)
    )

    return AppConfig(
        roon=roon_config,
        llm=llm_config,
        defaults=defaults_config,
    )


# Global config instance (loaded on import, can be refreshed)
_config: AppConfig | None = None


def get_config() -> AppConfig:
    """Get the current configuration, loading if necessary."""
    global _config
    if _config is None:
        _config = load_config()
    return _config


def get_qobuz_config() -> dict[str, str]:
    """Return Qobuz credentials from environment variables or config.user.yaml.

    Priority: environment variables > config.user.yaml > empty string.
    Returns a dict with keys: email, password.
    (app_id is auto-extracted from the Qobuz web player — not configurable.)
    """
    user_config = load_user_yaml_config()
    qobuz_yaml = user_config.get("qobuz", {})
    return {
        "email": get_env_or_yaml("QOBUZ_EMAIL", qobuz_yaml.get("email"), ""),
        "password": get_env_or_yaml("QOBUZ_PASSWORD", qobuz_yaml.get("password"), ""),
    }


def get_acoustid_config() -> dict:
    """Return AcoustID settings from environment variables or config.user.yaml.

    Priority: environment variables > config.user.yaml > defaults.
    Returns a dict with keys: api_key (str), enabled (bool), auto_verify_qobuz (bool).
    """
    user_config = load_user_yaml_config()
    # Also check base config.yaml for acoustid section
    base_config = load_yaml_config()
    # Merge: user overrides base
    acoustid_yaml: dict = {}
    acoustid_yaml.update(base_config.get("acoustid", {}))
    acoustid_yaml.update(user_config.get("acoustid", {}))

    api_key = get_env_or_yaml("ACOUSTID_API_KEY", acoustid_yaml.get("api_key"), "")
    enabled_raw = get_env_or_yaml(
        "ACOUSTID_ENABLED", acoustid_yaml.get("enabled"), False
    )
    auto_verify_raw = get_env_or_yaml(
        "ACOUSTID_AUTO_VERIFY_QOBUZ", acoustid_yaml.get("auto_verify_qobuz"), False
    )

    def _to_bool(val) -> bool:
        if isinstance(val, bool):
            return val
        if isinstance(val, str):
            return val.lower() in ("1", "true", "yes")
        return bool(val)

    return {
        "api_key": api_key,
        "enabled": _to_bool(enabled_raw) and bool(api_key),
        "auto_verify_qobuz": _to_bool(auto_verify_raw),
    }


def get_listenbrainz_config() -> dict[str, str]:
    """Return ListenBrainz credentials from environment variables or config.user.yaml.

    Priority: environment variables > config.user.yaml > empty string.
    Returns a dict with keys: token, username.
    """
    user_config = load_user_yaml_config()
    lb_yaml = user_config.get("listenbrainz", {})
    return {
        "token": get_env_or_yaml("LISTENBRAINZ_TOKEN", lb_yaml.get("token"), ""),
        "username": get_env_or_yaml("LISTENBRAINZ_USERNAME", lb_yaml.get("username"), ""),
    }


def get_lastfm_config() -> dict[str, str]:
    """Return Last.fm credentials from environment variables or config.user.yaml.

    Priority: environment variables > config.user.yaml > empty string.
    Returns a dict with keys: api_key, api_secret, session_key, username.
    """
    user_config = load_user_yaml_config()
    lf_yaml = user_config.get("lastfm", {})
    return {
        "api_key":     get_env_or_yaml("LASTFM_API_KEY",     lf_yaml.get("api_key"), ""),
        "api_secret":  get_env_or_yaml("LASTFM_API_SECRET",  lf_yaml.get("api_secret"), ""),
        "session_key": get_env_or_yaml("LASTFM_SESSION_KEY", lf_yaml.get("session_key"), ""),
        "username":    get_env_or_yaml("LASTFM_USERNAME",     lf_yaml.get("username"), ""),
    }


_DEFAULT_ENABLED_EVENTS = ["playlist_generated", "library_sync_complete"]


def get_notifications_config() -> dict[str, Any]:
    """Return notification settings from environment variables or config.user.yaml.

    Priority: environment variables > config.user.yaml > defaults.
    Returns a dict with keys: discord_webhook_url, telegram_bot_token,
    telegram_chat_id, webhook_url, enabled_events.
    """
    user_config = load_user_yaml_config()
    notif_yaml = user_config.get("notifications", {})
    return {
        "discord_webhook_url": get_env_or_yaml(
            "DISCORD_WEBHOOK_URL", notif_yaml.get("discord_webhook_url"), ""
        ),
        "telegram_bot_token": get_env_or_yaml(
            "TELEGRAM_BOT_TOKEN", notif_yaml.get("telegram_bot_token"), ""
        ),
        "telegram_chat_id": get_env_or_yaml(
            "TELEGRAM_CHAT_ID", notif_yaml.get("telegram_chat_id"), ""
        ),
        "webhook_url": get_env_or_yaml(
            "WEBHOOK_URL", notif_yaml.get("webhook_url"), ""
        ),
        "enabled_events": notif_yaml.get(
            "enabled_events", list(_DEFAULT_ENABLED_EVENTS)
        ),
    }


def save_notifications_config(updates: dict[str, Any]) -> None:
    """Persist notification settings to config.user.yaml."""
    notif_updates: dict[str, Any] = {}
    for key in (
        "discord_webhook_url",
        "telegram_bot_token",
        "telegram_chat_id",
        "webhook_url",
        "enabled_events",
    ):
        if key in updates:
            notif_updates[key] = updates[key]

    if notif_updates:
        save_user_config({"notifications": notif_updates})


# =============================================================================
# Runtime settings (env-only — read via these accessors, never os.environ
# directly in the rest of the codebase).
# =============================================================================


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.lower() in ("1", "true", "yes", "on")


def get_roonsage_password() -> str | None:
    """HTTP Basic Auth password (None = auth disabled)."""
    return os.environ.get("ROONSAGE_PASSWORD") or None


def get_cors_origins() -> list[str]:
    """Allowed CORS origins. Defaults to the local app URL only."""
    return [
        o.strip()
        for o in os.environ.get("CORS_ORIGINS", "http://localhost:5765").split(",")
        if o.strip()
    ]


def get_watchlist_scan_interval_seconds() -> int:
    """Interval between watchlist scans (env: WATCHLIST_SCAN_INTERVAL_HOURS)."""
    return int(os.environ.get("WATCHLIST_SCAN_INTERVAL_HOURS", "12")) * 3600


def get_audio_features_enabled() -> bool:
    """True when the audio-features worker + DJ-set endpoints should run."""
    return _env_bool("AUDIO_FEATURES_ENABLED", False)


def get_audio_features_full() -> bool:
    """True for full Spotify-style feature vector, False for BPM + key only."""
    raw = os.environ.get("AUDIO_FEATURES_FULL", "true").lower()
    return raw not in ("0", "false", "no", "off")


def get_music_library_path() -> Path:
    """Filesystem root for audio analysis."""
    return Path(os.environ.get("MUSIC_LIBRARY_PATH", "/music"))


def get_music_path_map() -> tuple[str, str]:
    """(src, dst) path remap from Roon-reported paths to container paths."""
    return (
        os.environ.get("MUSIC_PATH_MAP_FROM", ""),
        os.environ.get("MUSIC_PATH_MAP_TO", ""),
    )


def get_enrichment_skip_mb() -> bool:
    """True = skip MusicBrainz, use Last.fm only (~50× speed)."""
    return _env_bool("ENRICHMENT_SKIP_MB", False)


# ---------------------------------------------------------------------------
# CLAP text-to-audio search (v13.0)
# ---------------------------------------------------------------------------


def get_clap_enabled() -> bool:
    """True when the CLAP text-to-audio search subsystem should run.

    Off by default because the CLAP model is ~600 MB and downloads on first use.
    """
    return _env_bool("CLAP_ENABLED", False)


def get_clap_model() -> str:
    return os.environ.get("CLAP_MODEL", "laion/larger_clap_music_and_speech")


def get_clap_batch_size() -> int:
    try:
        return max(1, int(os.environ.get("CLAP_BATCH_SIZE", "4")))
    except ValueError:
        return 4


def get_clap_cache_dir() -> Path:
    return Path(os.environ.get("CLAP_CACHE_DIR", "/app/data/.clap_cache"))


# ---------------------------------------------------------------------------
# Lyrics semantic search (v13.0)
# ---------------------------------------------------------------------------


def get_lyrics_search_enabled() -> bool:
    return _env_bool("LYRICS_SEARCH_ENABLED", False)


def get_lyrics_model() -> str:
    return os.environ.get("LYRICS_MODEL", "Alibaba-NLP/gte-multilingual-base")


def is_llm_provider_from_env() -> bool:
    """True when LLM_PROVIDER is set as an environment variable."""
    return os.environ.get("LLM_PROVIDER") is not None


def refresh_config(config_path: Path | None = None) -> AppConfig:
    """Reload configuration from file and environment."""
    global _config
    _config = load_config(config_path)
    return _config


def update_config_values(updates: dict[str, Any]) -> AppConfig:
    """Update configuration values and persist to config.user.yaml.

    Changes are saved to config.user.yaml so they survive server restarts.
    Environment variables still take priority over saved settings.
    """
    global _config
    if _config is None:
        _config = load_config()

    # Create updated config by merging updates
    roon_updates = {}
    llm_updates = {}
    qobuz_updates = {}

    if "roon_host" in updates and updates["roon_host"]:
        roon_updates["host"] = updates["roon_host"]
    if "roon_port" in updates and updates["roon_port"]:
        roon_updates["port"] = updates["roon_port"]
    if "roon_token" in updates and updates["roon_token"]:
        roon_updates["token"] = updates["roon_token"]
    if "roon_core_id" in updates and updates["roon_core_id"]:
        roon_updates["core_id"] = updates["roon_core_id"]

    if "llm_provider" in updates and updates["llm_provider"]:
        new_provider = updates["llm_provider"]
        llm_updates["provider"] = new_provider

        # Auto-select API key from environment if provider changed and no key provided
        if not updates.get("llm_api_key"):
            env_keys = {
                "anthropic": os.environ.get("ANTHROPIC_API_KEY", ""),
                "openai": os.environ.get("OPENAI_API_KEY", ""),
                "gemini": os.environ.get("GEMINI_API_KEY", ""),
            }
            if env_keys.get(new_provider):
                llm_updates["api_key"] = env_keys[new_provider]

        # Auto-select default models for new provider
        if new_provider in MODEL_DEFAULTS:
            defaults = MODEL_DEFAULTS[new_provider]
            if not updates.get("model_analysis"):
                llm_updates["model_analysis"] = defaults["analysis"]
            if not updates.get("model_generation"):
                llm_updates["model_generation"] = defaults["generation"]

    if "llm_api_key" in updates and updates["llm_api_key"]:
        llm_updates["api_key"] = updates["llm_api_key"]
    if "model_analysis" in updates and updates["model_analysis"]:
        llm_updates["model_analysis"] = updates["model_analysis"]
    if "model_generation" in updates and updates["model_generation"]:
        llm_updates["model_generation"] = updates["model_generation"]

    # Local provider settings
    if "ollama_url" in updates and updates["ollama_url"]:
        llm_updates["ollama_url"] = updates["ollama_url"]
    if "ollama_context_window" in updates and updates["ollama_context_window"]:
        llm_updates["ollama_context_window"] = updates["ollama_context_window"]
    if "custom_url" in updates and updates["custom_url"]:
        llm_updates["custom_url"] = updates["custom_url"]
    if "custom_context_window" in updates and updates["custom_context_window"]:
        llm_updates["custom_context_window"] = updates["custom_context_window"]

    # Qobuz playlist save settings (app_id auto-extracted — not stored)
    if "qobuz_email" in updates and updates["qobuz_email"]:
        qobuz_updates["email"] = updates["qobuz_email"]
    if "qobuz_password" in updates and updates["qobuz_password"]:
        qobuz_updates["password"] = updates["qobuz_password"]

    # Create new config with updates
    new_roon = _config.roon.model_copy(update=roon_updates)
    new_llm = _config.llm.model_copy(update=llm_updates)

    _config = AppConfig(
        roon=new_roon,
        llm=new_llm,
        defaults=_config.defaults,
    )

    # Persist to user config file
    user_updates: dict[str, Any] = {}
    if roon_updates:
        user_updates["roon"] = roon_updates
    if llm_updates:
        user_updates["llm"] = llm_updates
    if qobuz_updates:
        user_updates["qobuz"] = qobuz_updates

    if user_updates:
        save_user_config(user_updates)

    return _config
