"""Sentence-embedding backend for lyrics search.

Uses HuggingFace ``transformers`` to load the GTE-multilingual model and
mean-pool the token embeddings into a single sentence vector. Lazily
loaded — the model is ~500 MB on first download.

Tests should monkeypatch ``embed_text`` directly to avoid loading the model.
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


def _ensure_lock():
    global _lock
    if _lock is None:
        import threading  # noqa: PLC0415
        _lock = threading.Lock()
    return _lock


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


def embed_text(text: str):
    """Encode a single string. Returns numpy.float32 1D array."""
    import numpy as np  # noqa: PLC0415

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
