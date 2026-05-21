"""Tests for LLM client (async-first, v12 refactor)."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_async_mock(return_value):
    """Return an AsyncMock pre-configured with a return value."""
    m = AsyncMock()
    m.return_value = return_value
    return m


# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

class TestLLMClientInitialization:
    """Tests for LLM client initialization."""

    def test_anthropic_client_init(self):
        """Should initialize AsyncAnthropic client correctly."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="sk-ant-test-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
        )

        with patch("backend.llm_client.anthropic") as mock_anthropic:
            client = LLMClient(config)
            mock_anthropic.AsyncAnthropic.assert_called_once_with(api_key="sk-ant-test-key")
            assert client.provider == "anthropic"

    def test_openai_client_init(self):
        """Should initialize AsyncOpenAI client correctly."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="openai",
            api_key="sk-test-key",
            model_analysis="gpt-4.1",
            model_generation="gpt-4.1-mini",
        )

        with patch("backend.llm_client.openai") as mock_openai:
            client = LLMClient(config)
            mock_openai.AsyncOpenAI.assert_called_once_with(api_key="sk-test-key")
            assert client.provider == "openai"

    def test_ollama_client_init_creates_async_httpx(self):
        """Ollama provider should create a persistent AsyncClient."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="llama3:8b",
            model_generation="llama3:8b",
            ollama_url="http://localhost:11434",
        )

        with patch("backend.llm_client.httpx.AsyncClient") as mock_ac:
            mock_ac.return_value = MagicMock()
            client = LLMClient(config)
            mock_ac.assert_called_once()
            assert client.provider == "ollama"
            assert client._ollama_client is not None

    def test_invalid_api_key_anthropic(self):
        """Should handle any API key at init; validation deferred to first call."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="invalid-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
        )

        with patch("backend.llm_client.anthropic") as mock_anthropic:
            mock_anthropic.AsyncAnthropic.return_value = MagicMock()
            client = LLMClient(config)
            assert client.provider == "anthropic"

    def test_invalid_api_key_openai(self):
        """Should handle any API key at init; validation deferred to first call."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="openai",
            api_key="invalid-key",
            model_analysis="gpt-4.1",
            model_generation="gpt-4.1-mini",
        )

        with patch("backend.llm_client.openai") as mock_openai:
            mock_openai.AsyncOpenAI.return_value = MagicMock()
            client = LLMClient(config)
            assert client.provider == "openai"


# ---------------------------------------------------------------------------
# Async analyze / generate
# ---------------------------------------------------------------------------

