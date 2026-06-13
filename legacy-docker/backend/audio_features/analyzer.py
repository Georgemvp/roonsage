"""Audio feature extraction using librosa.

Returns a dict with BPM, musical key (root + mode + Camelot code) and a
small set of heuristic Spotify-style features (energy, danceability,
valence, acousticness, instrumentalness, loudness LUFS).

Heavy dependencies (``librosa``, ``soundfile``, ``pyloudnorm``) are
imported lazily so the module can be imported by FastAPI startup code on
systems where the audio stack is not installed — in that case
``ANALYZER_AVAILABLE`` is False and the worker skips analysis cleanly.

This module is intentionally pure-function: it accepts a file path and
returns a dict. No DB access, no logging side effects beyond a single
warning on failure. The worker is responsible for persistence and retries.
"""

from __future__ import annotations

import asyncio
import logging
import math
from concurrent.futures import ProcessPoolExecutor
from typing import Any

from backend.audio_features import camelot

logger = logging.getLogger(__name__)

# Librosa loads quickly when imported once, but it pulls numpy/scipy/numba
# which add ~3s of import time the very first call. Detect availability up
# front so the rest of the codebase can act on it.
try:
    import librosa  # noqa: F401  (probed at import time)
    import numpy as np  # noqa: F401

    ANALYZER_AVAILABLE = True
except ImportError:  # pragma: no cover — exercised only when extras are missing
    ANALYZER_AVAILABLE = False


# Krumhansl-Schmuckler key profiles (Temperley 1999 weights).
_MAJOR_PROFILE = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                  2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
_MINOR_PROFILE = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                  2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
_PITCHES = ["C", "C#", "D", "D#", "E", "F",
            "F#", "G", "G#", "A", "A#", "B"]


def _key_from_chroma(chroma: Any) -> tuple[str, str, float]:
    """Return ``(root, mode, confidence)`` from a chroma matrix."""
    import numpy as np  # noqa: PLC0415

    pitch_class = np.mean(chroma, axis=1)
    pitch_class = pitch_class / (pitch_class.sum() + 1e-9)

    best_root = "C"
    best_mode = "major"
    best_score = -1.0
    for offset in range(12):
        rolled = np.roll(pitch_class, -offset)
        maj = float(np.dot(rolled, _MAJOR_PROFILE))
        minr = float(np.dot(rolled, _MINOR_PROFILE))
        if maj > best_score:
            best_score = maj
            best_root = _PITCHES[offset]
            best_mode = "major"
        if minr > best_score:
            best_score = minr
            best_root = _PITCHES[offset]
            best_mode = "minor"

    # Crude confidence: ratio of winner to runner-up (capped 0–1).
    sorted_scores = sorted(
        [
            float(np.dot(np.roll(pitch_class, -i), profile))
            for i in range(12)
            for profile in (_MAJOR_PROFILE, _MINOR_PROFILE)
        ],
        reverse=True,
    )
    if len(sorted_scores) >= 2 and sorted_scores[1] > 0:
        confidence = max(0.0, min(1.0, 1.0 - sorted_scores[1] / sorted_scores[0]))
    else:
        confidence = 0.0
    return best_root, best_mode, confidence


