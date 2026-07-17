#!/usr/bin/env bash
# Build the whole macOS app: Rust core (release) then the Swift executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-core.sh" release

# SwiftPM does not track the Rust staticlib as an input: it is pulled in via
# linker flags, not a declared dependency. So when only the core changes, swift
# build considers the executable up to date and silently keeps linking the OLD
# core — the app then reports stale results from a tree that looks fully rebuilt.
# This is not hypothetical: a core fix was verified green in `cargo test` and via
# the CLI while the packaged app still shipped the previous behaviour.
#
# Drop the executable whenever the staticlib is newer, forcing a re-link.
LIB="$ROOT/target/release/libstackpulse_ffi.a"
APP_BIN="$ROOT/apps/StackPulseMac/.build/release/StackPulseApp"
if [ -f "$LIB" ] && [ -f "$APP_BIN" ] && [ "$LIB" -nt "$APP_BIN" ]; then
  echo "==> core is newer than the app binary — forcing a re-link"
  rm -f "$APP_BIN"
fi

echo "==> swift build (release)"
cd "$ROOT/apps/StackPulseMac"
swift build -c release

echo "==> app binary:"
ls -la "$ROOT/apps/StackPulseMac/.build/release/StackPulseApp"
echo "==> done"
