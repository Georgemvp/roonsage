"""LLM client abstraction for Anthropic, OpenAI, Google Gemini, Ollama, and custom providers."""

import asyncio
import json
import logging
import re
from dataclasses import dataclass
from typing import Any

import anthropic
import httpx
import openai
from google import genai
from google.genai import types as genai_types
from json_repair import repair_json

from backend.models import (
    LLMConfig,
    OllamaModel,
    OllamaModelInfo,
    OllamaModelsResponse,
    OllamaStatus,
)

logger = logging.getLogger(__name__)


# Cost per million tokens (updated Feb 2026)
MODEL_COSTS = {
    # Anthropic models (input/output per million tokens)
    "claude-sonnet-4-5": {"input": 3.00, "output": 15.00},
    "claude-haiku-4-5": {"input": 1.00, "output": 5.00},
    # OpenAI models
    "gpt-4.1": {"input": 2.00, "output": 8.00},
    "gpt-4.1-mini": {"input": 0.40, "output": 1.60},
    # Google Gemini models
    "gemini-2.5-pro": {"input": 1.25, "output": 5.00},
    "gemini-2.5-flash": {"input": 0.30, "output": 2.50},
    "gemini-2.5-flash-lite": {"input": 0.10, "output": 0.40},
}

# Context limits per model (in tokens) - used to calculate max tracks
MODEL_CONTEXT_LIMITS = {
    # Anthropic
    "claude-sonnet-4-5": 200_000,
    "claude-haiku-4-5": 200_000,
    # OpenAI
    "gpt-4.1": 128_000,
    "gpt-4.1-mini": 128_000,
    # Google Gemini
    "gemini-2.5-pro": 1_000_000,
    "gemini-2.5-flash": 1_000_000,
    "gemini-2.5-flash-lite": 1_000_000,
    # Gemma 4 (local via Ollama — MLX-optimised for Apple Silicon)
    "gemma4:e2b": 128_000,
    "gemma4:e2b-mlx": 128_000,
    "gemma4:e4b": 128_000,
    "gemma4:e4b-mlx": 128_000,
    "gemma4:26b": 256_000,
    "gemma4:26b-mlx": 256_000,
    "gemma4:31b": 256_000,
    "gemma4:31b-mlx": 256_000,
    "gemma4:latest": 128_000,
    # RoonSage custom model (Gemma 4 E4B-MLX + tuned Modelfile, 16 GB RAM cap)
    "roonsage": 65_536,
}

# Tokens per track (based on real-world testing, Feb 2026)
TOKENS_PER_TRACK = 40

# Tokens per album for recommendation flow (artist, album, year, genres)
TOKENS_PER_ALBUM = 25


@dataclass
class LLMResponse:
    """Response from an LLM call."""

    content: str
    input_tokens: int
    output_tokens: int
    model: str
    provider: str = ""

    @property
    def total_tokens(self) -> int:
        """Total tokens used."""
        return self.input_tokens + self.output_tokens

    def estimated_cost(self) -> float:
        """Estimate cost in USD. Local providers (ollama, custom) are always free."""
        if self.provider in ("ollama", "custom"):
            return 0.0
        return estimate_cost_for_model(self.model, self.input_tokens, self.output_tokens)


def estimate_cost_for_model(
    model: str, input_tokens: int, output_tokens: int, config: LLMConfig | None = None
) -> float:
    """Estimate cost in USD for a given model and token counts.

    Args:
        model: Model name (e.g., 'claude-haiku-4-5', 'gpt-4.1-mini')
        input_tokens: Estimated input token count
        output_tokens: Estimated output token count
        config: Optional LLMConfig to check for local providers

    Returns:
        Estimated cost in USD (0.0 for local providers)
    """
    costs = get_model_cost(model, config)
    input_cost = (input_tokens / 1_000_000) * costs["input"]
    output_cost = (output_tokens / 1_000_000) * costs["output"]
    return input_cost + output_cost


