#!/usr/bin/env python3
"""Convert LAION-CLAP (music) to Core ML for the RoonSage native analyzer.

This is a BUILD-TIME tool. It runs once on a developer machine to produce two
``.mlpackage`` models that the Swift analyzer loads at runtime — there is no
Python at runtime.

    audio encoder : input_features (log-mel) -> 512-dim joint embedding
    text encoder  : input_ids + attention_mask -> 512-dim joint embedding

Both embeddings live in CLAP's shared audio/text space, so cosine(audio, text)
is meaningful — that is what powers mood scoring and free-text search.

------------------------------------------------------------------------------
Tested environment (see native/.venv). Python 3.9.
    pip install \
        numpy==1.26.4 \
        torch==2.4.1 \
        transformers==4.44.2 \
        coremltools==8.1 \
        soundfile==0.12.1 \
        librosa==0.10.2
------------------------------------------------------------------------------

Usage:
    # 1) convert both encoders + dump the mel front-end config Swift must mirror
    python convert_clap_to_coreml.py convert --out ../RoonSage/Resources/CLAP

    # 2) de-risk: PyTorch <-> Core ML parity + cosine matrix on real tracks
    python convert_clap_to_coreml.py validate --out ../RoonSage/Resources/CLAP \
        /Volumes/4tbdrive/SoulSync-Downloads/*.flac

The CLAP feature-extractor parameters (sample rate, n_fft, hop, n_mels, the mel
filter-bank matrix itself, fixed frame count) are written to ``clap_mel.json``
next to the models. Step 1 (CLAPModel.swift) reproduces that front-end exactly
so Swift-computed mels match the PyTorch processor bit-for-bit.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

# Default model — matches legacy CLAUDE.md CLAP_MODEL default.
DEFAULT_MODEL = os.environ.get("CLAP_MODEL", "laion/larger_clap_music_and_speech")
# Mood labels scored via cosine(audio_embed, text_embed(label)). English prompts
# (CLAP is trained on English captions); UI strings stay Dutch in Swift.
MOOD_LABELS = ["danceable", "aggressive", "happy", "party", "relaxed", "sad"]


def _lazy_imports():
    import numpy as np
    import torch
    from transformers import ClapModel, ClapProcessor

    return np, torch, ClapModel, ClapProcessor


# PyTorch bicubic uses Keys' cubic convolution with A = -0.75.
_BICUBIC_A = -0.75


def _bicubic_resample_matrix(in_size: int, out_size: int, align_corners: bool):
    """A fixed (out_size x in_size) float32 matrix W such that `W @ v` resamples a
    length-`in_size` signal to `out_size` with the SAME bicubic interpolation
    PyTorch's `aten::upsample_bicubic2d` applies (cubic convolution, A=-0.75,
    border-replicated 4-tap support). Because the analyzer's input shape and the
    HTSAT target size are both fixed at trace time, the whole resize is this one
    constant linear map — so we get exact bicubic (not a bilinear approximation)
    as a single matmul, with no MIL bicubic op needed.
    """
    import numpy as np

    if out_size == in_size:
        return np.eye(in_size, dtype=np.float32)

    A = _BICUBIC_A

    def cubic1(x):  # |x| <= 1
        return ((A + 2.0) * x - (A + 3.0)) * x * x + 1.0

    def cubic2(x):  # 1 < |x| < 2
        return ((A * x - 5.0 * A) * x + 8.0 * A) * x - 4.0 * A

    # Source coordinate per PyTorch `area_pixel_compute_source_index` (cubic=True:
    # negative source indices are kept, not clamped to 0).
    if align_corners:
        scale = (in_size - 1) / (out_size - 1) if out_size > 1 else 0.0
    else:
        scale = in_size / out_size

    W = np.zeros((out_size, in_size), dtype=np.float64)
    for i in range(out_size):
        src = scale * i if align_corners else scale * (i + 0.5) - 0.5
        x0 = int(np.floor(src))
        t = src - x0
        # Coefficients for the 4 taps at offsets [-1, 0, 1, 2] (sum to 1).
        coeffs = (cubic2(t + 1.0), cubic1(t), cubic1(1.0 - t), cubic2(2.0 - t))
        for off, w in zip((-1, 0, 1, 2), coeffs):
            idx = min(max(x0 + off, 0), in_size - 1)   # replicate border
            W[i, idx] += w
    return W.astype(np.float32)


def _register_custom_ops():
    """CLAP/HTSAT resizes the mel to a square image with bicubic interpolation,
    an op Core ML's torch frontend does not implement. Input shapes (and thus the
    target size) are fixed at trace time, so we implement EXACT bicubic as a baked
    constant matmul (`_bicubic_resample_matrix`) instead of the old bilinear
    approximation — this closes the PyTorch<->CoreML parity gap (see
    EMBEDDING_NOTES.md / `validate`). Each axis is resampled independently, so a
    one-axis interpolate (HTSAT resizes time and freq separately) is a single
    matmul; an unchanged axis is an identity matrix and is skipped.
    """
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs
    from coremltools.converters.mil.frontend.torch.torch_op_registry import (
        _TORCH_OPS_REGISTRY,
        register_torch_op,
    )

    if "upsample_bicubic2d" in _TORCH_OPS_REGISTRY.name_to_func_mapping:
        return

    @register_torch_op
    def upsample_bicubic2d(context, node):
        import numpy as np

        inputs = _get_inputs(context, node)
        x = inputs[0]
        out_size = [int(v) for v in inputs[1].val]
        align = False
        if len(inputs) > 2 and inputs[2] is not None and inputs[2].val is not None:
            align = bool(inputs[2].val)

        in_h, in_w = int(x.shape[-2]), int(x.shape[-1])
        out_h, out_w = out_size[0], out_size[1]

        y = x
        # Resize the height (time) axis: y = Wh @ x.
        if out_h != in_h:
            wh = _bicubic_resample_matrix(in_h, out_h, align)          # (out_h, in_h)
            y = mb.matmul(x=wh, y=y)
        # Resize the width (mel) axis: y = y @ Ww.
        if out_w != in_w:
            ww = np.ascontiguousarray(
                _bicubic_resample_matrix(in_w, out_w, align).T)        # (in_w, out_w)
            y = mb.matmul(x=y, y=ww)
        # Keep an EXACT target size (no scale factors) so the downstream HTSAT
        # reshape never sees an off-by-one; name the output as the node expects.
        y = mb.identity(x=y, name=node.name)
        context.add(y)


# ---------------------------------------------------------------------------
# Tracing wrappers — expose ONE clean forward() each for torch.jit.trace.
# ---------------------------------------------------------------------------
def _build_wrappers(model):
    import torch

    class AudioEncoder(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, input_features):
            # get_audio_features applies the audio projection -> joint space.
            return self.m.get_audio_features(input_features=input_features)

    class TextEncoder(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, input_ids, attention_mask):
            return self.m.get_text_features(
                input_ids=input_ids, attention_mask=attention_mask
            )

    return AudioEncoder(model).eval(), TextEncoder(model).eval()


def _dummy_audio_input(processor, np, torch):
    """Run the processor on silence to discover the real input_features shape."""
    sr = processor.feature_extractor.sampling_rate
    seconds = getattr(processor.feature_extractor, "max_length_s", 10)
    wav = np.zeros(int(sr * seconds), dtype=np.float32)
    feats = processor(audios=wav, sampling_rate=sr, return_tensors="pt")
    return feats["input_features"]


def _dummy_text_input(processor, max_len=64):
    feats = processor(
        text=["a calm piano piece"],
        return_tensors="pt",
        padding="max_length",
        max_length=max_len,
        truncation=True,
    )
    return feats["input_ids"], feats["attention_mask"]


def _save_f32(path: Path, arr, np):
    """Write a contiguous little-endian float32 blob (no header) for Swift."""
    np.ascontiguousarray(arr, dtype="<f4").tofile(str(path))


def _dump_mel_config(processor, out_dir: Path, np):
    """Persist everything Swift needs to reproduce the mel front-end exactly."""
    fe = processor.feature_extractor
    # NON-fusion CLAP (rand_trunc / repeatpad) uses the librosa-style *slaney*
    # filter bank, NOT `mel_filters` (that one is torchaudio, fusion-only).
    mel_filters = np.asarray(fe.mel_filters_slaney, dtype=np.float32)
    cfg = {
        "model": DEFAULT_MODEL,
        "projection_dim": int(getattr(processor, "projection_dim", 512) or 512),
        "sampling_rate": int(fe.sampling_rate),
        "n_fft": int(getattr(fe, "fft_window_size", getattr(fe, "n_fft", 1024))),
        "hop_length": int(getattr(fe, "hop_length", 480)),
        "n_mels": int(fe.feature_size),
        "max_length_s": int(getattr(fe, "max_length_s", 10)),
        "nb_max_frames": int(getattr(fe, "nb_max_frames", 0)),
        "nb_frequency_bins": int(getattr(fe, "nb_frequency_bins", 0)),
        "frequency_min": float(getattr(fe, "frequency_min", 0.0)),
        "frequency_max": float(getattr(fe, "frequency_max", fe.sampling_rate / 2)),
        "top_db": (None if getattr(fe, "top_db", None) is None else float(fe.top_db)),
        "padding": getattr(fe, "padding", "repeatpad"),
        "mel_filters_shape": list(mel_filters.shape),
        "mood_labels": MOOD_LABELS,
    }
    (out_dir / "clap_mel.json").write_text(json.dumps(cfg, indent=2))
    # The filter-bank matrix itself ([513, 64]) — both .npy (reference) and a
    # raw row-major float32 blob Swift loads directly (no .npy parser needed).
    np.save(out_dir / "clap_mel_filters.npy", mel_filters)
    _save_f32(out_dir / "clap_mel_filters.f32", mel_filters, np)
    return cfg


def cmd_convert(args):
    np, torch, ClapModel, ClapProcessor = _lazy_imports()
    import coremltools as ct

    _register_custom_ops()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[convert] loading {DEFAULT_MODEL} …", flush=True)
    model = ClapModel.from_pretrained(DEFAULT_MODEL).eval()
    processor = ClapProcessor.from_pretrained(DEFAULT_MODEL)

    cfg = _dump_mel_config(processor, out_dir, np)
    # Ship the RoBERTa BPE tokenizer files so the analyzer can tokenize text
    # queries natively for /text-embed (Step 8).
    processor.tokenizer.save_vocabulary(str(out_dir))
    print(f"[convert] mel config: {cfg['n_mels']} mels @ {cfg['sampling_rate']} Hz, "
          f"input_features + tokenizer dump written", flush=True)

    audio_enc, text_enc = _build_wrappers(model)

    # ---- audio encoder ----------------------------------------------------
    audio_in = _dummy_audio_input(processor, np, torch)
    print(f"[convert] audio input_features shape = {tuple(audio_in.shape)}", flush=True)
    with torch.no_grad():
        ts_audio = torch.jit.trace(audio_enc, (audio_in,), strict=False)
    ml_audio = ct.convert(
        ts_audio,
        inputs=[ct.TensorType(name="input_features", shape=audio_in.shape)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml_audio.save(str(out_dir / "CLAPAudio.mlpackage"))
    print("[convert] saved CLAPAudio.mlpackage", flush=True)

    # ---- text encoder -----------------------------------------------------
    ids, mask = _dummy_text_input(processor, max_len=args.text_len)
    with torch.no_grad():
        ts_text = torch.jit.trace(text_enc, (ids, mask), strict=False)
    ml_text = ct.convert(
        ts_text,
        inputs=[
            ct.TensorType(name="input_ids", shape=ids.shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=mask.shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml_text.save(str(out_dir / "CLAPText.mlpackage"))
    print("[convert] saved CLAPText.mlpackage", flush=True)

    # ---- precompute mood label embeddings via the CORE ML text encoder ------
    # Use Core ML (not PyTorch) so mood labels live in the same approximated
    # space as the Core ML audio embeddings (the bilinear-resize shift only
    # affects the audio side; see EMBEDDING_NOTES.md). No Swift tokenizer needed.
    ct_text = ct.models.MLModel(str(out_dir / "CLAPText.mlpackage"))
    mood_embeds = np.zeros((len(MOOD_LABELS), cfg["projection_dim"]), dtype=np.float32)
    for i, label in enumerate(MOOD_LABELS):
        feats = processor(
            text=[label], return_tensors="np",
            padding="max_length", max_length=args.text_len, truncation=True,
        )
        out = ct_text.predict({
            "input_ids": feats["input_ids"].astype(np.int32),
            "attention_mask": feats["attention_mask"].astype(np.int32),
        })
        e = np.asarray(out["embedding"]).reshape(-1)
        mood_embeds[i] = e / (np.linalg.norm(e) + 1e-9)
    np.save(out_dir / "clap_mood_embeds.npy", mood_embeds)
    _save_f32(out_dir / "clap_mood_embeds.f32", mood_embeds, np)
    print(f"[convert] saved {len(MOOD_LABELS)} mood label embeddings (Core ML)", flush=True)
    print("[convert] DONE", flush=True)


def _embed_pytorch(model, processor, np, torch, paths):
    import librosa

    sr = processor.feature_extractor.sampling_rate
    embeds = []
    for p in paths:
        wav, _ = librosa.load(p, sr=sr, mono=True)
        feats = processor(audios=wav, sampling_rate=sr, return_tensors="pt")
        with torch.no_grad():
            e = model.get_audio_features(input_features=feats["input_features"])
            e = torch.nn.functional.normalize(e, dim=-1)
        embeds.append((feats["input_features"], e.cpu().numpy()[0]))
    return embeds


def _cosine_matrix(np, vecs):
    m = np.stack([v / (np.linalg.norm(v) + 1e-9) for v in vecs])
    return m @ m.T


def cmd_validate(args):
    np, torch, ClapModel, ClapProcessor = _lazy_imports()
    import coremltools as ct

    out_dir = Path(args.out)
    paths = []
    for pat in args.tracks:
        paths.extend(sorted(glob.glob(pat)))
    paths = paths[: args.n]
    if len(paths) < 2:
        sys.exit(f"need >=2 audio files, got {len(paths)}")

    print(f"[validate] {len(paths)} tracks:")
    for p in paths:
        print("   ", Path(p).name)

    model = ClapModel.from_pretrained(DEFAULT_MODEL).eval()
    processor = ClapProcessor.from_pretrained(DEFAULT_MODEL)

    pt = _embed_pytorch(model, processor, np, torch, paths)
    pt_vecs = [v for _, v in pt]

    ml_audio = ct.models.MLModel(str(out_dir / "CLAPAudio.mlpackage"))
    cm_vecs = []
    for feats, _ in pt:
        out = ml_audio.predict({"input_features": feats.numpy().astype(np.float32)})
        e = np.asarray(out["embedding"]).reshape(-1)
        cm_vecs.append(e / (np.linalg.norm(e) + 1e-9))

    parity = [float(np.dot(a / (np.linalg.norm(a) + 1e-9), b))
              for a, b in zip(pt_vecs, cm_vecs)]

    np.set_printoptions(precision=3, suppress=True)
    print("\n[validate] PyTorch cosine matrix:")
    print(_cosine_matrix(np, pt_vecs))
    print("\n[validate] Core ML cosine matrix:")
    print(_cosine_matrix(np, cm_vecs))
    print("\n[validate] per-track PyTorch<->CoreML parity (want >0.99):")
    for p, c in zip(paths, parity):
        print(f"   {c:.4f}  {Path(p).name}")
    worst = min(parity)
    print(f"\n[validate] worst parity = {worst:.4f} "
          f"({'PASS' if worst > 0.99 else 'CHECK'})")


# Deterministic synthetic waveform — Swift regenerates this EXACTLY (same
# closed form) so the golden test needs no audio file and no large input blob.
GOLDEN_SINES = [(110.0, 0.5), (440.0, 0.25), (1760.0, 0.15), (6000.0, 0.1)]


def _golden_waveform(np, sr=48000, n=480000):
    t = np.arange(n, dtype=np.float64) / sr
    wav = np.zeros(n, dtype=np.float64)
    for freq, amp in GOLDEN_SINES:
        wav += amp * np.sin(2.0 * np.pi * freq * t)
    return wav.astype(np.float32)


def cmd_golden(args):
    np, torch, ClapModel, ClapProcessor = _lazy_imports()
    import coremltools as ct

    out_dir = Path(args.out)
    processor = ClapProcessor.from_pretrained(DEFAULT_MODEL)

    # Golden tokenization for the Swift RoBERTa-BPE tokenizer test (Step 8).
    golden_text = "a dreamy ambient piano piece"
    tk = processor(text=[golden_text], return_tensors="np",
                   padding="max_length", max_length=64, truncation=True)
    text_golden = {
        "phrase": golden_text,
        "max_length": 64,
        "ids": [int(x) for x in tk["input_ids"][0].tolist()],
        "mask": [int(x) for x in tk["attention_mask"][0].tolist()],
    }

    wav = _golden_waveform(np)

    feats = processor(audios=wav, sampling_rate=48000, return_tensors="np")
    mel = np.asarray(feats["input_features"], dtype=np.float32)  # (1,1,1001,64)
    mel2d = mel.reshape(mel.shape[-2], mel.shape[-1])            # (1001,64)

    ml_audio = ct.models.MLModel(str(out_dir / "CLAPAudio.mlpackage"))
    out = ml_audio.predict({"input_features": mel.astype(np.float32)})
    emb = np.asarray(out["embedding"]).reshape(-1)
    emb = emb / (np.linalg.norm(emb) + 1e-9)

    _save_f32(out_dir / "golden_mel.f32", mel2d, np)
    _save_f32(out_dir / "golden_embedding.f32", emb, np)
    meta = {
        "sample_rate": 48000,
        "n_samples": int(wav.shape[0]),
        "sines": [{"freq": f, "amp": a} for f, a in GOLDEN_SINES],
        "mel_shape": list(mel2d.shape),
        "mel_mean": float(mel2d.mean()),
        "mel_std": float(mel2d.std()),
        "mel_first_frame": mel2d[0].tolist(),
        "embedding_dim": int(emb.shape[0]),
        "text": text_golden,
    }
    (out_dir / "golden.json").write_text(json.dumps(meta, indent=2))
    print(f"[golden] mel {mel2d.shape} mean={meta['mel_mean']:.4f} "
          f"std={meta['mel_std']:.4f}; embedding dim={emb.shape[0]} saved", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("convert", help="convert CLAP encoders to Core ML")
    c.add_argument("--out", required=True, help="output dir for .mlpackage + config")
    c.add_argument("--text-len", type=int, default=64, help="fixed text token length")
    c.set_defaults(func=cmd_convert)

    v = sub.add_parser("validate", help="PyTorch<->CoreML parity + cosine matrix")
    v.add_argument("--out", required=True, help="dir containing the .mlpackage files")
    v.add_argument("--n", type=int, default=5, help="number of tracks to embed")
    v.add_argument("tracks", nargs="+", help="audio file paths or globs")
    v.set_defaults(func=cmd_validate)

    g = sub.add_parser("golden", help="dump deterministic golden vectors for Swift tests")
    g.add_argument("--out", required=True, help="dir containing the .mlpackage files")
    g.set_defaults(func=cmd_golden)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
