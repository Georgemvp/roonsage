"""Sentence-embedding backend for lyrics search.

Two inference backends with auto-detection:

1. **ONNX Runtime** (preferred when available) — loads
   ``data/models/gte_multilingual.onnx`` + the matching tokenizer in
   ``data/models/gte_tokenizer/``. Built by ``scripts/export_gte_onnx.py``.
2. **HuggingFace transformers** — original GTE-multilingual via ``AutoModel``,
   ~500 MB on first download. Used when ONNX files are missing or
   ``LYRICS_USE_ONNX=false``.

Tests should monkeypatch ``embed_text`` directly to avoid loading any model.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

EMBEDDING_DIM = 768  # GTE-base output size

_tokenizer = None
_model = None
_lock = None

_onnx_backend: Any = None  # None = uninitialised; "missing" = checked, not available
_onnx_lock = None


def _ensure_lock():
    global _lock
    if _lock is None:
        import threading  # noqa: PLC0415
        _lock = threading.Lock()
    return _lock


def _ensure_onnx_lock():
    global _onnx_lock
    if _onnx_lock is None:
        import threading  # noqa: PLC0415
        _onnx_lock = threading.Lock()
    return _onnx_lock


def get_model_pair():
    """Lazy-load (tokenizer, model). Returns (None, None) on failure / disabled."""
    global _tokenizer, _model
    if _tokenizer is not None and _model is not None:
        return _tokenizer, _model

    from backend.config import get_lyrics_model, get_lyrics_search_enabled  # noqa: PLC0415

    if not get_lyrics_search_enabled():
        return None, None

    lock = _ensure_lock()
    with lock:
        if _tokenizer is not None and _model is not None:
            return _tokenizer, _model
        try:
            from transformers import AutoModel, AutoTokenizer  # noqa: PLC0415
        except ImportError as exc:
            logger.warning("transformers not installed: %s", exc)
            return None, None

        try:
            model_id = get_lyrics_model()
            _tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
            _model = AutoModel.from_pretrained(model_id, trust_remote_code=True)
            _model.eval()
            logger.info("Lyrics model loaded (%s)", model_id)
            return _tokenizer, _model
        except Exception:
            logger.exception("Failed to load lyrics model")
            return None, None


def reset_model() -> None:
    global _tokenizer, _model
    _tokenizer = None
    _model = None
    reset_onnx_backend()


# ---------------------------------------------------------------------------
# ONNX backend (preferred when exported file exists on disk)
# ---------------------------------------------------------------------------


class _OnnxLyricsBackend:
    """ONNX Runtime inference for GTE-multilingual.

    Mean-pools the model's ``last_hidden_state`` masked by ``attention_mask``
    to produce a single sentence vector — matches the transformers path exactly.
    """

    def __init__(self, model_path, tokenizer_dir):
        import onnxruntime as ort  # noqa: PLC0415
        from tokenizers import Tokenizer  # noqa: PLC0415

        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 0
        self.session = ort.InferenceSession(
            str(model_path), sess_options=opts, providers=["CPUExecutionProvider"]
        )
        # Tokenizer was saved by `optimum`; tokenizer.json is the fast format.
        tok_json = tokenizer_dir / "tokenizer.json"
        if not tok_json.exists():
            raise FileNotFoundError(f"missing tokenizer.json at {tok_json}")
        tok = Tokenizer.from_file(str(tok_json))
        tok.enable_truncation(max_length=512)
        # Padding to longest is fine for single-string encoding; dynamic axes
        # in the exported model accept variable sequence length.
        self.tokenizer = tok
        # Cache the set of expected input names so we know whether to provide
        # token_type_ids (BERT-style models need it; GTE doesn't).
        self._input_names = {inp.name for inp in self.session.get_inputs()}

    def embed_text(self, text: str):
        import numpy as np  # noqa: PLC0415

        enc = self.tokenizer.encode(text)
        ids = np.asarray([enc.ids], dtype=np.int64)
        mask = np.asarray([enc.attention_mask], dtype=np.int64)
        feeds: dict[str, Any] = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self._input_names:
            feeds["token_type_ids"] = np.zeros_like(ids)

        outputs = self.session.run(None, feeds)
        # The exported feature-extraction head returns last_hidden_state first.
        last = outputs[0]  # (1, L, D)
        mask_f = mask.astype(np.float32)[..., None]
        summed = (last * mask_f).sum(axis=1)
        counts = mask_f.sum(axis=1).clip(min=1)
        pooled = (summed / counts).squeeze(0)
        return np.asarray(pooled, dtype=np.float32)


def get_onnx_backend():
    """Return the cached ONNX backend, or None if disabled / files missing."""
    global _onnx_backend
    if _onnx_backend is not None:
        return _onnx_backend if _onnx_backend != "missing" else None

    from backend.config import (  # noqa: PLC0415
        get_lyrics_search_enabled,
        get_lyrics_use_onnx,
        get_onnx_models_dir,
    )

    if not get_lyrics_search_enabled() or not get_lyrics_use_onnx():
        _onnx_backend = "missing"
        return None

    models_dir = get_onnx_models_dir()
    model_path = models_dir / "gte_multilingual.onnx"
    tokenizer_dir = models_dir / "gte_tokenizer"
    if not (model_path.exists() and tokenizer_dir.exists()):
        _onnx_backend = "missing"
        return None

    lock = _ensure_onnx_lock()
    with lock:
        if _onnx_backend is not None and _onnx_backend != "missing":
            return _onnx_backend
        try:
            backend = _OnnxLyricsBackend(model_path, tokenizer_dir)
        except Exception:
            logger.exception("Failed to load lyrics ONNX backend — falling back to transformers")
            _onnx_backend = "missing"
            return None
        _onnx_backend = backend
        logger.info("Lyrics ONNX backend loaded from %s", models_dir)
        return _onnx_backend


def reset_onnx_backend() -> None:
    global _onnx_backend
    _onnx_backend = None


def embed_text(text: str):
    """Encode a single string. Returns numpy.float32 1D array."""
    import numpy as np  # noqa: PLC0415

    onnx = get_onnx_backend()
    if onnx is not None:
        return np.asarray(onnx.embed_text(text), dtype=np.float32)

    tok, model = get_model_pair()
    if tok is None or model is None:
        raise RuntimeError(
            "Lyrics embedder unavailable — set LYRICS_SEARCH_ENABLED=true "
            "and install transformers."
        )

    import torch  # noqa: PLC0415

    with torch.no_grad():
        enc = tok(
            [text],
            padding=True,
            truncation=True,
            max_length=512,
            return_tensors="pt",
        )
        out = model(**enc)
        # Mean-pool the last hidden state, masked by the attention mask.
        last = out.last_hidden_state
        mask = enc["attention_mask"].unsqueeze(-1).float()
        summed = (last * mask).sum(dim=1)
        counts = mask.sum(dim=1).clamp(min=1)
        pooled = (summed / counts).squeeze(0).cpu().numpy()
    return np.asarray(pooled, dtype=np.float32)


# ---------------------------------------------------------------------------
# Storage helpers + batch worker
# ---------------------------------------------------------------------------


def _serialize(vec) -> bytes:
    import numpy as np  # noqa: PLC0415
    return np.asarray(vec, dtype=np.float32).tobytes()


def _deserialize(blob: bytes):
    import numpy as np  # noqa: PLC0415
    return np.frombuffer(blob, dtype=np.float32)


def load_all_embeddings(conn: sqlite3.Connection) -> tuple[list[str], Any]:
    import numpy as np  # noqa: PLC0415
    rows = conn.execute("SELECT item_key, embedding FROM lyrics_embeddings").fetchall()
    if not rows:
        return [], np.zeros((0, EMBEDDING_DIM), dtype=np.float32)
    keys = [r["item_key"] for r in rows]
    matrix = np.stack([_deserialize(r["embedding"]) for r in rows])
    return keys, matrix


def get_status(conn: sqlite3.Connection) -> dict[str, Any]:
    row = conn.execute("SELECT * FROM lyrics_runs WHERE id = 1").fetchone()
    return dict(row) if row else {"status": "idle"}


def _set_state(conn: sqlite3.Connection, status: str, **fields: Any) -> None:
    sets = ["status = ?"]
    args: list[Any] = [status]
    for k, v in fields.items():
        sets.append(f"{k} = ?")
        args.append(v)
    conn.execute(f"UPDATE lyrics_runs SET {', '.join(sets)} WHERE id = 1", args)
    conn.commit()


def batch_embed_lyrics(conn: sqlite3.Connection) -> dict[str, Any]:
    """Extract lyrics from disk + embed every track that has a resolved path.

    Two passes folded into one loop for simplicity:
      1. Read the file, extract embedded lyrics into ``lyrics_data``.
      2. Embed the text into ``lyrics_embeddings``.
    """
    from backend.config import get_lyrics_model  # noqa: PLC0415
    from backend.lyrics.extractor import extract_lyrics  # noqa: PLC0415

    rows = conn.execute(
        """SELECT af.item_key, af.file_path
           FROM track_audio_features af
           LEFT JOIN lyrics_embeddings le ON le.item_key = af.item_key
           WHERE af.file_path IS NOT NULL AND le.item_key IS NULL"""
    ).fetchall()

    n_total = len(rows)
    n_extracted = 0
    n_embedded = 0
    n_no_lyrics = 0
    n_failed = 0
    model_name = get_lyrics_model()

    _set_state(
        conn, "running",
        started_at=datetime.now(UTC).isoformat(),
        finished_at=None,
        n_total=n_total, n_extracted=0, n_embedded=0, n_no_lyrics=0, n_failed=0,
        error_message=None,
    )

    try:
        for r in rows:
            ikey = r["item_key"]
            path = r["file_path"]
            try:
                lyrics = extract_lyrics(path)
                if not lyrics:
                    n_no_lyrics += 1
                    conn.execute(
                        """INSERT INTO lyrics_data
                           (item_key, lyrics, language, source, extracted_at)
                           VALUES (?, NULL, NULL, 'tag', ?)
                           ON CONFLICT(item_key) DO NOTHING""",
                        (ikey, datetime.now(UTC).isoformat()),
                    )
                    continue

                n_extracted += 1
                conn.execute(
                    """INSERT INTO lyrics_data
                       (item_key, lyrics, language, source, extracted_at)
                       VALUES (?, ?, NULL, 'tag', ?)
                       ON CONFLICT(item_key) DO UPDATE SET
                         lyrics = excluded.lyrics,
                         extracted_at = excluded.extracted_at""",
                    (ikey, lyrics, datetime.now(UTC).isoformat()),
                )

                emb = embed_text(lyrics)
                conn.execute(
                    """INSERT INTO lyrics_embeddings
                       (item_key, embedding, model_version, embedded_at)
                       VALUES (?, ?, ?, ?)
                       ON CONFLICT(item_key) DO UPDATE SET
                         embedding = excluded.embedding,
                         model_version = excluded.model_version,
                         embedded_at = excluded.embedded_at""",
                    (ikey, _serialize(emb), model_name, datetime.now(UTC).isoformat()),
                )
                n_embedded += 1
            except Exception as exc:
                logger.warning("lyrics pipeline failed for %s: %s", ikey, exc)
                n_failed += 1

            if (n_extracted + n_no_lyrics + n_failed) % 5 == 0:
                _set_state(
                    conn, "running",
                    n_extracted=n_extracted,
                    n_embedded=n_embedded,
                    n_no_lyrics=n_no_lyrics,
                    n_failed=n_failed,
                )

        _set_state(
            conn, "complete",
            finished_at=datetime.now(UTC).isoformat(),
            n_extracted=n_extracted,
            n_embedded=n_embedded,
            n_no_lyrics=n_no_lyrics,
            n_failed=n_failed,
        )
        return {
            "status": "complete",
            "n_total": n_total,
            "n_extracted": n_extracted,
            "n_embedded": n_embedded,
            "n_no_lyrics": n_no_lyrics,
            "n_failed": n_failed,
        }
    except Exception as exc:
        logger.exception("Lyrics batch failed")
        _set_state(
            conn, "failed",
            finished_at=datetime.now(UTC).isoformat(),
            error_message=str(exc),
            n_extracted=n_extracted,
            n_embedded=n_embedded,
            n_no_lyrics=n_no_lyrics,
            n_failed=n_failed,
        )
        raise