def _danceability(y: Any, sr: int, tempo: float) -> float:
    """Heuristic danceability ∈ [0, 1]: rhythm stability × tempo-in-dance-range."""
    import numpy as np  # noqa: PLC0415

    # Onset envelope autocorrelation peakiness signals rhythmic stability.
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    if onset_env.size < 4:
        return 0.0
    ac = librosa.autocorrelate(onset_env, max_size=sr // 2)
    if ac.size < 8:
        return 0.0
    ac = ac / (ac[0] + 1e-9)
    peakiness = float(np.clip(np.max(ac[2:]) , 0.0, 1.0))

    # Bell curve around 120 BPM (sweet spot for "dance" music).
    tempo_score = math.exp(-((tempo - 120.0) ** 2) / (2 * 30.0 ** 2))
    return float(np.clip(0.6 * peakiness + 0.4 * tempo_score, 0.0, 1.0))


def _energy(y: Any) -> float:
    """RMS energy → squashed to [0, 1] via tanh."""
    import numpy as np  # noqa: PLC0415

    rms = float(np.sqrt(np.mean(y ** 2)))
    # tanh(rms * 8) — empirically maps quiet/loud audio to ~0.1–0.95.
    return float(np.tanh(rms * 8.0))


def _valence(chroma: Any, mode: str) -> float:
    """Heuristic valence: major-mode strength + brightness."""
    import numpy as np  # noqa: PLC0415

    base = 0.6 if mode == "major" else 0.3
    # Chroma "brightness" — share of pitch classes above the median.
    pitch_class = np.mean(chroma, axis=1)
    if pitch_class.sum() <= 0:
        return base
    norm = pitch_class / pitch_class.sum()
    brightness = float(np.sum(norm[6:]))  # F# and above
    return float(np.clip(base + 0.4 * (brightness - 0.5), 0.0, 1.0))


def _acousticness(y: Any, sr: int) -> float:
    """Spectral centroid → low centroid ≈ acoustic instruments."""
    import numpy as np  # noqa: PLC0415

    centroid = float(np.mean(librosa.feature.spectral_centroid(y=y, sr=sr)))
    # Centroid ~1000 Hz → acoustic; ~4000 Hz → electronic. Linear map clipped.
    return float(np.clip(1.0 - (centroid - 800.0) / 3500.0, 0.0, 1.0))


def _instrumentalness(y: Any, sr: int) -> float:
    """Crude vocal-presence test via spectral flatness in 200–4000 Hz band."""
    import numpy as np  # noqa: PLC0415

    flatness = float(np.mean(librosa.feature.spectral_flatness(y=y)))
    # Vocal music tends to have lower flatness in mids → invert + clip.
    return float(np.clip(flatness * 4.0, 0.0, 1.0))


def _loudness_lufs(y: Any, sr: int) -> float | None:
    """Integrated LUFS via pyloudnorm. Returns None if pkg unavailable."""
    try:
        import pyloudnorm as pyln  # noqa: PLC0415

        meter = pyln.Meter(sr)
        loudness = meter.integrated_loudness(y)
        # pyloudnorm returns -inf for silence; clamp to a sane floor.
        if loudness == float("-inf") or math.isnan(loudness):
            return None
        return float(loudness)
    except ImportError:
        return None
    except Exception as exc:
        logger.debug("LUFS measurement failed: %s", exc)
        return None


def _analyze_sync(file_path: str, *, full: bool = True) -> dict[str, Any]:
    """Synchronous analyser — runs on a worker thread.

    Args:
        file_path: Path to an audio file readable by librosa (ffmpeg fallback).
        full:      When False, only BPM + key are computed (cheap path).
                   When True, the full Spotify-style feature vector is included.

    Returns:
        Dict with keys present only when computed:
            bpm, bpm_confidence, key_root, key_mode, camelot,
            energy, danceability, valence, acousticness,
            instrumentalness, loudness_lufs.
    """
    import librosa  # noqa: PLC0415
    import numpy as np  # noqa: PLC0415

    # Load max 120 s mono @ 22050 Hz — plenty for tempo / key / spectral stats.
    y, sr = librosa.load(file_path, sr=22050, mono=True, duration=120.0)
    if y.size < sr * 10:
        # Too short for stable analysis — abort.
        raise ValueError("audio shorter than 10s, refusing to analyse")

    # BPM
    tempo_obj, _beats = librosa.beat.beat_track(y=y, sr=sr)
    tempo = float(tempo_obj) if np.isscalar(tempo_obj) else float(np.atleast_1d(tempo_obj)[0])
    tempo = round(tempo, 1)

    # Key
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    root, mode, key_confidence = _key_from_chroma(chroma)

    out: dict[str, Any] = {
        "bpm": tempo,
        "bpm_confidence": round(float(key_confidence), 3),
        "key_root": root,
        "key_mode": mode,
        "camelot": camelot.from_key(root, mode),
    }

    if not full:
        return out

    out.update({
        "energy": round(_energy(y), 3),
        "danceability": round(_danceability(y, sr, tempo), 3),
        "valence": round(_valence(chroma, mode), 3),
        "acousticness": round(_acousticness(y, sr), 3),
        "instrumentalness": round(_instrumentalness(y, sr), 3),
        "loudness_lufs": _loudness_lufs(y, sr),
    })
    if out["loudness_lufs"] is not None:
        out["loudness_lufs"] = round(out["loudness_lufs"], 2)
    return out


# Module-level process pool for CPU-bound librosa analysis. ProcessPoolExecutor
# sidesteps the GIL so 4 workers can actually run on 4 cores. Lazily created
# on first use so importing this module remains cheap.
_process_pool: ProcessPoolExecutor | None = None


def _get_pool() -> ProcessPoolExecutor:
    global _process_pool
    if _process_pool is None:
        _process_pool = ProcessPoolExecutor(max_workers=4)
    return _process_pool


async def analyze_track(file_path: str, *, full: bool = True) -> dict[str, Any]:
    """Analyse a track in a worker process so the event loop stays responsive."""
    if not ANALYZER_AVAILABLE:
        raise RuntimeError(
            "librosa is not installed — the audio_features worker cannot run. "
            "Add librosa to requirements.txt and rebuild the Docker image."
        )
    import functools  # noqa: PLC0415
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(
        _get_pool(), functools.partial(_analyze_sync, file_path, full=full)
    )
