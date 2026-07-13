#!/usr/bin/env bash
# Build the Rust portable core artifacts the macOS app links against.
#   - libstackpulse_ffi.a  (static lib linked into the Swift executable)
#   - stackpulse           (CLI, also used for smoke tests)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${1:-release}"
FLAG=""
[ "$PROFILE" = "release" ] && FLAG="--release"

echo "==> cargo build ($PROFILE): ffi + cli"
cargo build $FLAG -p stackpulse-ffi -p stackpulse-cli

echo "==> artifacts in target/$PROFILE:"
ls -la "target/$PROFILE/libstackpulse_ffi.a" "target/$PROFILE/stackpulse" 2>/dev/null || true
echo "==> done"
