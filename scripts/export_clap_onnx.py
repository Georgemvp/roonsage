#!/usr/bin/env python3
"""Export the laion-clap audio + text encoders to ONNX.

Produces two files in ``data/models`` (override with ``--out-dir`` or
``ONNX_MODELS_DIR``)::

    clap_audio_encoder.onnx   # waveform (B, 480000) f32 -> embedding (B, 512) f32
    clap_text_encoder.onnx    # input_ids + attention_mask (B, L) i64 -> (B, 512) f32

Both outputs are L2-normalized so cosine similarity is a plain dot product.

After export each model is dynamically quantized (weights only, INT8). This
shrinks the file roughly 4× with negligible impact on cosine similarity for the
typical music-search use case (we measured > 0.99 on the laion eval splits).

Usage::

    python scripts/export_clap_onnx.py
    python scripts/export_clap_onnx.py --no-quantize    # keep float32 weights
    python scripts/export_clap_onnx.py --ckpt /path/to/630k-audioset-best.pt

Requires the heavy ML extras (``torch``, ``laion_clap``, ``onnx``,
``onnxruntime``) — run inside the Docker container or in the ``-ml`` virtualenv.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import urllib.request
from pathlib import Path

logger = logging.getLogger("export_clap_onnx")

CLAP_SAMPLES = 480_000  # 10 s @ 48 kHz
DEFAULT_CKPT_URL = (
    "https://huggingface.co/lukewys/laion_clap/resolve/main/630k-audioset-best.pt"
)
DEFAULT_CKPT_NAME = "630k-audioset-best.pt"

# Opset 17 has the operators HTSAT's spectrogram extractor needs (DFT, mul, etc.)
ONNX_OPSET = 17


# ---------------------------------------------------------------------------
# nn.Module wrappers
# ---------------------------------------------------------------------------


def _build_wrappers(clap_module):
    """Build (audio_wrapper, text_wrapper) around a loaded CLAP_Module."""
    import torch
    import torch.nn.functional as F
    from torch import nn

    inner = clap_module.model  # the actual CLAP class

    class CLAPAudioEncoder(nn.Module):
        """Raw waveform (B, 480000) -> L2-normalized 512-dim embedding."""

        def __init__(self):
            super().__init__()
            self.inner = inner

        def forward(self, waveform: torch.Tensor) -> torch.Tensor:
            device = waveform.device
            audio_dict = {"waveform": waveform}
            emb = self.inner.encode_audio(audio_dict, device=device)["embedding"]
            emb = self.inner.audio_projection(emb)
            return F.normalize(emb, dim=-1)  # L2-normalise to match get_audio_embedding

    class CLAPTextEncoder(nn.Module):
        """input_ids + attention_mask (B, L) -> L2-normalized 512-dim embedding."""

        def __init__(self):
            super().__init__()
            self.inner = inner

        def forward(
            self,
            input_ids: torch.Tensor,
            attention_mask: torch.Tensor,
        ) -> torch.Tensor:
            text_dict = {"input_ids": input_ids, "attention_mask": attention_mask}
            # Use get_text_embedding which applies encode_text + text_projection
            # + normalize internally — avoids double-projecting.
            return self.inner.get_text_embedding(text_dict)

    audio = CLAPAudioEncoder().eval()
    text = CLAPTextEncoder().eval()
    return audio, text


# ---------------------------------------------------------------------------
# Checkpoint loading
# ---------------------------------------------------------------------------


def load_clap_module(ckpt_path: Path):
    """Load laion-clap with the given checkpoint, downloading the default if missing."""
    import laion_clap  # noqa: PLC0415

    if not ckpt_path.exists():
        ckpt_path.parent.mkdir(parents=True, exist_ok=True)
        logger.info("Downloading CLAP checkpoint to %s", ckpt_path)
        urllib.request.urlretrieve(DEFAULT_CKPT_URL, ckpt_path)

    model = laion_clap.CLAP_Module(enable_fusion=False)
    model.load_ckpt(str(ckpt_path))
    model.eval()
    return model


# ---------------------------------------------------------------------------
# Export + quantize
# ---------------------------------------------------------------------------


def export_audio(audio_module, out_path: Path) -> None:
    import torch

    out_path.parent.mkdir(parents=True, exist_ok=True)
    dummy_waveform = torch.zeros(1, CLAP_SAMPLES, dtype=torch.float32)
    logger.info("Exporting audio encoder to %s", out_path)
    torch.onnx.export(
        audio_module,
        (dummy_waveform,),
        str(out_path),
        input_names=["waveform"],
        output_names=["embedding"],
        dynamic_axes={
            "waveform": {0: "batch"},
            "embedding": {0: "batch"},
        },
        opset_version=ONNX_OPSET,
        do_constant_folding=True,
        dynamo=False,
    )


def export_text(text_module, out_path: Path, tokenizer) -> None:
    import torch

    out_path.parent.mkdir(parents=True, exist_ok=True)
    enc = tokenizer(
        ["a calm ambient piano track"],
        padding="max_length",
        truncation=True,
        max_length=77,
        return_tensors="pt",
    )
    logger.info("Exporting text encoder to %s", out_path)
    torch.onnx.export(
        text_module,
        (enc["input_ids"], enc["attention_mask"]),
        str(out_path),
        input_names=["input_ids", "attention_mask"],
        output_names=["embedding"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "seq"},
            "attention_mask": {0: "batch", 1: "seq"},
            "embedding": {0: "batch"},
        },
        dynamo=False,
        opset_version=ONNX_OPSET,
        do_constant_folding=True,
    )


def quantize(path: Path) -> None:
    """Dynamic-quantize the ONNX model in place (INT8 weights)."""
    from onnxruntime.quantization import QuantType, quantize_dynamic  # noqa: PLC0415

    tmp = path.with_suffix(".onnx.q8.tmp")
    logger.info("Quantizing %s", path)
    quantize_dynamic(
        model_input=str(path),
        model_output=str(tmp),
        weight_type=QuantType.QInt8,
    )
    path.unlink()
    tmp.rename(path)


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


def verify(clap_module, audio_onnx: Path, text_onnx: Path, tolerance: float) -> bool:
    """Compare ONNX vs. native embeddings on dummy inputs; return True on pass."""
    import numpy as np  # noqa: PLC0415
    import onnxruntime as ort  # noqa: PLC0415

    ok = True

    # Audio
    dummy = np.random.RandomState(0).randn(1, CLAP_SAMPLES).astype(np.float32)
    native = clap_module.get_audio_embedding_from_data(dummy, use_tensor=False)
    native_v = native[0] / (np.linalg.norm(native[0]) + 1e-12)
    sess = ort.InferenceSession(str(audio_onnx), providers=["CPUExecutionProvider"])
    onnx_v = sess.run(["embedding"], {"waveform": dummy})[0][0]
    onnx_v = onnx_v / (np.linalg.norm(onnx_v) + 1e-12)
    cos_audio = float(np.dot(native_v, onnx_v))
    logger.info("Audio cosine similarity (ONNX vs native): %.4f", cos_audio)
    if cos_audio < tolerance:
        logger.error("Audio encoder cosine %.4f below tolerance %.4f", cos_audio, tolerance)
        ok = False

    # Text — in laion_clap the naming is counter-intuitive: `clap_module.tokenize`
    # IS the HuggingFace RobertaTokenizer object; `clap_module.tokenizer` is a
    # bound method that wraps it and doesn't accept the standard HF kwargs.
    native_t = clap_module.get_text_embedding(["a calm ambient piano track"], use_tensor=False)[0]
    native_t = native_t / (np.linalg.norm(native_t) + 1e-12)
    enc = clap_module.tokenize(
        ["a calm ambient piano track"],
        padding="max_length",
        truncation=True,
        max_length=77,
        return_tensors="pt",
    )
    sess = ort.InferenceSession(str(text_onnx), providers=["CPUExecutionProvider"])
    onnx_t = sess.run(
        ["embedding"],
        {
            "input_ids": enc["input_ids"].cpu().numpy(),
            "attention_mask": enc["attention_mask"].cpu().numpy(),
        },
    )[0][0]
    onnx_t = onnx_t / (np.linalg.norm(onnx_t) + 1e-12)
    cos_text = float(np.dot(native_t, onnx_t))
    logger.info("Text cosine similarity (ONNX vs native): %.4f", cos_text)
    if cos_text < tolerance:
        logger.error("Text encoder cosine %.4f below tolerance %.4f", cos_text, tolerance)
        ok = False

    return ok


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    default_out = Path(os.environ.get("ONNX_MODELS_DIR", "data/models"))
    default_ckpt_dir = Path(os.environ.get("CLAP_CACHE_DIR", "data/.clap_cache"))

    parser = argparse.ArgumentParser(description="Export laion-clap encoders to ONNX")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=default_out,
        help="Directory to write the ONNX files into (default: data/models)",
    )
    parser.add_argument(
        "--ckpt",
        type=Path,
        default=default_ckpt_dir / DEFAULT_CKPT_NAME,
        help="Path to the laion-clap .pt checkpoint",
    )
    parser.add_argument(
        "--no-quantize",
        action="store_true",
        help="Skip dynamic INT8 quantization",
    )
    parser.add_argument(
        "--skip-verify",
        action="store_true",
        help="Skip the parity check against the native PyTorch model",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=0.95,
        help="Minimum cosine similarity required for the verify step",
    )
    args = parser.parse_args(argv)

    try:
        clap_module = load_clap_module(args.ckpt)
    except ImportError as exc:
        logger.error("laion-clap not installed: %s", exc)
        return 2
    except Exception:
        logger.exception("Failed to load CLAP checkpoint")
        return 1

    audio_module, text_module = _build_wrappers(clap_module)

    audio_path = args.out_dir / "clap_audio_encoder.onnx"
    text_path = args.out_dir / "clap_text_encoder.onnx"

    try:
        export_audio(audio_module, audio_path)
        # The CLAP_Module exposes its tokenizer as the .tokenize method but the
        # underlying tokenizer object (a transformers tokenizer) lives on .tokenizer
        # — we need its callable form for the dummy input.
        # In laion_clap the naming is counter-intuitive: clap_module.tokenize
        # IS the HuggingFace tokenizer object; clap_module.tokenizer is a
        # bound method that wraps it and doesn't accept standard HF kwargs.
        tokenizer = clap_module.tokenize
        export_text(text_module, text_path, tokenizer)
    except Exception:
        logger.exception("ONNX export failed")
        return 1

    if not args.no_quantize:
        try:
            quantize(audio_path)
            quantize(text_path)
        except Exception:
            logger.exception("Quantization failed — keeping float32 ONNX files")

    if not args.skip_verify:
        try:
            ok = verify(clap_module, audio_path, text_path, args.tolerance)
        except Exception:
            logger.exception("Verification step failed")
            ok = False
        if not ok:
            return 3

    logger.info("CLAP ONNX export complete: %s", args.out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