class TestLLMClientAsyncAnalyze:
    """Tests for async LLM analysis calls."""

    @pytest.mark.asyncio
    async def test_analyze_uses_analysis_model(self):
        """Should use analysis model for analyze calls."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
        )

        mock_response = MagicMock()
        mock_response.content = [MagicMock(text='{"result": "test"}')]
        mock_response.usage.input_tokens = 100
        mock_response.usage.output_tokens = 50

        with patch("backend.llm_client.anthropic") as mock_anthropic:
            mock_ac = MagicMock()
            mock_ac.messages.create = _make_async_mock(mock_response)
            mock_anthropic.AsyncAnthropic.return_value = mock_ac

            client = LLMClient(config)
            result = await client.analyze("test prompt", "system prompt")

            call_args = mock_ac.messages.create.call_args
            assert call_args.kwargs["model"] == "claude-sonnet-4-5"
            assert result.input_tokens == 100
            assert result.output_tokens == 50

    @pytest.mark.asyncio
    async def test_generate_uses_generation_model(self):
        """Should use generation model for generate calls."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
            smart_generation=False,
        )

        mock_response = MagicMock()
        mock_response.content = [MagicMock(text='[{"artist": "Test", "title": "Song"}]')]
        mock_response.usage.input_tokens = 100
        mock_response.usage.output_tokens = 50

        with patch("backend.llm_client.anthropic") as mock_anthropic:
            mock_ac = MagicMock()
            mock_ac.messages.create = _make_async_mock(mock_response)
            mock_anthropic.AsyncAnthropic.return_value = mock_ac

            client = LLMClient(config)
            await client.generate("test prompt", "system prompt")

            call_args = mock_ac.messages.create.call_args
            assert call_args.kwargs["model"] == "claude-haiku-4-5"

    @pytest.mark.asyncio
    async def test_smart_generation_uses_analysis_model(self):
        """Should use analysis model when smart_generation is enabled."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
            smart_generation=True,
        )

        mock_response = MagicMock()
        mock_response.content = [MagicMock(text='[{"artist": "Test", "title": "Song"}]')]
        mock_response.usage.input_tokens = 100
        mock_response.usage.output_tokens = 50

        with patch("backend.llm_client.anthropic") as mock_anthropic:
            mock_ac = MagicMock()
            mock_ac.messages.create = _make_async_mock(mock_response)
            mock_anthropic.AsyncAnthropic.return_value = mock_ac

            client = LLMClient(config)
            await client.generate("test prompt", "system prompt")

            call_args = mock_ac.messages.create.call_args
            assert call_args.kwargs["model"] == "claude-sonnet-4-5"


# ---------------------------------------------------------------------------
# Token tracking
# ---------------------------------------------------------------------------

class TestLLMClientTokenTracking:
    """Tests for token and cost tracking."""

    @pytest.mark.asyncio
    async def test_tracks_tokens_anthropic(self):
        """Should track tokens for Anthropic calls."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
        )

        mock_response = MagicMock()
        mock_response.content = [MagicMock(text='{"result": "test"}')]
        mock_response.usage.input_tokens = 150
        mock_response.usage.output_tokens = 75

        with patch("backend.llm_client.anthropic") as mock_anthropic:
            mock_ac = MagicMock()
            mock_ac.messages.create = _make_async_mock(mock_response)
            mock_anthropic.AsyncAnthropic.return_value = mock_ac

            client = LLMClient(config)
            result = await client.analyze("test prompt", "system prompt")

        assert result.input_tokens == 150
        assert result.output_tokens == 75
        assert result.total_tokens == 225

    @pytest.mark.asyncio
    async def test_tracks_tokens_openai(self):
        """Should track tokens for OpenAI calls."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="openai",
            api_key="test-key",
            model_analysis="gpt-4.1",
            model_generation="gpt-4.1-mini",
        )

        mock_response = MagicMock()
        mock_response.choices = [MagicMock(message=MagicMock(content='{"result": "test"}'))]
        mock_response.usage.prompt_tokens = 150
        mock_response.usage.completion_tokens = 75

        with patch("backend.llm_client.openai") as mock_openai:
            mock_oa = MagicMock()
            mock_oa.chat.completions.create = _make_async_mock(mock_response)
            mock_openai.AsyncOpenAI.return_value = mock_oa

            client = LLMClient(config)
            result = await client.analyze("test prompt", "system prompt")

        assert result.input_tokens == 150
        assert result.output_tokens == 75
        assert result.total_tokens == 225


# ---------------------------------------------------------------------------
# Sync wrappers
# ---------------------------------------------------------------------------

class TestSyncWrappers:
    """Tests for analyze_sync / generate_sync wrappers (used by recommender.py)."""

    def test_analyze_sync_returns_result(self):
        """analyze_sync should block and return the same result as analyze."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
        )

        expected = LLMResponse(
            content='{"ok": true}', input_tokens=10, output_tokens=5, model="claude-sonnet-4-5"
        )

        with patch("backend.llm_client.anthropic"):
            client = LLMClient(config)

        with patch.object(client, "analyze", return_value=expected) as mock_analyze:
            # analyze is async — patch with a coroutine-returning mock
            async def _coro(*a, **kw):
                return expected

            mock_analyze.side_effect = _coro
            result = client.analyze_sync("prompt", "system")

        assert result is expected

    def test_generate_sync_returns_result(self):
        """generate_sync should block and return the same result as generate."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test-key",
            model_analysis="claude-sonnet-4-5",
            model_generation="claude-haiku-4-5",
        )

        expected = LLMResponse(
            content="[1, 2, 3]", input_tokens=20, output_tokens=10, model="claude-haiku-4-5"
        )

        with patch("backend.llm_client.anthropic"):
            client = LLMClient(config)

        async def _coro(*a, **kw):
            return expected

        with patch.object(client, "generate", side_effect=_coro):
            result = client.generate_sync("prompt", "system")

        assert result is expected


# ---------------------------------------------------------------------------
# Ollama async provider
# ---------------------------------------------------------------------------

class TestOllamaAsync:
    """Tests for async Ollama provider."""

    @pytest.mark.asyncio
    async def test_complete_ollama_success(self):
        """Should make async completion request to Ollama API."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="llama3:8b",
            model_generation="llama3:8b",
            ollama_url="http://localhost:11434",
        )

        mock_http_response = MagicMock()
        mock_http_response.json.return_value = {
            "response": '{"result": "test"}',
            "prompt_eval_count": 100,
            "eval_count": 50,
        }
        mock_http_response.raise_for_status = MagicMock()

        with patch("backend.llm_client.httpx.AsyncClient") as mock_ac:
            mock_ac.return_value = AsyncMock()
            client = LLMClient(config)
        # Replace with a proper async mock after construction
        client._ollama_client = AsyncMock()
        client._ollama_client.post = _make_async_mock(mock_http_response)

        result = await client._complete_ollama("test prompt", "system prompt", "llama3:8b")

        assert result.content == '{"result": "test"}'
        assert result.input_tokens == 100
        assert result.output_tokens == 50
        assert result.model == "llama3:8b"
        # Verify correct endpoint was called
        call_args = client._ollama_client.post.call_args
        assert "/api/generate" in call_args[0][0]

    @pytest.mark.asyncio
    async def test_complete_dispatch_routes_to_ollama(self, mocker):
        """Should route 'ollama' provider to _complete_ollama method."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="llama3:8b",
            model_generation="llama3:8b",
            ollama_url="http://localhost:11434",
        )

        with patch("backend.llm_client.httpx.AsyncClient") as mock_ac:
            mock_ac.return_value = MagicMock()
            client = LLMClient(config)

        expected = LLMResponse(content="test", input_tokens=0, output_tokens=0, model="llama3:8b")
        mock_ollama = mocker.patch.object(client, "_complete_ollama", new_callable=AsyncMock)
        mock_ollama.return_value = expected

        result = await client._complete("test prompt", "system prompt", "llama3:8b")

        mock_ollama.assert_called_once_with("test prompt", "system prompt", "llama3:8b")
        assert result is expected

    @pytest.mark.asyncio
    async def test_close_releases_ollama_client(self):
        """close() should aclose the async httpx client and set it to None."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="llama3:8b",
            model_generation="llama3:8b",
            ollama_url="http://localhost:11434",
        )

        with patch("backend.llm_client.httpx.AsyncClient") as mock_ac:
            mock_ac.return_value = MagicMock()
            client = LLMClient(config)
        mock_aclose = AsyncMock()
        client._ollama_client.aclose = mock_aclose

        await client.close()

        mock_aclose.assert_awaited_once()
        assert client._ollama_client is None


