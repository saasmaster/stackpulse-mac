#!/usr/bin/env bash
# Build the whole macOS app: Rust core (release) then the Swift executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-core.sh" release

echo "==> swift build (release)"
cd "$ROOT/apps/StackPulseMac"
swift build -c release

echo "==> app binary:"
ls -la "$ROOT/apps/StackPulseMac/.build/release/StackPulseApp"
echo "==> done"
