#!/usr/bin/env bash
# Portability smoke test for the shared core.
#
# The portable crates (stackpulse-protocol, stackpulse-core, stackpulse-cli)
# MUST build for non-macOS targets so the future Windows client and Chrome
# native host can reuse them. This proves the boundary before the Mac app is
# finished (spec: "minimal Windows core smoke test early").
#
# Strategy:
#   1. Always: build + test the portable crates on the host.
#   2. If a Windows target + linker are available, cross-compile them too.
#      Missing cross toolchain is a soft skip (CI's Linux job is the hard gate).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORTABLE=(-p stackpulse-protocol -p stackpulse-core -p stackpulse-cli)

echo "==> host build + test of portable crates"
cargo build "${PORTABLE[@]}"
cargo test "${PORTABLE[@]}"

TARGET="x86_64-pc-windows-gnu"
echo "==> attempting cross-compile for $TARGET"
if rustup target list --installed 2>/dev/null | grep -q "$TARGET"; then
  if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    cargo build "${PORTABLE[@]}" --target "$TARGET"
    echo "==> cross-compile OK ($TARGET)"
  else
    echo "~~ SKIP: mingw linker (x86_64-w64-mingw32-gcc) not installed."
    echo "   install: brew install mingw-w64   (then re-run)"
  fi
else
  echo "~~ SKIP: rust target $TARGET not installed."
  echo "   install: rustup target add $TARGET"
fi

# The FFI crate is intentionally macOS/native-oriented; do not require it to
# cross-compile here. Portability is guaranteed for the pure-logic crates.
echo "==> portability smoke done"
