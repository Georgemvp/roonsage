#!/usr/bin/env bash
# Build a macOS .icns from a 1024px PNG via iconutil.
#   ./make-icns.sh <source-1024.png> <Output.icns>
# Regenerate the PNGs first with the Swift generators:
#   swift make-icon.swift           # main app  -> icon-1024.png
#   swift make-analyzer-icon.swift  # analyzer  -> analyzer-icon-1024.png
set -euo pipefail

SRC="${1:?usage: make-icns.sh <source-1024.png> <Output.icns>}"
OUT="${2:?usage: make-icns.sh <source-1024.png> <Output.icns>}"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size"           "$SRC" --out "$ICONSET/icon_${size}x${size}.png"     >/dev/null
  sips -z $((size*2)) $((size*2))   "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png"  >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$(dirname "$ICONSET")"
echo "✓ wrote $OUT"
