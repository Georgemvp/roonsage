"""CLAP (Contrastive Language-Audio Pretraining) text-to-audio search.

Two inference backends with auto-detection:

1. **ONNX Runtime** (preferred when available) — loads
   ``data/models/clap_audio_encoder.onnx`` + ``clap_text_encoder.onnx`` and uses
   ``tokenizers`` for the RoBERTa text tokenization. Smaller RAM footprint,
   faster cold start. Built by ``scripts/export_clap_onnx.py``.
2. **laion-clap (PyTorch)** — original full model, ~600 MB on first download.
   Used as a fallback when ONNX files are missing or ``CLAP_USE_ONNX=false``.

Public surface:

* ``batch_analyze_clap`` — iterate tracks that have a ``file_path`` resolved
  by ``path_resolver`` and don't yet have a stored embedding; compute the
  CLAP audio embedding and persist it as ``np.float32`` bytes in
  ``clap_embeddings.embedding``.
* ``search_by_text`` — encode a free-text query with the CLAP text encoder
  and rank stored embeddings by cosine similarity.

``CLAP_ENABLED`` must be ``true`` for any of this to run. Tests mock the
encoder via ``get_model`` (ONNX path is skipped automatically when the files
aren't present).
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import sqlite3

logger = logging.getLogger(__name__)

EMBEDDING_DIM = 512  # laion-clap default

_model = None
_model_lock = None  # lazy threading import to keep cold start fast


# ---------------------------------------------------------------------------
# Model lifecycle
# ---------------------------------------------------------------------------


def _ensure_lock():
    global _model_lock
    if _model_lock is None:
        import threading  # noqa: PLC0415
        _model_lock = threading.Lock()
    return _model_lock


def get_model():
    """Lazy load + cache the CLAP model. Returns None if disabled or import fails."""
    global _model
    if _model is not None:
        return _model

    from backend.config import get_clap_enabled, get_clap_model  # noqa: PLC0415
    if not get_clap_enabled():
        return None

    lock = _ensure_lock()
    with lock:
        if _model is not None:
            return _model
        try:
            import laion_clap  # noqa: PLC0415
        except ImportError as exc:
            logger.warning("laion-clap not installed: %s", exc)
            return None

        try:
            from backend.config import get_clap_cache_dir  # noqa: PLC0415
            model = laion_clap.CLAP_Module(enable_fusion=False)
            ckpt = get_clap_model()
            if ckpt and ckpt != "laion/larger_clap_music_and_speech":
                model.load_ckpt(ckpt)
            else:
                # laion_clap always downloads to its own site-packages dir, which
                # is not writable by the non-root app user. Download the checkpoint
                # ourselves to the writable cache dir and pass the local path.
                cache_dir = get_clap_cache_dir()
                cache_dir.mkdir(parents=True, exist_ok=True)
                weight_name = "630k-audioset-best.pt"
                local_ckpt = cache_dir / weight_name
                if not local_ckpt.exists():
                    import urllib.request  # noqa: PLC0415
                    url = f"https://huggingface.co/lukewys/laion_clap/resolve/main/{weight_name}"
                    logger.info("Downloading CLAP checkpoint to %s", local_ckpt)
                    urllib.request.urlretrieve(url, local_ckpt)
                model.load_ckpt(str(local_ckpt))
            _model = model
            logger.info("CLAP model loaded (%s)", ckpt)
            return _model
        except Exception:
            logger.exception("Failed to load CLAP model")
            return None


def reset_model() -> None:
    """Drop the cached model (used by tests / config reloads)."""
    global _model
    _model = None
    reset_onnx_backend()


# ---------------------------------------------------------------------------
# ONNX backend (preferred when exported files exist on disk)
# ---------------------------------------------------------------------------


_onnx_backend: Any = None  # None = uninitialised; "missing" = checked, not available
_onnx_lock = None


def _ensure_onnx_lock():
    global _onnx_lock
    if _onnx_lock is None:
        import threading  # noqa: PLC0415
        _onnx_lock = threading.Lock()
    return _onnx_lock


def _ort_providers() -> list[str]:
    """Return best available ONNX Runtime execution providers.

    Prefers CoreMLExecutionProvider on Apple Silicon; falls back to CPU.
    Always includes CPUExecutionProvider as the final fallback.
    """
    import onnxruntime as ort  # noqa: PLC0415

    available = set(ort.get_available_providers())
    providers = [p for p in ("CoreMLExecutionProvider", "CPUExecutionProvider") if p in available]
    return providers or ["CPUExecutionProvider"]


class _OnnxClapBackend:
    """ONNX Runtime inference for the CLAP audio + text encoders.

    Loaded lazily by :func:`get_onnx_backend`. The audio session expects a
    ``(batch, 480_000)`` float32 waveform; the text session expects ``input_ids``
    and ``attention_mask`` int64 tensors. Both outputs are L2-normalized.
    """

    # RoBERTa-base config — laion-clap uses this tokenizer.
    _TOKENIZER_REPO = "roberta-base"
    _MAX_TEXT_LEN = 77
    _PAD_ID = 1  # roberta-base pad token

    def __init__(self, audio_path, text_path):
        import onnxruntime as ort  # noqa: PLC0415

        providers = _ort_providers()
        logger.info("CLAP ONNX using providers: %s", providers)
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 0  # let ORT pick based on available cores
        self.audio_sess = ort.InferenceSession(
            str(audio_path), sess_options=opts, providers=providers
        )
        self.text_sess = ort.InferenceSession(
            str(text_path), sess_options=opts, providers=providers
        )
        self.tokenizer = self._load_tokenizer()

    @classmethod
    def _load_tokenizer(cls):
        from tokenizers import Tokenizer  # noqa: PLC0415

        tok = Tokenizer.from_pretrained(cls._TOKENIZER_REPO)
        tok.enable_padding(length=cls._MAX_TEXT_LEN, pad_id=cls._PAD_ID, pad_token="<pad>")
        tok.enable_truncation(max_length=cls._MAX_TEXT_LEN)
        return tok

    def embed_audio(self, waveform):
        import numpy as np  # noqa: PLC0415

        wf = np.ascontiguousarray(waveform, dtype=np.float32)
        if wf.ndim == 1:
            wf = wf[None, :]
        out = self.audio_sess.run(["embedding"], {"waveform": wf})[0]
        return out[0]

    def embed_text(self, text: str):
        import numpy as np  # noqa: PLC0415

        enc = self.tokenizer.encode(text)
        input_ids = np.asarray([enc.ids], dtype=np.int64)
        attention_mask = np.asarray([enc.attention_mask], dtype=np.int64)
        out = self.text_sess.run(
            ["embedding"],
            {"input_ids": input_ids, "attention_mask": attention_mask},
        )[0]
        return out[0]


def get_onnx_backend():
    """Return the cached ONNX backend, or None if disabled / files missing."""
    global _onnx_backend
    if _onnx_backend is not None:
        return _onnx_backend if _onnx_backend != "missing" else None

    from backend.config import (  # noqa: PLC0415
        get_clap_enabled,
        get_clap_use_onnx,
        get_onnx_models_dir,
    )

    if not get_clap_enabled() or not get_clap_use_onnx():
        _onnx_backend = "missing"
        return None

    models_dir = get_onnx_models_dir()
    audio_path = models_dir / "clap_audio_encoder.onnx"
    text_path = models_dir / "clap_text_encoder.onnx"
    if not (audio_path.exists() and text_path.exists()):
        _onnx_backend = "missing"
        return None

    lock = _ensure_onnx_lock()
    with lock:
        if _onnx_backend is not None and _onnx_backend != "missing":
            return _onnx_backend
        try:
            backend = _OnnxClapBackend(audio_path, text_path)
        except Exception:
            logger.exception("Failed to load CLAP ONNX backend — falling back to laion_clap")
            _onnx_backend = "missing"
            return None
        _onnx_backend = backend
        logger.info("CLAP ONNX backend loaded from %s", models_dir)
        return _onnx_backend


def reset_onnx_backend() -> None:
    global _onnx_backend
    _onnx_backend = None


# ---------------------------------------------------------------------------
# Inference dispatch helpers
# ---------------------------------------------------------------------------


def _embed_audio_from_waveform(waveform):
    """Compute the 512-d CLAP embedding from a (480_000,) float32 waveform."""
    onnx = get_onnx_backend()
    if onnx is not None:
        return onnx.embed_audio(waveform)
    model = get_model()
    if model is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")
    return model.get_audio_embedding_from_data([waveform], use_tensor=False)[0]


def _embed_text(text: str):
    onnx = get_onnx_backend()
    if onnx is not None:
        return onnx.embed_text(text)
    model = get_model()
    if model is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")
    return model.get_text_embedding([text], use_tensor=False)[0]


# ---------------------------------------------------------------------------
# Run state
# ---------------------------------------------------------------------------


def get_status(conn: sqlite3.Connection) -> dict[str, Any]:
    row = conn.execute("SELECT * FROM clap_runs WHERE id = 1").fetchone()
    return dict(row) if row else {"status": "idle"}


def _set_state(
    conn: sqlite3.Connection,
    status: str,
    **fields: Any,
) -> None:
    sets = ["status = ?"]
    args: list[Any] = [status]
    for k, v in fields.items():
        sets.append(f"{k} = ?")
        args.append(v)
    conn.execute(f"UPDATE clap_runs SET {', '.join(sets)} WHERE id = 1", args)
    conn.commit()


# ---------------------------------------------------------------------------
# Storage helpers
# ---------------------------------------------------------------------------


def _serialize(vec) -> bytes:
    import numpy as np  # noqa: PLC0415
    return np.asarray(vec, dtype=np.float32).tobytes()


def _deserialize(blob: bytes):
    import numpy as np  # noqa: PLC0415
    return np.frombuffer(blob, dtype=np.float32)


def _store_embedding(
    conn: sqlite3.Connection, item_key: str, embedding, model_name: str
) -> None:
    conn.execute(
        """INSERT INTO clap_embeddings (item_key, embedding, model, analyzed_at)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(item_key) DO UPDATE SET
             embedding = excluded.embedding,
             model = excluded.model,
             analyzed_at = excluded.analyzed_at""",
        (item_key, _serialize(embedding), model_name, datetime.now(UTC).isoformat()),
    )


def load_all_embeddings(conn: sqlite3.Connection) -> tuple[list[str], Any]:
    """Pull every stored CLAP embedding as a (keys, numpy matrix) pair."""
    import numpy as np  # noqa: PLC0415
    rows = conn.execute("SELECT item_key, embedding FROM clap_embeddings").fetchall()
    if not rows:
        return [], np.zeros((0, EMBEDDING_DIM), dtype=np.float32)
    keys = [r["item_key"] for r in rows]
    matrix = np.stack([_deserialize(r["embedding"]) for r in rows])
    return keys, matrix


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


_CLAP_SR = 48_000       # sample rate the model was trained at
_CLAP_FRAMES = 480_000  # 10 s × 48 kHz — exactly what get_audio_features expects


def analyze_track_clap(audio_path: str):
    """Compute the CLAP audio embedding for a single file. Returns numpy 1D array.

    Reads only the first 10 seconds of audio via soundfile to avoid loading the
    entire file through Docker's virtual filesystem — reduces I/O by 20-30× for
    typical music files while producing identical embeddings (CLAP clips to 10 s
    internally regardless).
    """
    onnx = get_onnx_backend()
    model = get_model() if onnx is None else None
    if onnx is None and model is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")

    try:
        import numpy as np  # noqa: PLC0415
        import soundfile as sf  # noqa: PLC0415

        info = sf.info(audio_path)
        native_sr = info.samplerate
        # Skip the intro: start 30 s in (or 20 % of track if shorter).
        # The body of a song is far more representative than the opening bars,
        # and body-to-body cosine similarity is ~0.89 vs intro-to-body ~0.73.
        skip_sec = min(30.0, info.duration * 0.20)
        start_frame = min(int(native_sr * skip_sec), max(0, info.frames - int(native_sr * 12)))
        # Read slightly more than 10 s so resampling doesn't lose the tail.
        frames_to_read = min(int(native_sr * 11), info.frames - start_frame)
        data, _ = sf.read(audio_path, start=start_frame, frames=frames_to_read, dtype="float32", always_2d=True)
        # (frames, channels) → mono
        data = data.mean(axis=1)

        if native_sr != _CLAP_SR:
            import librosa  # noqa: PLC0415
            data = librosa.resample(data, orig_sr=native_sr, target_sr=_CLAP_SR)

        # Hard-clip or pad to exactly _CLAP_FRAMES
        if len(data) >= _CLAP_FRAMES:
            data = data[:_CLAP_FRAMES]
        else:
            data = np.pad(data, (0, _CLAP_FRAMES - len(data)))

        return _embed_audio_from_waveform(data)

    except Exception as exc:
        logger.debug("Fast audio clip failed for %s (%s) — falling back to filelist", audio_path, exc)
        # The filelist fallback (laion_clap reads the file itself) only works
        # with the PyTorch model. If we're in ONNX-only mode, load the heavy
        # model on demand as a last resort for this one file.
        fb_model = model or get_model()
        if fb_model is None:
            raise
        emb = fb_model.get_audio_embedding_from_filelist([audio_path], use_tensor=False)
        return emb[0]


def search_by_text(
    conn: sqlite3.Connection,
    query: str,
    limit: int = 25,
) -> list[dict[str, Any]]:
    """Encode the query and return top tracks by cosine similarity."""
    import numpy as np  # noqa: PLC0415

    if get_onnx_backend() is None and get_model() is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")

    keys, matrix = load_all_embeddings(conn)
    if not keys:
        return []

    text_emb = np.asarray(_embed_text(query), dtype=np.float32)
    text_norm = text_emb / (np.linalg.norm(text_emb) + 1e-12)
    mat_norm = matrix / (np.linalg.norm(matrix, axis=1, keepdims=True) + 1e-12)
    scores = mat_norm @ text_norm  # cosine similarities

    # Fetch more candidates than needed so deduplication doesn't starve the result set.
    top_idx = np.argsort(-scores)[:limit * 6]
    placeholders = ",".join("?" for _ in top_idx)
    top_keys = [keys[i] for i in top_idx]
    rows = conn.execute(
        f"""SELECT t.item_key, t.title, t.artist, t.album, t.year
            FROM tracks t WHERE t.item_key IN ({placeholders})""",
        top_keys,
    ).fetchall()
    by_key = {r["item_key"]: dict(r) for r in rows}

    # Deduplicate: keep only the highest-scoring match per unique (artist, title) pair.
    # The same recording often appears on multiple albums in Roon, each with its own embedding.
    seen: set[tuple[str, str]] = set()
    out: list[dict[str, Any]] = []
    for idx in top_idx:
        if len(out) >= limit:
            break
        k = keys[int(idx)]
        meta = by_key.get(k, {"item_key": k})
        dedup_key = (
            (meta.get("artist") or "").lower().strip(),
            (meta.get("title") or "").lower().strip(),
        )
        if dedup_key in seen:
            continue
        seen.add(dedup_key)
        meta["similarity"] = float(scores[int(idx)])
        out.append(meta)
    return out


def batch_analyze_clap(conn: sqlite3.Connection) -> dict[str, Any]:
    """Iterate tracks needing analysis and store CLAP embeddings.

    Pulls candidate ``(item_key, file_path)`` rows from
    ``track_audio_features`` (path_resolver populates ``file_path`` there).
    Skips items that already have an embedding.
    """
    from backend.config import get_clap_model  # noqa: PLC0415

    if get_onnx_backend() is None and get_model() is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")

    rows = conn.execute(
        """SELECT af.item_key, af.file_path
           FROM track_audio_features af
           LEFT JOIN clap_embeddings ce ON ce.item_key = af.item_key
           WHERE af.file_path IS NOT NULL AND ce.item_key IS NULL"""
    ).fetchall()

    # Grand total = already done + still remaining, so the progress bar never jumps back.
    n_already = conn.execute("SELECT COUNT(*) FROM clap_embeddings").fetchone()[0]
    n_remaining = len(rows)
    n_total = n_already + n_remaining
    n_done = n_already
    n_failed = 0
    model_name = get_clap_model()

    started = datetime.now(UTC).isoformat()
    _set_state(
        conn, "running",
        started_at=started, finished_at=None,
        n_total=n_total, n_done=n_done, n_failed=0, error_message=None,
    )

    try:
        for r in rows:
            try:
                emb = analyze_track_clap(r["file_path"])
                _store_embedding(conn, r["item_key"], emb, model_name)
                n_done += 1
            except Exception as exc:
                logger.warning("CLAP analyze failed for %s: %s", r["item_key"], exc)
                n_failed += 1
            if (n_done + n_failed) % 5 == 0:
                _set_state(conn, "running", n_done=n_done, n_failed=n_failed)
                conn.commit()

        _set_state(
            conn, "complete",
            finished_at=datetime.now(UTC).isoformat(),
            n_done=n_done, n_failed=n_failed,
        )
        return {"status": "complete", "n_total": n_total, "n_done": n_done, "n_failed": n_failed}
    except Exception as exc:
        logger.exception("CLAP batch analysis failed")
        _set_state(
            conn, "failed",
            finished_at=datetime.now(UTC).isoformat(),
            n_done=n_done, n_failed=n_failed,
            error_message=str(exc),
        )
        raise
