#!/usr/bin/env bash
# Build "RoonSage Analyzer.app" + DMG (ad-hoc signed unless SIGN_IDENTITY set).
#   cd native && ./scripts/build-analyzer-release.sh [version]
set -euo pipefail

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
VERSION="${VERSION#analyzer-v}"
VERSION="${VERSION#v}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGE_DIR="$MACOS_DIR/RoonSage"
OUTPUT_DIR="$MACOS_DIR/build"
mkdir -p "$OUTPUT_DIR"

APP_NAME="RoonSage Analyzer"
EXEC_NAME="RoonSageAnalyzerApp"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/RoonSage-Analyzer-${VERSION}.dmg"
ENTITLEMENTS="$MACOS_DIR/AnalyzerEntitlements.plist"

echo "▶ Building $APP_NAME $VERSION"

echo "── Step 1: swift build -c release"
(cd "$PACKAGE_DIR" && swift build -c release --product "$EXEC_NAME")
BINARY="$PACKAGE_DIR/.build/release/$EXEC_NAME"

echo "── Step 2: assemble .app bundle"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$EXEC_NAME"
# Stamp the version into both keys by name (robust: works whatever the
# template currently holds — a magic-placeholder sed silently stamps nothing
# once the template drifts, which is how it stuck at 1.0.6).
awk -v ver="$VERSION" '
  /<key>CFBundleShortVersionString<\/key>/ { print; getline; sub(/<string>[^<]*<\/string>/, "<string>" ver "</string>"); print; next }
  /<key>CFBundleVersion<\/key>/            { print; getline; sub(/<string>[^<]*<\/string>/, "<string>" ver "</string>"); print; next }
  { print }
' "$PACKAGE_DIR/Sources/RoonSageAnalyzerApp/Info.plist" \
  > "$APP_PATH/Contents/Info.plist"
ICON="$MACOS_DIR/assets/RoonSageAnalyzer.icns"
[[ -f "$ICON" ]] && cp "$ICON" "$APP_PATH/Contents/Resources/AppIcon.icns"

echo "── Step 3: codesign"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Ad-hoc: no entitlements (the shared keychain group needs a real identity;
  # KeychainStore falls back to a group-less query on unsigned builds).
  codesign --deep --force --sign - "$APP_PATH"
else
  codesign --deep --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_PATH"
fi

echo "── Step 4: create DMG"
STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH"
rm -rf "$STAGING"

echo "✓ Done: $DMG_PATH"
ls -lh "$DMG_PATH"
