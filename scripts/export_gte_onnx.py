#!/usr/bin/env python3
"""Export the GTE-multilingual sentence-embedding model to ONNX.

Produces ``data/models/gte_multilingual.onnx`` (override with ``--out-dir``)
plus the matching tokenizer files (``tokenizer.json`` + ``tokenizer_config.json``)
in ``data/models/gte_tokenizer/``.

The model is exported with HuggingFace ``optimum`` because GTE-multilingual ships
with ``trust_remote_code`` modeling code that doesn't trace cleanly via plain
``torch.onnx.export``.

After export the model is dynamically quantized (INT8 weights) — typical
shrinkage is ~4×.

Usage::

    python scripts/export_gte_onnx.py
    python scripts/export_gte_onnx.py --no-quantize
    python scripts/export_gte_onnx.py --model Alibaba-NLP/gte-multilingual-base

Requires the heavy ML extras (``transformers``, ``optimum``, ``onnx``,
``onnxruntime``) — run inside the Docker container or in the ``-ml`` virtualenv.
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import sys
from pathlib import Path

logger = logging.getLogger("export_gte_onnx")

DEFAULT_MODEL = "Alibaba-NLP/gte-multilingual-base"


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------


def export_with_optimum(model_id: str, out_dir: Path) -> Path:
    """Export via ``optimum.exporters.onnx.main_export``.

    Returns the path to the produced ``model.onnx``.
    """
    from optimum.exporters.onnx import main_export  # noqa: PLC0415

    out_dir.mkdir(parents=True, exist_ok=True)
    logger.info("Exporting %s -> %s", model_id, out_dir)
    main_export(
        model_name_or_path=model_id,
        output=str(out_dir),
        task="feature-extraction",
        trust_remote_code=True,
        opset=17,
    )
    produced = out_dir / "model.onnx"
    if not produced.exists():
        raise FileNotFoundError(f"optimum did not produce {produced}")
    return produced


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


# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------


def verify(model_id: str, onnx_path: Path, tokenizer_dir: Path, tolerance: float) -> bool:
    """Compare ONNX vs. transformers embeddings on a fixed sentence.

    Mean-pools the token embeddings (masked by attention) to match
    ``backend.lyrics.embedder.embed_text``.
    """
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
    # The exported model may also accept token_type_ids — add it if so.
    expected = {i.name for i in sess.get_inputs()}
    if "token_type_ids" in expected:
        feeds["token_type_ids"] = enc.get(
            "token_type_ids",
            torch.zeros_like(enc["input_ids"]),
        ).cpu().numpy()

    onnx_out = sess.run(None, feeds)[0]  # (B, L, D)
    mask_np = feeds["attention_mask"].astype(np.float32)[..., None]
    onnx_vec = (onnx_out * mask_np).sum(axis=1) / mask_np.sum(axis=1).clip(min=1)
    onnx_vec = onnx_vec.squeeze(0)
    onnx_vec = onnx_vec / (np.linalg.norm(onnx_vec) + 1e-12)

    cos = float(np.dot(native, onnx_vec))
    logger.info("GTE cosine similarity (ONNX vs native): %.4f", cos)
    if cos < tolerance:
        logger.error("GTE cosine %.4f below tolerance %.4f", cos, tolerance)
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
        default=0.99,
        help="Minimum cosine similarity required to pass verification",
    )
    args = parser.parse_args(argv)

    # optimum writes a directory; we move the artifacts into a canonical layout.
    optimum_dir = args.out_dir / "_gte_export_tmp"
    final_model = args.out_dir / "gte_multilingual.onnx"
    final_tokenizer = args.out_dir / "gte_tokenizer"

    try:
        produced = export_with_optimum(args.model, optimum_dir)
    except ImportError as exc:
        logger.error("optimum/transformers not installed: %s", exc)
        return 2
    except Exception:
        logger.exception("optimum export failed")
        return 1

    # Move/rename the model file and tokenizer assets into the canonical names.
    final_model.parent.mkdir(parents=True, exist_ok=True)
    if final_model.exists():
        final_model.unlink()
    shutil.move(str(produced), str(final_model))

    if final_tokenizer.exists():
        shutil.rmtree(final_tokenizer)
    final_tokenizer.mkdir(parents=True, exist_ok=True)
    for fname in optimum_dir.iterdir():
        # Keep tokenizer + config files; discard the leftover ONNX metadata
        # (model.onnx_data etc.) which is no longer referenced once we moved
        # the .onnx file.
        if fname.suffix in {".json", ".txt", ".model"} or fname.name in {"vocab.txt", "sentencepiece.bpe.model"}:
            shutil.copy(str(fname), str(final_tokenizer / fname.name))

    # Remove the temp export directory once we've extracted what we need.
    shutil.rmtree(optimum_dir, ignore_errors=True)

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
