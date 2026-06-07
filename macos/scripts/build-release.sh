#!/usr/bin/env bash
# Build a signed, notarized RoonSage.app + DMG.
#
# Usage (local):
#   cd macos
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   APPLE_ID="you@example.com" \
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#   APPLE_TEAM_ID="ABCDE12345" \
#   ./scripts/build-release.sh [version]
#
# In GitHub Actions the env vars are injected from secrets; the workflow
# also handles certificate import before calling this script.
set -euo pipefail

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}"
VERSION="${VERSION#v}"   # strip leading 'v'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGE_DIR="$MACOS_DIR/RoonSage"
ENTITLEMENTS="$MACOS_DIR/Entitlements.plist"
OUTPUT_DIR="$MACOS_DIR/build"

APP_NAME="RoonSage"
BUNDLE_ID="com.roonsage.native"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}.dmg"

echo "▶ Building $APP_NAME $VERSION"
echo ""

# ── 1. Build release binary ───────────────────────────────────────────────────
echo "── Step 1: swift build -c release"
(cd "$PACKAGE_DIR" && swift build -c release --product RoonSage 2>&1)
BINARY="$PACKAGE_DIR/.build/release/RoonSage"

# ── 2. Assemble .app bundle ───────────────────────────────────────────────────
echo "── Step 2: assemble .app bundle"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_NAME"

# Patch version into Info.plist
sed \
  -e "s|<string>2.0.0</string>|<string>$VERSION</string>|g" \
  "$PACKAGE_DIR/Sources/RoonSage/Info.plist" \
  > "$APP_PATH/Contents/Info.plist"

# App icon (optional — add RoonSage.icns to macos/assets/ to include it)
ICON="$MACOS_DIR/assets/RoonSage.icns"
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

# ── 3. Code sign ─────────────────────────────────────────────────────────────
echo "── Step 3: codesign"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "   SIGN_IDENTITY not set — using ad-hoc signing (local testing only)"
    codesign --deep --force --verbose --sign - "$APP_PATH"
else
    codesign --deep --force --verbose \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$APP_PATH"
fi

# ── 4. Notarize (skipped for ad-hoc) ─────────────────────────────────────────
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo "── Step 4: notarize"
    ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait \
        --timeout 30m

    rm "$ZIP_PATH"
    xcrun stapler staple "$APP_PATH"
    echo "   ✓ Notarized and stapled"
else
    echo "── Step 4: skipping notarization (APPLE_ID/APPLE_APP_PASSWORD/APPLE_TEAM_ID not set)"
fi

# ── 5. Create DMG ─────────────────────────────────────────────────────────────
echo "── Step 5: create DMG"
STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

rm -rf "$STAGING"

# Sign the DMG itself (required for notarization of the DMG)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo ""
echo "✓ Done: $DMG_PATH"
ls -lh "$DMG_PATH"
