#!/usr/bin/env bash
# Assemble a runnable StackPulse.app bundle from the built Swift binary.
#
# This produces an ad-hoc-signed bundle suitable for LOCAL use. Real
# distribution (Developer ID signing, hardened runtime, notarization, signed
# DMG, Sparkle feed) is a documented Phase-6 pipeline — see docs/DISTRIBUTION
# notes / CHANGELOG. Do not ship this bundle to users as-is.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="StackPulse"
BIN_NAME="StackPulseApp"
BUILD_DIR="$ROOT/apps/StackPulseMac/.build/release"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
PLIST_SRC="$ROOT/apps/StackPulseMac/Resources/Info.plist"

if [ ! -x "$BUILD_DIR/$BIN_NAME" ]; then
  echo "!! $BIN_NAME not built. Run scripts/build-app.sh first." >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (Dock / Finder). Referenced by CFBundleIconFile=AppIcon in Info.plist.
ICON_SRC="$ROOT/apps/StackPulseMac/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc codesign (hardened runtime)"
codesign --force --sign - --options runtime --timestamp=none "$APP" >/dev/null 2>&1 || \
  codesign --force --sign - "$APP"

echo "==> verify"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true
echo "==> built: $APP"
echo "    run with: open \"$APP\"   (or) \"$APP/Contents/MacOS/$BIN_NAME\" --dump"
