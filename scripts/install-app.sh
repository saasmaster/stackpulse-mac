#!/usr/bin/env bash
# Replace the INSTALLED StackPulse.app with the freshly packaged one, then
# relaunch it.
#
# Why this exists: `build-app.sh` only produces the executable under
# `.build/release`, and `package-app.sh` only assembles `dist/StackPulse.app`.
# Neither touches the copy you actually double-click, so it is entirely possible
# to build, test, and verify a change while the running app stays on an old
# build — which is exactly what happened once. This is the one command that puts
# a change where it can actually be seen, and it verifies the version afterwards
# rather than assuming.
#
# Override the destination with INSTALL_DIR (default: ~/Desktop).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="StackPulse"
SRC="$ROOT/dist/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Desktop}"
DEST="$INSTALL_DIR/$APP_NAME.app"
PLIST_SRC="$ROOT/apps/StackPulseMac/Resources/Info.plist"

if [ ! -d "$SRC" ]; then
  echo "!! $SRC not found. Run scripts/package-app.sh first (or: make package)." >&2
  exit 1
fi

EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST_SRC")"

# Quit any running copy: macOS keeps the old executable mapped, so replacing the
# bundle under a live process leaves you staring at the previous build.
if pgrep -f "$APP_NAME.app/Contents/MacOS/StackPulseApp" >/dev/null 2>&1; then
  echo "==> quitting the running $APP_NAME"
  pkill -f "$APP_NAME.app/Contents/MacOS/StackPulseApp" || true
  sleep 2
fi

echo "==> installing to $DEST"
rm -rf "$DEST"
ditto "$SRC" "$DEST"

INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
if [ "$INSTALLED" != "$EXPECTED" ]; then
  echo "!! installed version $INSTALLED != source $EXPECTED — the bundle is stale." >&2
  exit 1
fi

# Prove the shipped bundle really carries this build's parsers, not just a
# matching version string.
if ! "$DEST/Contents/MacOS/StackPulseApp" --selftest-parsers >/dev/null 2>&1; then
  echo "!! the installed bundle failed its parser self-test." >&2
  exit 1
fi

echo "==> relaunching"
open "$DEST"
echo "==> installed $APP_NAME $INSTALLED at $DEST (self-test passed)"