class LLMClient:
    """Unified async LLM client for Anthropic, OpenAI, Gemini, Ollama, and custom providers."""

    def __init__(self, config: LLMConfig):
        """Initialize LLM client.

        Args:
            config: LLM configuration with provider and API key
        """
        self.config = config
        self.provider = config.provider
        self._client: Any = None
        # Reusable async httpx client for Ollama (created lazily, closed in close())
        self._ollama_client: httpx.AsyncClient | None = None

        if config.provider == "anthropic":
            self._client = anthropic.AsyncAnthropic(api_key=config.api_key)
        elif config.provider == "openai":
            self._client = openai.AsyncOpenAI(api_key=config.api_key)
        elif config.provider == "gemini":
            self._client = genai.Client(api_key=config.api_key)
        elif config.provider == "custom":
            # Custom OpenAI-compatible endpoint
            self._client = openai.AsyncOpenAI(
                api_key=config.api_key or "not-needed",
                base_url=config.custom_url,
            )
        elif config.provider == "ollama":
            # Persistent AsyncClient reused across calls (closed in shutdown)
            self._ollama_client = httpx.AsyncClient(timeout=httpx.Timeout(600.0))

    async def close(self) -> None:
        """Release resources held by this client (e.g. Ollama connection pool)."""
        if self._ollama_client is not None:
            await self._ollama_client.aclose()
            self._ollama_client = None

    # ------------------------------------------------------------------
    # Private async completion methods
    # ------------------------------------------------------------------

    async def _complete_anthropic(
        self, prompt: str, system: str, model: str
    ) -> LLMResponse:
        """Make an async completion request to Anthropic."""
        logger.info("Calling Anthropic API with %d char prompt", len(prompt))
        response = await self._client.messages.create(
            model=model,
            max_tokens=8192,
            system=system,
            messages=[{"role": "user", "content": prompt}],
        )
        logger.debug("Anthropic response received")

        content = response.content[0].text
        return LLMResponse(
            content=content,
            input_tokens=response.usage.input_tokens,
            output_tokens=response.usage.output_tokens,
            model=model,
            provider="anthropic",
        )

    async def _complete_openai(
        self, prompt: str, system: str, model: str
    ) -> LLMResponse:
        """Make an async completion request to OpenAI or custom OpenAI-compatible endpoint."""
        logger.info("Calling OpenAI-compatible API with %d char prompt", len(prompt))
        response = await self._client.chat.completions.create(
            model=model,
            max_tokens=8192,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": prompt},
            ],
        )
        logger.debug("OpenAI-compatible response received")

        content = response.choices[0].message.content
        input_tokens = getattr(response.usage, "prompt_tokens", 0) if response.usage else 0
        output_tokens = getattr(response.usage, "completion_tokens", 0) if response.usage else 0
        return LLMResponse(
            content=content,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            model=model,
            provider=self.provider,
        )

    async def _complete_gemini(
        self, prompt: str, system: str, model: str, max_retries: int = 3
    ) -> LLMResponse:
        """Make an async completion request to Google Gemini with retry logic.

        Gemini 2.5 models have a known issue where responses can be truncated
        due to internal "thinking" consuming output tokens. We retry on
        truncation (MAX_TOKENS finish reason) or empty responses.
        """
        last_error = None

        for attempt in range(max_retries):
            logger.info(
                "Calling Gemini API (attempt %d/%d) with %d char prompt",
                attempt + 1, max_retries, len(prompt),
            )

            response = await self._client.aio.models.generate_content(
                model=model,
                contents=prompt,
                config=genai_types.GenerateContentConfig(
                    system_instruction=system,
                ),
            )

            finish_reason = None
            if response.candidates:
                finish_reason = response.candidates[0].finish_reason

            usage = response.usage_metadata
            content = response.text if response.text else ""

            logger.info(
                "Gemini response: %d chars, finish_reason=%s, output_tokens=%d",
                len(content),
                finish_reason,
                usage.candidates_token_count if usage else 0,
            )

            if finish_reason == genai_types.FinishReason.MAX_TOKENS:
                logger.warning(
                    "Gemini response truncated (MAX_TOKENS), attempt %d/%d",
                    attempt + 1, max_retries,
                )
                last_error = "Response truncated due to MAX_TOKENS"
                continue

            if not content or len(content.strip()) < 10:
                logger.warning(
                    "Gemini returned empty/minimal response, attempt %d/%d",
                    attempt + 1, max_retries,
                )
                last_error = "Empty or minimal response"
                continue

            return LLMResponse(
                content=content,
                input_tokens=usage.prompt_token_count if usage else 0,
                output_tokens=usage.candidates_token_count if usage else 0,
                model=model,
                provider="gemini",
            )

        raise RuntimeError(f"Gemini API failed after {max_retries} attempts: {last_error}")

    async def _complete_ollama(
        self, prompt: str, system: str, model: str, temperature: float = 0.3
    ) -> LLMResponse:
        """Make an async completion request to Ollama via the chat endpoint.

        Uses /api/chat so Gemma's instruction-tuned chat template is applied
        correctly. Forces JSON output mode and passes num_ctx explicitly so
        the full model context window is always available.
        """
        logger.info("Calling Ollama /api/chat with %d char prompt (temp=%.1f)", len(prompt), temperature)
        ollama_url = self.config.ollama_url.rstrip("/")

        if self._ollama_client is None:
            self._ollama_client = httpx.AsyncClient(timeout=httpx.Timeout(600.0))

        num_ctx = min(get_model_context_limit(model, self.config), 65_536)
        response = await self._ollama_client.post(
            f"{ollama_url}/api/chat",
            json={
                "model": model,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": prompt},
                ],
                "stream": False,
                "format": "json",
                "options": {
                    "num_ctx": num_ctx,
                    "temperature": temperature,
                },
            },
        )
        response.raise_for_status()
        data = response.json()

        logger.debug("Ollama chat response received")

        content = data.get("message", {}).get("content", "")
        input_tokens = data.get("prompt_eval_count", 0)
        output_tokens = data.get("eval_count", 0)

        if not content or len(content.strip()) < 2:
            logger.warning("Ollama returned empty response. Input tokens: %d", input_tokens)
            raise RuntimeError(
                "Ollama returned an empty response. This may happen if the context "
                "window is too small for the request. Try reducing the number of "
                "tracks sent to AI or using a model with a larger context window."
            )

        return LLMResponse(
            content=content,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            model=model,
            provider="ollama",
        )

    async def _complete(
        self, prompt: str, system: str, model: str, temperature: float = 0.3
    ) -> LLMResponse:
        """Dispatch async completion to the configured provider."""
        if self.provider == "anthropic":
            return await self._complete_anthropic(prompt, system, model)
        elif self.provider in ("openai", "custom"):
            return await self._complete_openai(prompt, system, model)
        elif self.provider == "gemini":
            return await self._complete_gemini(prompt, system, model)
        elif self.provider == "ollama":
            return await self._complete_ollama(prompt, system, model, temperature)
        else:
            raise ValueError(f"Unknown provider: {self.provider}")

    # ------------------------------------------------------------------
    # Public async API  (used by analyzer.py, generator.py, routes)
    # ------------------------------------------------------------------

    async def analyze(self, prompt: str, system: str) -> LLMResponse:
        """Use the analysis model for understanding tasks (async).

        Temperature 0.3 — slightly creative for genre/mood detection and
        album discovery, but still consistent.
        """
        model = self.config.model_analysis
        return await self._complete(prompt, system, model, temperature=0.3)

    async def generate(self, prompt: str, system: str) -> LLMResponse:
        """Use the generation model for track selection (async).

        Temperature 0.2 — deterministic curation; reduces random track
        ordering and improves JSON reliability on large track lists.
        """
        if self.config.smart_generation:
            model = self.config.model_analysis
        else:
            model = self.config.model_generation
        return await self._complete(prompt, system, model, temperature=0.2)

    # ------------------------------------------------------------------
    # Sync wrappers — for callers that run in a thread (e.g. recommender.py
    # via asyncio.to_thread).  They start a fresh event loop per call which
    # is safe inside a thread that has no running loop.
    # ------------------------------------------------------------------

    def analyze_sync(self, prompt: str, system: str) -> LLMResponse:
        """Sync wrapper around :meth:`analyze` for thread-pool callers."""
        return asyncio.run(self.analyze(prompt, system))

    def generate_sync(self, prompt: str, system: str) -> LLMResponse:
        """Sync wrapper around :meth:`generate` for thread-pool callers."""
        return asyncio.run(self.generate(prompt, system))

    # ------------------------------------------------------------------
    # JSON parsing helpers (stateless — no async needed)
    # ------------------------------------------------------------------

    def _extract_json_bounds(self, content: str) -> str | None:
        """Extract JSON array or object from content with extra text.

        Finds the first [ or { and its matching closing bracket,
        properly handling nested structures and strings.

        Args:
            content: Raw content that may contain JSON with extra text

        Returns:
            Extracted JSON string, or None if no valid JSON found
        """
        start_idx = -1
        open_char = None
        close_char = None

        for i, c in enumerate(content):
            if c == '[':
                start_idx = i
                open_char = '['
                close_char = ']'
                break
            elif c == '{':
                start_idx = i
                open_char = '{'
                close_char = '}'
                break

        if start_idx == -1:
            return None

        depth = 0
        in_string = False
        escape_next = False

        for i in range(start_idx, len(content)):
            c = content[i]

            if escape_next:
                escape_next = False
                continue

            if c == '\\' and in_string:
                escape_next = True
                continue

            if c == '"' and not escape_next:
                in_string = not in_string
                continue

            if in_string:
                continue

            if c == open_char:
                depth += 1
            elif c == close_char:
                depth -= 1
                if depth == 0:
                    return content[start_idx:i + 1]

        return None

    def parse_json_response(self, response: LLMResponse) -> Any:
        """Parse JSON from LLM response, handling common issues.

        Args:
            response: LLM response to parse

        Returns:
            Parsed JSON data

        Raises:
            ValueError: If JSON cannot be parsed
        """
        content = response.content.strip()

        if not content:
            raise ValueError(
                "LLM returned an empty response. This may happen if the context "
                "window is too small. Try reducing 'Max Tracks to AI' in filters."
            )

        # Extract from markdown code blocks
        json_match = re.search(r"```json\s*\n?(.*?)```", content, re.DOTALL | re.IGNORECASE)
        if json_match:
            content = json_match.group(1).strip()
        else:
            match = re.search(r"```(?:\w+)?\s*\n?(.*?)```", content, re.DOTALL)
            if match:
                content = match.group(1).strip()

        # Replace curly/smart quotes with straight quotes (common LLM issue)
        content = content.replace('“', '"').replace('”', '"')
        content = content.replace('‘', "'").replace('’', "'")

        try:
            return json.loads(content)
        except json.JSONDecodeError as e:
            original_error = e

            if "Extra data" in str(e):
                extracted = self._extract_json_bounds(content)
                if extracted:
                    try:
                        return json.loads(extracted)
                    except json.JSONDecodeError:
                        pass

            try:
                repaired = repair_json(content, return_objects=True)
                logger.debug("JSON repair succeeded for malformed LLM response")
                return repaired
            except Exception:
                pass

            preview = content[:200] + "..." if len(content) > 200 else content
            raise ValueError(
                f"Failed to parse LLM response as JSON: {original_error}\n"
                f"Response preview: {preview}"
            ) from None


