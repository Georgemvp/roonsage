"""CLAP (Contrastive Language-Audio Pretraining) text-to-audio search.

Loads a laion-clap model lazily and exposes:

* ``batch_analyze_clap`` — iterate tracks that have a ``file_path`` resolved
  by ``path_resolver`` and don't yet have a stored embedding; compute the
  CLAP audio embedding and persist it as ``np.float32`` bytes in
  ``clap_embeddings.embedding``.
* ``search_by_text`` — encode a free-text query with the CLAP text encoder
  and rank stored embeddings by cosine similarity.

The model itself is large (~600 MB) and downloads on first use. ``CLAP_ENABLED``
must be ``true`` for any of this to run. Tests mock the encoder.
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
    model = get_model()
    if model is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")

    try:
        import numpy as np          # noqa: PLC0415
        import soundfile as sf      # noqa: PLC0415

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

        emb = model.get_audio_embedding_from_data([data], use_tensor=False)
        return emb[0]

    except Exception as exc:
        logger.debug("Fast audio clip failed for %s (%s) — falling back to filelist", audio_path, exc)
        emb = model.get_audio_embedding_from_filelist([audio_path], use_tensor=False)
        return emb[0]


def search_by_text(
    conn: sqlite3.Connection,
    query: str,
    limit: int = 25,
) -> list[dict[str, Any]]:
    """Encode the query and return top tracks by cosine similarity."""
    import numpy as np  # noqa: PLC0415

    model = get_model()
    if model is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")

    keys, matrix = load_all_embeddings(conn)
    if not keys:
        return []

    text_emb = model.get_text_embedding([query], use_tensor=False)[0]
    text_emb = np.asarray(text_emb, dtype=np.float32)
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

    model = get_model()
    if model is None:
        raise RuntimeError("CLAP model not available — set CLAP_ENABLED=true")

    rows = conn.execute(
        """SELECT af.item_key, af.file_path
           FROM track_audio_features af
           LEFT JOIN clap_embeddings ce ON ce.item_key = af.item_key
           WHERE af.file_path IS NOT NULL AND ce.item_key IS NULL"""
    ).fetchall()

    n_total = len(rows)
    n_done = 0
    n_failed = 0
    model_name = get_clap_model()

    started = datetime.now(UTC).isoformat()
    _set_state(
        conn, "running",
        started_at=started, finished_at=None,
        n_total=n_total, n_done=0, n_failed=0, error_message=None,
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
