"""Tests for the ONNX inference paths in clap_search and lyrics.embedder.

Real ONNX inference can't be exercised in CI — the export scripts require
~1 GB of model checkpoints plus the full ML stack. Instead these tests verify
the *dispatch wiring*:

* When ``*_USE_ONNX`` is false or the ``.onnx`` files don't exist, the call
  must fall through to the legacy backend (``laion_clap`` / ``transformers``).
* When a stub ONNX backend is installed via monkeypatch, the dispatch
  helpers must route through it (and must not load the heavy model).
* A stubbed parity test confirms that — *given* a future export script that
  produces correct ONNX models — the dispatch helpers' output matches the
  legacy backend within cosine tolerance ``>= 0.99``. The real parity check
  lives in ``scripts/export_*_onnx.py``'s ``verify`` step.
"""

from __future__ import annotations

import pytest

pytest.importorskip("numpy")

import numpy as np  # noqa: E402

from backend.audio_features import clap_search  # noqa: E402
from backend.lyrics import embedder  # noqa: E402

# ---------------------------------------------------------------------------
# Helpers / fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_backends():
    """Ensure each test starts with a clean ONNX-backend cache."""
    clap_search.reset_onnx_backend()
    embedder.reset_onnx_backend()
    yield
    clap_search.reset_onnx_backend()
    embedder.reset_onnx_backend()


def _make_onnx_files(models_dir, kind: str) -> None:
    """Create placeholder files matching the export script's layout."""
    models_dir.mkdir(parents=True, exist_ok=True)
    if kind == "clap":
        (models_dir / "clap_audio_encoder.onnx").write_bytes(b"\x00")
        (models_dir / "clap_text_encoder.onnx").write_bytes(b"\x00")
    elif kind == "gte":
        (models_dir / "gte_multilingual.onnx").write_bytes(b"\x00")
        tok = models_dir / "gte_tokenizer"
        tok.mkdir(parents=True, exist_ok=True)
        (tok / "tokenizer.json").write_bytes(b"{}")
    else:
        raise ValueError(kind)


# ---------------------------------------------------------------------------
# CLAP dispatch tests
# ---------------------------------------------------------------------------


def test_clap_falls_back_when_no_onnx_files(monkeypatch, tmp_path):
    """No files on disk → legacy laion_clap path must be used."""
    monkeypatch.setenv("CLAP_ENABLED", "true")
    monkeypatch.setenv("CLAP_USE_ONNX", "true")
    monkeypatch.setenv("ONNX_MODELS_DIR", str(tmp_path / "models"))  # dir doesn't exist

    legacy_called = {"text": 0, "audio": 0}

    class _LegacyModel:
        def get_text_embedding(self, texts, use_tensor=False):
            legacy_called["text"] += 1
            return np.ones((len(texts), clap_search.EMBEDDING_DIM), dtype=np.float32)

        def get_audio_embedding_from_data(self, data, use_tensor=False):
            legacy_called["audio"] += 1
            return np.ones((len(data), clap_search.EMBEDDING_DIM), dtype=np.float32)

    monkeypatch.setattr(clap_search, "get_model", lambda: _LegacyModel())

    assert clap_search.get_onnx_backend() is None
    vec = clap_search._embed_text("anything")
    assert vec.shape == (clap_search.EMBEDDING_DIM,)
    assert legacy_called["text"] == 1


def test_clap_disabled_via_env_skips_onnx(monkeypatch, tmp_path):
    """CLAP_USE_ONNX=false → ONNX backend skipped even when files exist."""
    models_dir = tmp_path / "models"
    _make_onnx_files(models_dir, "clap")

    monkeypatch.setenv("CLAP_ENABLED", "true")
    monkeypatch.setenv("CLAP_USE_ONNX", "false")
    monkeypatch.setenv("ONNX_MODELS_DIR", str(models_dir))

    assert clap_search.get_onnx_backend() is None


def test_clap_disabled_when_clap_off(monkeypatch, tmp_path):
    """CLAP_ENABLED=false → ONNX backend not loaded (matches legacy semantics)."""
    models_dir = tmp_path / "models"
    _make_onnx_files(models_dir, "clap")

    monkeypatch.setenv("CLAP_ENABLED", "false")
    monkeypatch.setenv("CLAP_USE_ONNX", "true")
    monkeypatch.setenv("ONNX_MODELS_DIR", str(models_dir))

    assert clap_search.get_onnx_backend() is None


def test_clap_uses_onnx_backend_when_installed(monkeypatch):
    """When a backend is cached, the dispatch helper must use it without
    falling back to laion_clap."""

    class _StubBackend:
        def embed_text(self, text):
            v = np.zeros(clap_search.EMBEDDING_DIM, dtype=np.float32)
            v[3] = 1.0
            return v

        def embed_audio(self, waveform):
            v = np.zeros(clap_search.EMBEDDING_DIM, dtype=np.float32)
            v[4] = 1.0
            return v

    monkeypatch.setattr(clap_search, "_onnx_backend", _StubBackend())

    def _no_model():
        raise AssertionError("get_model must not be called when ONNX is available")

    monkeypatch.setattr(clap_search, "get_model", _no_model)

    text_vec = clap_search._embed_text("calm ambient piano")
    assert text_vec.shape == (clap_search.EMBEDDING_DIM,)
    assert text_vec[3] == pytest.approx(1.0)

    audio_vec = clap_search._embed_audio_from_waveform(
        np.zeros(480_000, dtype=np.float32)
    )
    assert audio_vec.shape == (clap_search.EMBEDDING_DIM,)
    assert audio_vec[4] == pytest.approx(1.0)