# ---------------------------------------------------------------------------
# Custom provider (async)
# ---------------------------------------------------------------------------

class TestCustomProvider:
    """Tests for custom OpenAI-compatible provider."""

    def test_custom_client_init_creates_async_openai_client(self):
        """Custom provider should create AsyncOpenAI client with custom base_url."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="custom",
            api_key="",
            model_analysis="my-model",
            model_generation="my-model",
            custom_url="http://localhost:5000/v1",
            custom_context_window=8192,
        )

        with patch("backend.llm_client.openai") as mock_openai:
            client = LLMClient(config)
            mock_openai.AsyncOpenAI.assert_called_once_with(
                api_key="not-needed",
                base_url="http://localhost:5000/v1",
            )
            assert client.provider == "custom"

    @pytest.mark.asyncio
    async def test_complete_custom_success(self):
        """Should make async completion request to custom endpoint via _complete_openai."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="custom",
            api_key="",
            model_analysis="my-model",
            model_generation="my-model",
            custom_url="http://localhost:5000/v1",
            custom_context_window=8192,
        )

        mock_response = MagicMock()
        mock_response.choices = [MagicMock(message=MagicMock(content='{"result": "test"}'))]
        mock_response.usage.prompt_tokens = 100
        mock_response.usage.completion_tokens = 50

        with patch("backend.llm_client.openai") as mock_openai:
            mock_oa = MagicMock()
            mock_oa.chat.completions.create = _make_async_mock(mock_response)
            mock_openai.AsyncOpenAI.return_value = mock_oa

            client = LLMClient(config)
            result = await client._complete_openai("test prompt", "system prompt", "my-model")

        assert result.content == '{"result": "test"}'
        assert result.input_tokens == 100
        assert result.output_tokens == 50
        assert result.model == "my-model"

    @pytest.mark.asyncio
    async def test_complete_dispatch_routes_to_custom(self, mocker):
        """Should route 'custom' provider to _complete_openai method."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="custom",
            api_key="",
            model_analysis="my-model",
            model_generation="my-model",
            custom_url="http://localhost:5000/v1",
        )

        with patch("backend.llm_client.openai"):
            client = LLMClient(config)

        expected = LLMResponse(content="test", input_tokens=0, output_tokens=0, model="my-model")
        mock_method = mocker.patch.object(client, "_complete_openai", new_callable=AsyncMock)
        mock_method.return_value = expected

        result = await client._complete("test prompt", "system prompt", "my-model")

        mock_method.assert_called_once_with("test prompt", "system prompt", "my-model")
        assert result is expected


# ---------------------------------------------------------------------------
# Local provider costs
# ---------------------------------------------------------------------------

class TestLocalProviderCosts:
    """Tests for local provider cost calculations."""

    def test_ollama_cost_is_zero(self):
        """Ollama provider should have zero cost."""
        from backend.llm_client import get_model_cost
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="llama3:8b",
            model_generation="llama3:8b",
        )

        costs = get_model_cost("llama3:8b", config)
        assert costs["input"] == 0.0
        assert costs["output"] == 0.0

    def test_custom_cost_is_zero(self):
        """Custom provider should have zero cost."""
        from backend.llm_client import get_model_cost
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="custom",
            api_key="",
            model_analysis="my-model",
            model_generation="my-model",
            custom_url="http://localhost:5000/v1",
        )

        costs = get_model_cost("my-model", config)
        assert costs["input"] == 0.0
        assert costs["output"] == 0.0

    def test_estimate_cost_is_zero_for_local(self):
        """estimate_cost_for_model should return 0 for local providers."""
        from backend.llm_client import estimate_cost_for_model
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="llama3:8b",
            model_generation="llama3:8b",
        )

        cost = estimate_cost_for_model("llama3:8b", 10000, 5000, config)
        assert cost == 0.0

    def test_known_cloud_model_has_nonzero_cost(self):
        """Known cloud model should return non-zero costs."""
        from backend.llm_client import get_model_cost

        costs = get_model_cost("claude-haiku-4-5", None)
        assert costs["input"] > 0
        assert costs["output"] > 0

    def test_unknown_model_falls_back_gracefully(self):
        """Unknown model should not raise; should return some cost dict."""
        from backend.llm_client import get_model_cost

        costs = get_model_cost("completely-unknown-model-xyz", None)
        assert "input" in costs
        assert "output" in costs


# ---------------------------------------------------------------------------
# Local provider context limits
# ---------------------------------------------------------------------------

class TestLocalProviderContextLimits:
    """Tests for local provider context limit lookups."""

    def test_custom_context_from_config(self):
        """Custom provider should use context window from config."""
        from backend.llm_client import get_model_context_limit
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="custom",
            api_key="",
            model_analysis="my-model",
            model_generation="my-model",
            custom_url="http://localhost:5000/v1",
            custom_context_window=16384,
        )

        limit = get_model_context_limit("my-model", config)
        assert limit == 16384

    def test_ollama_default_context(self):
        """Ollama provider without explicit window should use 32768 default."""
        from backend.llm_client import get_model_context_limit
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="llama3:8b",
            model_generation="llama3:8b",
        )

        limit = get_model_context_limit("llama3:8b", config)
        assert limit == 32768

    def test_ollama_context_from_config(self):
        """Ollama provider should use ollama_context_window from config when set."""
        from backend.llm_client import get_model_context_limit
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="ollama",
            api_key="",
            model_analysis="qwen3:8b",
            model_generation="qwen3:8b",
            ollama_context_window=40960,
        )

        limit = get_model_context_limit("qwen3:8b", config)
        assert limit == 40960

    def test_max_tracks_for_custom_model(self):
        """Should calculate max tracks based on custom context window."""
        from backend.llm_client import get_max_tracks_for_model
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="custom",
            api_key="",
            model_analysis="my-model",
            model_generation="my-model",
            custom_url="http://localhost:5000/v1",
            custom_context_window=16384,
        )

        max_tracks = get_max_tracks_for_model("my-model", config=config)
        # (16384 * 0.9 - 1000) / 40 ≈ 344 — just verify it's a plausible number
        assert max_tracks > 200

    def test_max_tracks_for_known_model(self):
        """get_max_tracks_for_model should return a reasonable value for known models."""
        from backend.llm_client import get_max_tracks_for_model

        # claude-haiku-4-5 has 200K context → very high track count
        max_tracks = get_max_tracks_for_model("claude-haiku-4-5")
        assert max_tracks > 1000


# ---------------------------------------------------------------------------
# Ollama model info parsing
# ---------------------------------------------------------------------------

class TestOllamaModelInfoParsing:
    """Tests for Ollama model info context window parsing."""

    def test_context_from_model_info(self):
        """Should extract context_length from model_info field."""
        from backend.llm_client import get_ollama_model_info

        mock_response = MagicMock()
        mock_response.json.return_value = {
            "model_info": {
                "general.architecture": "qwen3",
                "qwen3.context_length": 40960,
            },
            "details": {"parameter_size": "8B"},
            "parameters": "",
            "modelfile": "",
        }
        mock_response.raise_for_status = MagicMock()

        with patch("backend.llm_client.httpx.Client") as mock_client:
            mock_client.return_value.__enter__.return_value.post.return_value = mock_response
            result = get_ollama_model_info("http://localhost:11434", "qwen3:8b")

        assert result is not None
        assert result.context_window == 40960
        assert result.parameter_size == "8B"

    def test_num_ctx_overrides_model_info(self):
        """Explicit num_ctx in parameters should override model_info."""
        from backend.llm_client import get_ollama_model_info

        mock_response = MagicMock()
        mock_response.json.return_value = {
            "model_info": {
                "general.architecture": "llama",
                "llama.context_length": 8192,
            },
            "details": {},
            "parameters": "num_ctx 4096",
            "modelfile": "",
        }
        mock_response.raise_for_status = MagicMock()

        with patch("backend.llm_client.httpx.Client") as mock_client:
            mock_client.return_value.__enter__.return_value.post.return_value = mock_response
            result = get_ollama_model_info("http://localhost:11434", "llama3:8b")

        assert result is not None
        assert result.context_window == 4096  # num_ctx takes precedence

    def test_fallback_to_default_when_no_context_info(self):
        """Should use 32768 default when no context info available."""
        from backend.llm_client import get_ollama_model_info

        mock_response = MagicMock()
        mock_response.json.return_value = {
            "model_info": {},
            "details": {},
            "parameters": "",
            "modelfile": "",
        }
        mock_response.raise_for_status = MagicMock()

        with patch("backend.llm_client.httpx.Client") as mock_client:
            mock_client.return_value.__enter__.return_value.post.return_value = mock_response
            result = get_ollama_model_info("http://localhost:11434", "unknown-model")

        assert result is not None
        assert result.context_window == 32768


# ---------------------------------------------------------------------------
# JSON parsing
# ---------------------------------------------------------------------------

class TestJsonParsing:
    """Tests for JSON parsing from LLM responses."""

    def test_parse_json_with_extra_text(self):
        """Should handle LLM responses with extra text after JSON array."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test",
            model_analysis="test",
            model_generation="test",
        )

        with patch("backend.llm_client.anthropic"):
            client = LLMClient(config)

        response = LLMResponse(
            content='[{"artist": "Test", "title": "Song"}]\n\nThis is a great selection because...',
            input_tokens=100,
            output_tokens=50,
            model="test",
        )

        result = client.parse_json_response(response)
        assert result == [{"artist": "Test", "title": "Song"}]

    def test_parse_json_with_nested_objects(self):
        """Should handle nested JSON objects with extra text."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test",
            model_analysis="test",
            model_generation="test",
        )

        with patch("backend.llm_client.anthropic"):
            client = LLMClient(config)

        response = LLMResponse(
            content='{"title": "Test", "tracks": [{"name": "Song"}]} Extra text here',
            input_tokens=100,
            output_tokens=50,
            model="test",
        )

        result = client.parse_json_response(response)
        assert result == {"title": "Test", "tracks": [{"name": "Song"}]}

    def test_extract_json_bounds_with_strings_containing_brackets(self):
        """Should handle JSON with brackets inside strings."""
        from backend.llm_client import LLMClient
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test",
            model_analysis="test",
            model_generation="test",
        )

        with patch("backend.llm_client.anthropic"):
            client = LLMClient(config)

        content = '[{"reason": "This track [live] is great"}] Some explanation'
        result = client._extract_json_bounds(content)
        assert result == '[{"reason": "This track [live] is great"}]'

    def test_repair_unescaped_quotes_in_string(self):
        """Should repair unescaped double quotes inside string values."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test",
            model_analysis="test",
            model_generation="test",
        )

        with patch("backend.llm_client.anthropic"):
            client = LLMClient(config)

        response = LLMResponse(
            content='[{"artist": "Phoenix", "title": "Fences", "reason": "The song \\"Fences\\" is great"}]',
            input_tokens=100,
            output_tokens=50,
            model="test",
        )

        result = client.parse_json_response(response)
        assert result[0]["artist"] == "Phoenix"
        assert result[0]["title"] == "Fences"
        assert "Fences" in result[0]["reason"]

    def test_repair_json_with_newlines_in_strings(self):
        """Should handle newlines inside string values."""
        from backend.llm_client import LLMClient, LLMResponse
        from backend.models import LLMConfig

        config = LLMConfig(
            provider="anthropic",
            api_key="test",
            model_analysis="test",
            model_generation="test",
        )

        with patch("backend.llm_client.anthropic"):
            client = LLMClient(config)

        response = LLMResponse(
            content='[{"reason": "Line one\\nLine two"}]',
            input_tokens=100,
            output_tokens=50,
            model="test",
        )

        result = client.parse_json_response(response)
        assert "Line one" in result[0]["reason"]