# Global client instance
_llm_client: LLMClient | None = None


def get_llm_client() -> LLMClient | None:
    """Get the current LLM client instance."""
    return _llm_client


# ---------------------------------------------------------------------------
# Background AI gate — only free providers run background enrichment tasks.
# Paid providers (gemini, anthropic, openai) skip all background AI work.
# ---------------------------------------------------------------------------

FREE_PROVIDERS = frozenset({"ollama", "custom"})


def is_free_provider() -> bool:
    """Return True if the current LLM provider is free (local)."""
    client = get_llm_client()
    if not client:
        return False
    return client.provider in FREE_PROVIDERS


def is_background_ai_enabled() -> bool:
    """Check both provider gate and explicit config override."""
    from backend.config import get_background_ai_enabled  # noqa: PLC0415

    # Explicit override takes priority
    override = get_background_ai_enabled()
    if override is not None:
        return override

    # Default: enabled for free providers only
    return is_free_provider()


def init_llm_client(config: LLMConfig) -> LLMClient:
    """Initialize or reinitialize the LLM client."""
    global _llm_client
    _llm_client = LLMClient(config)
    return _llm_client


def get_max_tracks_for_model(
    model: str, buffer_percent: float = 0.10, config: LLMConfig | None = None
) -> int:
    """Calculate max tracks that can be sent to a model."""
    context_limit = get_model_context_limit(model, config)
    usable_tokens = int(context_limit * (1 - buffer_percent))
    available_for_tracks = usable_tokens - 1000
    max_tracks = available_for_tracks // TOKENS_PER_TRACK
    return max(100, max_tracks)