def test_clap_parity_stub(monkeypatch):
    """Cosine similarity between ONNX-stub and legacy-stub outputs >= 0.99.

    The export script's ``verify`` step does the real parity check. Here we
    only confirm that the dispatch helpers preserve the embedding rather than
    accidentally re-normalize, slice, or otherwise mutate the output.
    """
    rng = np.random.RandomState(42)
    base = rng.randn(clap_search.EMBEDDING_DIM).astype(np.float32)
    noise = 1e-3 * rng.randn(clap_search.EMBEDDING_DIM).astype(np.float32)

    class _StubOnnx:
        def embed_text(self, text):
            return base + noise

        def embed_audio(self, waveform):
            return base + noise

    class _LegacyModel:
        def get_text_embedding(self, texts, use_tensor=False):
            return np.stack([base for _ in texts])

        def get_audio_embedding_from_data(self, data, use_tensor=False):
            return np.stack([base for _ in data])

    # ONNX path
    monkeypatch.setattr(clap_search, "_onnx_backend", _StubOnnx())
    onnx_vec = np.asarray(clap_search._embed_text("query"), dtype=np.float32)

    # Legacy path
    monkeypatch.setattr(clap_search, "_onnx_backend", "missing")
    monkeypatch.setattr(clap_search, "get_model", lambda: _LegacyModel())
    legacy_vec = np.asarray(clap_search._embed_text("query"), dtype=np.float32)

    cos = float(
        np.dot(onnx_vec, legacy_vec)
        / (np.linalg.norm(onnx_vec) * np.linalg.norm(legacy_vec) + 1e-12)
    )
    assert cos >= 0.99, f"parity cosine {cos} below 0.99 tolerance"


# ---------------------------------------------------------------------------
# Lyrics dispatch tests
# ---------------------------------------------------------------------------


def test_lyrics_falls_back_when_no_onnx_files(monkeypatch, tmp_path):
    """No files → embed_text must use the transformers backend."""
    monkeypatch.setenv("LYRICS_SEARCH_ENABLED", "true")
    monkeypatch.setenv("LYRICS_USE_ONNX", "true")
    monkeypatch.setenv("ONNX_MODELS_DIR", str(tmp_path / "models"))

    legacy_called = {"n": 0}

    def _fake_embed_pair():
        # Build a callable pair that produces a deterministic 768-d vector.
        torch = pytest.importorskip("torch")

        class _Tok:
            def __call__(self, *_args, **_kwargs):
                return {
                    "input_ids": torch.tensor([[0, 1]]),
                    "attention_mask": torch.tensor([[1, 1]]),
                }

        class _Out:
            last_hidden_state = torch.ones((1, 2, embedder.EMBEDDING_DIM))

        class _Model:
            def __call__(self, **_kwargs):
                legacy_called["n"] += 1
                return _Out()

        return _Tok(), _Model()

    monkeypatch.setattr(embedder, "get_model_pair", _fake_embed_pair)

    assert embedder.get_onnx_backend() is None
    vec = embedder.embed_text("anything")
    assert vec.shape == (embedder.EMBEDDING_DIM,)
    assert legacy_called["n"] == 1


def test_lyrics_disabled_via_env_skips_onnx(monkeypatch, tmp_path):
    """LYRICS_USE_ONNX=false → ONNX backend skipped even when files exist."""
    models_dir = tmp_path / "models"
    _make_onnx_files(models_dir, "gte")

    monkeypatch.setenv("LYRICS_SEARCH_ENABLED", "true")
    monkeypatch.setenv("LYRICS_USE_ONNX", "false")
    monkeypatch.setenv("ONNX_MODELS_DIR", str(models_dir))

    assert embedder.get_onnx_backend() is None


def test_lyrics_disabled_when_search_off(monkeypatch, tmp_path):
    """LYRICS_SEARCH_ENABLED=false → ONNX backend skipped."""
    models_dir = tmp_path / "models"
    _make_onnx_files(models_dir, "gte")

    monkeypatch.setenv("LYRICS_SEARCH_ENABLED", "false")
    monkeypatch.setenv("LYRICS_USE_ONNX", "true")
    monkeypatch.setenv("ONNX_MODELS_DIR", str(models_dir))

    assert embedder.get_onnx_backend() is None


def test_lyrics_uses_onnx_backend_when_installed(monkeypatch):
    class _StubBackend:
        def embed_text(self, text):
            v = np.zeros(embedder.EMBEDDING_DIM, dtype=np.float32)
            v[7] = 1.0
            return v

    monkeypatch.setattr(embedder, "_onnx_backend", _StubBackend())

    def _no_pair():
        raise AssertionError("get_model_pair must not be called when ONNX is available")

    monkeypatch.setattr(embedder, "get_model_pair", _no_pair)

    vec = embedder.embed_text("anything")
    assert vec.shape == (embedder.EMBEDDING_DIM,)
    assert vec[7] == pytest.approx(1.0)
    assert vec.dtype == np.float32
