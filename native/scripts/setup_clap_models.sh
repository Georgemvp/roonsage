#!/usr/bin/env bash
# Build-time fetch of the CLAP Core ML resources for the analyzer host.
#
# Downloads the base CLAP model from Hugging Face and converts it to the two
# .mlpackage encoders + mel/tokenizer/mood resources, installing them where
# CLAPModel.resourceDir() looks by default:
#   ~/Library/Application Support/RoonSageAnalyzer/CLAP
#
# Idempotent: skips when the resources already exist. Override the target with
# the first argument or $ROONSAGE_CLAP_DIR. Requires python3 (a venv is created
# under native/.venv on first run). Run once per analyzer host / release.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # native/
DEFAULT_DIR="${HOME}/Library/Application Support/RoonSageAnalyzer/CLAP"
OUT="${1:-${ROONSAGE_CLAP_DIR:-$DEFAULT_DIR}}"

if [ -f "$OUT/clap_mel.json" ] && [ -d "$OUT/CLAPAudio.mlpackage" ]; then
  echo "[setup-clap] resources already present at: $OUT"
  exit 0
fi

VENV="$HERE/.venv"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
  echo "[setup-clap] creating venv at $VENV"
  python3 -m venv "$VENV"
fi

echo "[setup-clap] installing pinned ML deps (one-time, ~2-3 GB)…"
"$PY" -m pip install --quiet --upgrade pip
"$PY" -m pip install --quiet \
  "numpy==1.26.4" "torch==2.4.1" "transformers==4.44.2" \
  "coremltools==8.1" "soundfile==0.12.1" "librosa==0.10.2"

mkdir -p "$OUT"
export HF_HOME="${HF_HOME:-$VENV/hf_cache}"
echo "[setup-clap] converting CLAP → Core ML into: $OUT"
"$PY" "$HERE/scripts/convert_clap_to_coreml.py" convert --out "$OUT"
"$PY" "$HERE/scripts/convert_clap_to_coreml.py" golden  --out "$OUT"
echo "[setup-clap] done. roonsage-analyzer will load embeddings from $OUT"
