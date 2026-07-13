# Contributing to StackPulse

Thank you for your interest in StackPulse. This document explains how the
project is organized, how to build and test it, and the rules that keep the
codebase honest and portable.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Guiding principles

These are not negotiable; PRs that violate them will be asked to change.

1. **Local-first and private.** StackPulse reads the user's own local logs and,
   in this version, makes **no network calls**. Do not add a network dependency
   to `stackpulse-core` without an explicit design discussion and an opt-in.
2. **Honesty over polish.** Never present an estimate as a measured fact. Every
   number carries a `Provenance`. Costs are `LocalEstimate` and must be labeled
   as such in any UI. Do not claim a capability an adapter cannot actually
   provide — report `Unsupported` instead.
3. **Portable core.** `stackpulse-protocol` and `stackpulse-core` must build for
   non-macOS targets. No AppKit, no Keychain, no hardcoded platform paths, no
   macOS frameworks in those crates. Platform specifics live in the Swift app.
   See [ADR-0005](docs/decisions/0005-portable-core-boundary.md).
4. **Graceful degradation.** One provider failing must never take down the
   snapshot. Scans must not panic; on error, return a degraded `ProviderUsage`
   with a human-readable note.
5. **Read-only.** v0.1.0 never executes provider commands, never writes to
   provider data, and never follows symlinks while scanning.

## Project layout

| Path | Owner | Notes |
| --- | --- | --- |
| `crates/stackpulse-protocol` | protocol | Versioned wire contracts. Breaking changes bump `PROTOCOL_VERSION`. |
| `crates/stackpulse-core` | shared core | Detection, scanning, pricing, aggregation, dispatch. No platform code. |
| `crates/stackpulse-ffi` | shared core | C ABI. Keep it tiny: JSON in, JSON out. |
| `crates/stackpulse-cli` | shared core | `stackpulse` binary; also the portability smoke test. |
| `apps/StackPulseMac` | mac app | SwiftPM app; owns menu bar, UI, Keychain, updates. |
| `docs/` | all | Architecture, protocol, capabilities, security, ADRs. |

Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) before your first change so
you put code on the correct side of the boundary.

## Development setup

Prerequisites: Rust 1.96+ (MSRV 1.80), Swift 6.0+ with Command Line Tools,
macOS on Apple Silicon. Full Xcode is not used.

```sh
# Rust core, protocol, CLI
cargo build --release
cargo test
cargo fmt --all
cargo clippy --all-targets -- -D warnings

# FFI static lib + macOS app
cargo build -p stackpulse-ffi --release
cd apps/StackPulseMac && swift build
```

Handy verification commands:

```sh
./target/release/stackpulse snapshot --json     # full snapshot from your machine
swift run StackPulseApp --dump                   # same snapshot through the C ABI
```

## Before you open a pull request

Run all of the following and make sure they pass:

- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --all-targets -- -D warnings`
- [ ] `cargo test` (unit tests in protocol, core, and providers)
- [ ] `cd apps/StackPulseMac && swift build`
- [ ] For a protocol change: `PROTOCOL_VERSION` bumped if breaking, and
      `docs/PROTOCOL.md` + `docs/CROSS_REPO_CHANGELOG.md` updated.
- [ ] For a user-visible change: a `CHANGELOG.md` entry under `[Unreleased]`.

## Contribution guidelines by area

### Adding or changing a provider adapter

An adapter is a small unit struct implementing the `Provider` trait in
`crates/stackpulse-core/src/providers/`. To add one:

1. Add a module under `providers/` and register it in `engine.rs`
   (`Engine::new`). No caller changes are needed.
2. Advertise a **capability matrix** (`fn capabilities`) using the honest
   `Supported` / `Unavailable` / `Unsupported` states — never a single boolean.
3. Normalize tokens to the "exclusive input" convention (fresh input excludes
   cached tokens) so pricing is consistent across providers. Document any
   provider-specific quirk in the module's doc comment (as `claude.rs` and
   `codex.rs` do).
4. Deduplicate replayed turns; scanning resumed/archived sessions must not
   double-count.
5. Add unit tests with a small synthetic log fixture (see the existing
   `#[cfg(test)]` blocks). Do not commit real user logs.
6. Update [`docs/CAPABILITIES.md`](docs/CAPABILITIES.md).

### Changing the protocol

The protocol is a cross-repo contract (macOS app today; a Chrome host and a
Windows client tomorrow). Prefer **additive, backward-compatible** changes:
new fields should be `#[serde(default)]` so older peers keep parsing newer
payloads. A breaking change **must** bump `PROTOCOL_VERSION` and be recorded in
`docs/PROTOCOL.md` and `docs/CROSS_REPO_CHANGELOG.md`. See
[ADR-0006](docs/decisions/0006-independent-version-lines.md).

### Changing the pricing table

Pricing lives in `crates/stackpulse-core/src/pricing.rs`. When you update rates,
bump `PRICING_AS_OF` and keep the values as **approximate public list prices**.
Never wire pricing to a specific user's billing. Add or update tests that pin
the arithmetic.

### macOS app changes

The Swift app owns the menu bar, the SwiftUI popover, Keychain probing, and
(later) notifications, security-scoped bookmarks, and Sparkle updates. Keep
these out of the Rust core. The app decodes protocol JSON as `String`-typed
enums so a newer core never breaks decoding (forward compatibility).

## Commit and PR style

- Keep PRs focused; one concern per PR.
- Write a clear description of *what* and *why*. Link the relevant ADR or doc.
- Reference issues where applicable.
- New behavior needs tests; new user-facing behavior needs a changelog entry.

## Reporting bugs and vulnerabilities

- Ordinary bugs: open a GitHub issue with steps to reproduce, your macOS/Rust/
  Swift versions, and (redacted) relevant output. Never paste secrets or full
  session logs.
- Security vulnerabilities: **do not** open a public issue. Follow
  [`SECURITY.md`](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
project's MIT License (see [`LICENSE`](LICENSE)).
