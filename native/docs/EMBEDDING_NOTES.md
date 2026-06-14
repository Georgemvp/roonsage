# Embedding spike — CLAP → Core ML (Track E, Step 0)

Status: **spike PASSED, with one caveat.** CLAP converts and runs natively on
Apple Silicon; embeddings discriminate musically; PyTorch↔Core ML parity is
0.93–0.99 (below the 0.99 target) due to a bicubic→bilinear approximation. We do
**not** fall back to OpenL3.

## Decision

- Model: `laion/larger_clap_music_and_speech` (matches the legacy `CLAP_MODEL`
  default). 512-dim shared audio/text embedding space.
- Two Core ML packages produced by `native/scripts/convert_clap_to_coreml.py`:
  - `CLAPAudio.mlpackage` — `input_features` (log-mel) → 512-dim embedding
  - `CLAPText.mlpackage` — `input_ids` + `attention_mask` → 512-dim embedding
- Build-time only. No Python at runtime. Outputs land in
  `RoonSage/Sources/AudioAnalysis/Resources/CLAP/` (git-ignored — see "Shipping").

## Conversion hurdles solved

HTSAT (CLAP's audio backbone) uses `upsample_bicubic2d` to resize the mel into a
square "image". Core ML's torch frontend does not implement that op. Fix: a
custom `@register_torch_op` that maps it to `mb.resize_bilinear` with an **exact
target size** (scale-factor resizing rounded 1024→1023 and broke the downstream
HTSAT reshape). The bilinear approximation is the source of the parity gap below.

## Mel front-end config (Step 1 MUST reproduce this in Swift)

From `clap_mel.json` (PyTorch `ClapFeatureExtractor`):

| param        | value |
|--------------|-------|
| sample rate  | 48000 |
| n_fft        | 1024  |
| hop_length   | 480   |
| n_mels       | 64    |
| clip length  | 10 s → 1001 frames (`input_features` = `(1, 1, 1001, 64)`) |
| freq min/max | 50 / 14000 Hz |
| padding      | `repeatpad` (repeat-then-pad short clips to 10 s) |
| top_db       | null  |

The exact mel filter-bank matrix (`[513, 64]`) is dumped to
`clap_mel_filters.npy` — Swift should embed/port these coefficients rather than
recomputing a filter-bank, so the Swift mel matches PyTorch bit-for-bit and the
only remaining gap is the bilinear-vs-bicubic resize.

## Spike results (5 diverse tracks)

Discrimination is real — diagonal 1.0, off-diagonals 0.05–0.57, and the **track
rankings are identical** between PyTorch and Core ML (e.g. Linkin Park's nearest
neighbour is Erik Truffaz in both). Rankings are what k-NN retrieval depends on.

Per-track PyTorch↔Core ML parity: 0.94 / 0.99 / 0.93 / 0.96 / 0.93 (worst 0.93).

## Caveats & follow-ups for Step 1+

1. **Parity 0.93 is fine for retrieval** (Similar / Map / Path / Alchemy are all
   Core-ML-internal — the whole library is embedded by the *same* model, so the
   bilinear shift is common-mode and cancels in cosine ranking).
2. **Mood scoring crosses encoders** (audio embed vs text-label embed). Generate
   the mood-label embeddings with the **Core ML text encoder** (`CLAPText`), not
   the PyTorch `clap_mood_embeds.npy`, so both sides share the same space. The
   PyTorch `clap_mood_embeds.npy` is kept only as a reference.
3. If mood accuracy proves off, revisit the bicubic approximation (true bicubic
   has no MIL op; option: pre-resize the mel front-end to the target frame count
   so the in-model interpolation is a near-identity).

## Shipping the model (OPEN QUESTION — decide before merge)

The `.mlpackage` files are large model weights. They are currently git-ignored.
Options: Git LFS, a build-time download script, or commit (not recommended).
Resolve before wiring SPM resources in Step 1/4.

## Reproduce

```bash
cd native
python3 -m venv .venv
./.venv/bin/python -m pip install numpy==1.26.4 torch==2.4.1 \
    transformers==4.44.2 coremltools==8.1 soundfile==0.12.1 librosa==0.10.2
export HF_HOME="$(pwd)/.venv/hf_cache"
OUT="RoonSage/Sources/AudioAnalysis/Resources/CLAP"
./.venv/bin/python scripts/convert_clap_to_coreml.py convert --out "$OUT"
./.venv/bin/python scripts/convert_clap_to_coreml.py validate --out "$OUT" \
    "/path/to/five/*.flac"
```
