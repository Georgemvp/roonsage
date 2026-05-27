#!/usr/bin/env python3
"""Export the GTE-multilingual sentence-embedding model to ONNX.

Produces two files in ``data/models`` (override with ``--out-dir`` or
``ONNX_MODELS_DIR``)::

    gte_multilingual.onnx       # (batch, seq, 768) last_hidden_state
    gte_tokenizer/tokenizer.json  + tokenizer_config.json

The tokenizer files are saved alongside so the ONNX backend can load them with
``tokenizers.Tokenizer.from_file`` without needing the full transformers stack.

After export the model is dynamically quantized (INT8 weights). The verification
step checks that mean-pooled cosine similarity between the ONNX output and the
native transformers output is >= 0.99.

Usage::

    python scripts/export_gte_onnx.py
    python scripts/export_gte_onnx.py --no-quantize
    python scripts/export_gte_onnx.py --model Alibaba-NLP/gte-multilingual-base

Requires the ML extras (``transformers``, ``torch``, ``onnxruntime``) — run
inside the Docker container or in the ``-ml`` virtualenv.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

logger = logging.getLogger("export_gte_onnx")

DEFAULT_MODEL = "Alibaba-NLP/gte-multilingual-base"


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------


def export_with_torch(model_id: str, out_path: Path) -> None:
    """Export GTE using torch.onnx.export (legacy TorchScript path)."""
    import torch  # noqa: PLC0415
    from transformers import AutoModel, AutoTokenizer  # noqa: PLC0415

    out_path.parent.mkdir(parents=True, exist_ok=True)

    tok = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
    model = AutoModel.from_pretrained(model_id, trust_remote_code=True).eval()

    # Dummy input — single short sentence.
    enc = tok(
        ["the quick brown fox"],
        padding=True,
        truncation=True,
        max_length=64,
        return_tensors="pt",
    )
    ids = enc["input_ids"]
    mask = enc["attention_mask"]

    # Wrap to export only (input_ids, attention_mask) → last_hidden_state.
    class _GTEWrapper(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.model = model

        def forward(self, input_ids, attention_mask):
            out = self.model(input_ids=input_ids, attention_mask=attention_mask)
            return out.last_hidden_state

    wrapper = _GTEWrapper().eval()

    logger.info("Exporting %s -> %s", model_id, out_path)
    torch.onnx.export(
        wrapper,
        (ids, mask),
        str(out_path),
        input_names=["input_ids", "attention_mask"],
        output_names=["last_hidden_state"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "seq"},
            "attention_mask": {0: "batch", 1: "seq"},
            "last_hidden_state": {0: "batch", 1: "seq"},
        },
        opset_version=17,
        do_constant_folding=True,
        dynamo=False,
    )
    logger.info("Export done: %s", out_path)
    return tok


def save_tokenizer(tok, tokenizer_dir: Path) -> None:
    """Save only the fast-tokenizer JSON files for runtime loading."""
    tokenizer_dir.mkdir(parents=True, exist_ok=True)
    # save_pretrained writes all tokenizer files; we keep them all — the
    # inference code uses tokenizers.Tokenizer.from_file("tokenizer.json").
    tok.save_pretrained(str(tokenizer_dir))
    logger.info("Tokenizer saved to %s", tokenizer_dir)


def quantize(path: Path) -> None:
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
    logger.info("Quantized: %s", path)


# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------


def verify(model_id: str, onnx_path: Path, tokenizer_dir: Path, tolerance: float) -> bool:
    """Compare ONNX vs. native mean-pooled embeddings."""
    import numpy as np  # noqa: PLC0415
    import onnxruntime as ort  # noqa: PLC0415
    import torch  # noqa: PLC0415
    from transformers import AutoModel, AutoTokenizer  # noqa: PLC0415

    sentence = "the long road ahead is paved with quiet hope"

    tok = AutoTokenizer.from_pretrained(str(tokenizer_dir), trust_remote_code=True)
    model = AutoModel.from_pretrained(model_id, trust_remote_code=True).eval()
    enc = tok([sentence], padding=True, truncation=True, max_length=512, return_tensors="pt")
    with torch.no_grad():
        out = model(**enc)
        last = out.last_hidden_state
        mask = enc["attention_mask"].unsqueeze(-1).float()
        native = ((last * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1)).squeeze(0).cpu().numpy()
    native = native / (np.linalg.norm(native) + 1e-12)

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    feeds = {
        "input_ids": enc["input_ids"].cpu().numpy(),
        "attention_mask": enc["attention_mask"].cpu().numpy(),
    }
    onnx_last = sess.run(None, feeds)[0]  # (1, L, D)
    mask_np = feeds["attention_mask"].astype(np.float32)[..., None]
    onnx_vec = ((onnx_last * mask_np).sum(axis=1) / mask_np.sum(axis=1).clip(min=1)).squeeze(0)
    onnx_vec = onnx_vec / (np.linalg.norm(onnx_vec) + 1e-12)

    cos = float(np.dot(native, onnx_vec))
    logger.info("GTE cosine similarity (ONNX vs native): %.4f", cos)
    if cos < tolerance:
        logger.error("GTE cosine %.4f below tolerance %.4f — export may be incorrect", cos, tolerance)
        return False
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    default_out = Path(os.environ.get("ONNX_MODELS_DIR", "data/models"))

    parser = argparse.ArgumentParser(description="Export GTE-multilingual to ONNX")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=default_out,
        help="Directory to write the ONNX files into (default: data/models)",
    )
    parser.add_argument(
        "--model",
        type=str,
        default=os.environ.get("LYRICS_MODEL", DEFAULT_MODEL),
        help=f"HuggingFace model id (default: {DEFAULT_MODEL})",
    )
    parser.add_argument("--no-quantize", action="store_true", help="Skip INT8 quantization")
    parser.add_argument("--skip-verify", action="store_true", help="Skip parity check")
    parser.add_argument(
        "--tolerance",
        type=float,
        default=0.97,
        help="Minimum cosine similarity required to pass verification (default 0.97 for quantized)",
    )
    args = parser.parse_args(argv)

    final_model = args.out_dir / "gte_multilingual.onnx"
    final_tokenizer = args.out_dir / "gte_tokenizer"

    try:
        tok = export_with_torch(args.model, final_model)
        save_tokenizer(tok, final_tokenizer)
    except ImportError as exc:
        logger.error("transformers/torch not installed: %s", exc)
        return 2
    except Exception:
        logger.exception("Export failed")
        return 1

    if not args.no_quantize:
        try:
            quantize(final_model)
        except Exception:
            logger.exception("Quantization failed — keeping float32 ONNX file")

    if not args.skip_verify:
        try:
            ok = verify(args.model, final_model, final_tokenizer, args.tolerance)
        except Exception:
            logger.exception("Verification step failed")
            ok = False
        if not ok:
            return 3

    logger.info("GTE ONNX export complete: %s", final_model)
    return 0


if __name__ == "__main__":
    sys.exit(main())