def get_max_albums_for_model(
    model: str, buffer_percent: float = 0.10, config: LLMConfig | None = None
) -> int:
    """Calculate max albums that can be sent to a model."""
    context_limit = get_model_context_limit(model, config)
    usable_tokens = int(context_limit * (1 - buffer_percent))
    available_for_albums = usable_tokens - 1000
    max_albums = available_for_albums // TOKENS_PER_ALBUM
    return max(100, max_albums)


def get_model_context_limit(model: str, config: LLMConfig | None = None) -> int:
    """Get the context limit for a model in tokens."""
    if model in MODEL_CONTEXT_LIMITS:
        return MODEL_CONTEXT_LIMITS[model]
    if config:
        if config.provider == "custom":
            return config.custom_context_window
        if config.provider == "ollama":
            return config.ollama_context_window
    return 128_000


def get_model_cost(model: str, config: LLMConfig | None = None) -> dict[str, float]:
    """Get cost per million tokens for a model."""
    if config and config.provider in ("ollama", "custom"):
        return {"input": 0.0, "output": 0.0}
    return MODEL_COSTS.get(model, {"input": 1.0, "output": 2.0})


# =============================================================================
# Ollama API Functions  (sync — called during setup/config, not on hot path)
# =============================================================================


def list_ollama_models(ollama_url: str, timeout: float = 5.0) -> OllamaModelsResponse:
    """List available models from Ollama server."""
    try:
        with httpx.Client(timeout=timeout) as client:
            response = client.get(f"{ollama_url.rstrip('/')}/api/tags")
            response.raise_for_status()
            data = response.json()

            models = []
            for model_data in data.get("models", []):
                models.append(OllamaModel(
                    name=model_data.get("name", ""),
                    size=model_data.get("size", 0),
                    modified_at=model_data.get("modified_at", ""),
                ))

            return OllamaModelsResponse(models=models)

    except httpx.ConnectError:
        return OllamaModelsResponse(error=f"Cannot reach Ollama at {ollama_url}")
    except httpx.TimeoutException:
        return OllamaModelsResponse(error=f"Timeout connecting to Ollama at {ollama_url}")
    except Exception as e:
        logger.exception("Error listing Ollama models")
        return OllamaModelsResponse(error=str(e))


def get_ollama_model_info(
    ollama_url: str, model_name: str, timeout: float = 5.0
) -> OllamaModelInfo | None:
    """Get detailed info about an Ollama model including context window."""
    try:
        with httpx.Client(timeout=timeout) as client:
            response = client.post(
                f"{ollama_url.rstrip('/')}/api/show",
                json={"name": model_name},
            )
            response.raise_for_status()
            data = response.json()

            context_window = 32768
            context_detected = False

            model_info = data.get("model_info", {})
            for key, value in model_info.items():
                if key.endswith(".context_length") and isinstance(value, int):
                    context_window = value
                    context_detected = True
                    break

            parameters = data.get("parameters", "")
            modelfile = data.get("modelfile", "")

            for line in (parameters + "\n" + modelfile).split("\n"):
                line = line.strip().lower()
                if "num_ctx" in line:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part == "num_ctx" and i + 1 < len(parts):
                            try:
                                context_window = int(parts[i + 1])
                                context_detected = True
                                break
                            except ValueError:
                                pass

            details = data.get("details", {})
            parameter_size = details.get("parameter_size")

            return OllamaModelInfo(
                name=model_name,
                context_window=context_window,
                context_detected=context_detected,
                parameter_size=parameter_size,
            )

    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            return None
        logger.exception("Error getting Ollama model info")
        return None
    except Exception:
        logger.exception("Error getting Ollama model info")
        return None


def get_ollama_status(ollama_url: str, timeout: float = 5.0) -> OllamaStatus:
    """Check Ollama connection status."""
    models_response = list_ollama_models(ollama_url, timeout)

    if models_response.error:
        return OllamaStatus(connected=False, model_count=0, error=models_response.error)

    model_count = len(models_response.models)
    if model_count == 0:
        return OllamaStatus(
            connected=True,
            model_count=0,
            error="Connected but no models installed. Run `ollama pull llama3`",
        )

    return OllamaStatus(connected=True, model_count=model_count, error=None)
