# StackPulse

**A local-first, privacy-first command center for AI-assisted development on macOS.**

StackPulse watches the AI-coding providers you already use — how much you have
spent, how close you are to your usage limits, which models and projects are
burning tokens, and whether each integration is healthy — and surfaces it in a
native macOS menu-bar app. It reads only your own local logs, makes **no network
calls in this version**, and is useful even without an AI API key.

> **Status: v0.1.0 — Phase 0 foundation.** The portable Rust core, the Claude
> and Codex local-cost scanners, the C ABI bridge, and a SwiftUI menu-bar
> popover are working against real data. Many surfaces described in the vision
> below are explicitly marked **Planned**. StackPulse does not claim features it
> has not built.

---

## Why StackPulse

If you use Claude Code, the OpenAI Codex CLI, and other AI coding tools, your
spend and rate-limit state are scattered across each tool's own logs. StackPulse
consolidates them:

- **Spend and tokens at a glance** — today, yesterday, and the last 30 days, per
  provider and per model, with cache economics broken out.
- **Live limit windows** — for providers that record them locally (Codex's
  5-hour and weekly windows), StackPulse reads them with **zero network calls**.
- **Honest numbers** — every value is labeled with its provenance (measured,
  provider-reported, or a local estimate). Costs are estimates, never presented
  as amounts you were billed.
- **Local-first and private** — it reads files under your home directory that
  the AI tools already write, and nothing leaves your machine.

## What "local-first, no key required" means here

StackPulse computes everything in v0.1.0 from logs that Claude Code and the
Codex CLI already write to disk. It does not call any provider API, and it does
not need you to paste an API key. Detection of credentials checks only for their
**presence** (a file exists, or a Keychain item exists) — StackPulse never reads
the secret itself.

---

## Architecture in one paragraph

A **portable Rust core** does all the platform-neutral work — provider
detection, log scanning, token normalization, pricing, and aggregation — and
speaks a small, versioned JSON protocol. The **macOS app** is a Swift package
that links the Rust core as a static library and decodes the exact same JSON the
command-line tool prints. The core has **no macOS-specific code**, so a future
Windows client and a Chrome native-messaging host can reuse it unchanged.

```
              ┌──────────────────────────────────────────────┐
              │  stackpulse-protocol   (versioned contracts)  │
              └──────────────────────────────────────────────┘
                         ▲                        ▲
                         │ types                  │ types
              ┌──────────┴──────────┐   ┌─────────┴───────────┐
              │   stackpulse-core   │   │   Swift decoders    │
              │  (portable engine)  │   │  (apps/StackPulseMac)│
              └──────────┬──────────┘   └─────────▲───────────┘
                         │                         │
         ┌───────────────┼─────────────┐           │ JSON in / JSON out
         │               │             │           │
   stackpulse-cli   stackpulse-ffi ────┘   (C ABI: sp_core_handle_request)
   (stackpulse bin)  (staticlib+cdylib)
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full picture.

## Repository layout

| Path | What it is |
| --- | --- |
| `crates/stackpulse-protocol` | Versioned, platform-neutral serde contracts (`PROTOCOL_VERSION = 1.0.0`). |
| `crates/stackpulse-core` | The portable engine: detection, scanning, pricing, aggregation, dispatch. No platform code. |
| `crates/stackpulse-ffi` | Tiny C ABI (`staticlib` + `cdylib`) — JSON in, JSON out. |
| `crates/stackpulse-cli` | The `stackpulse` binary and the portability smoke-test target. |
| `apps/StackPulseMac` | The macOS menu-bar app (SwiftPM, links the Rust static lib). |
| `docs/` | Architecture, protocol, capabilities, security, and decision records. |

## Supported providers (v0.1.0)

All ten providers — **Antigravity, Claude, Codex, GitHub Copilot, Cursor,
Devin, Grok, OpenCode, OpenRouter, Z.ai** — are registered and appear in every
snapshot. Two have full local scanners; the rest are detection-only for now.

| Provider | v0.1.0 status |
| --- | --- |
| **Claude** (Claude Code) | Full local-cost scan, per-model breakdown, cache metrics. Live OAuth usage limits are **Planned**. |
| **Codex** (OpenAI Codex CLI) | Full local-cost scan, per-model breakdown, cache metrics, plus **provider-reported 5-hour / weekly limit windows** read from local logs with no network. |
| The other 8 | **Detection-only.** Honest installed / authenticated detection (presence-only) + a full capability matrix. Local usage/cost scanning is **Planned**. Devin, OpenRouter, and Z.ai are cloud/API-key services with no local footprint and read `not_detected` until an API-key integration lands. |

The full, honest capability matrix is in [`docs/CAPABILITIES.md`](docs/CAPABILITIES.md).

## Pricing and cost estimates

Costs come from an **embedded price table** of approximate public list prices per
million tokens (as of 2026-07). They are always labeled `LocalEstimate` and the
UI never presents them as billed amounts. For subscription/plan users these are
*equivalent metered list-price* estimates — a sense of what the same usage would
cost at list, not what you actually paid. Remote pricing (litellm, models.dev)
is a **Planned** enhancement. Details: [`docs/PRIVACY.md`](PRIVACY.md) and the
pricing notes in [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

---

## Building

### Prerequisites

- macOS on Apple Silicon (developed on macOS 26.5.1).
- **Rust 1.96+** (workspace MSRV is 1.80).
- **Swift 6.0+** with the Command Line Tools. Full Xcode is **not** required or
  used; the macOS app is a Swift Package built with SwiftPM.

### 1. Build the portable core and the CLI

```sh
# From the repo root
cargo build --release
cargo test            # runs the core, protocol, and provider unit tests
```

Try the CLI against your own machine:

```sh
./target/release/stackpulse snapshot          # human-readable summary
./target/release/stackpulse snapshot --json    # full UsageSnapshot JSON
./target/release/stackpulse status             # cheap per-provider detection
./target/release/stackpulse ping               # core + protocol versions
```

### 2. Build the FFI static library and the macOS app

The macOS app links `libstackpulse_ffi.a`, produced by building the FFI crate in
release mode, and then builds with SwiftPM:

```sh
cargo build -p stackpulse-ffi --release
cd apps/StackPulseMac
swift build
```

Run the app headless to verify the bridge without launching the GUI:

```sh
swift run StackPulseApp --dump       # prints the raw snapshot JSON and exits
swift run StackPulseApp --version    # prints the core version via the C ABI
```

Running `swift run StackPulseApp` with no flags starts the menu-bar accessory
app (no Dock icon); click the menu-bar gauge to open the popover.

> The SwiftPM linker search path for the static archive is **relative**
> (`-L ../../target/release`) so it survives a repository path that contains
> spaces. Build the app from the `apps/StackPulseMac` directory.

### Verifying portability

The core and protocol crates must build for non-macOS targets. That property is
guarded by keeping all platform-specific code out of those crates
(see [ADR-0005](docs/decisions/0005-portable-core-boundary.md)); the
`stackpulse-cli` binary is the smoke-test target for it.

---

## Distribution (Planned)

The intended release pipeline is Developer ID signing + hardened runtime +
notarization + a signed DMG with a published SHA-256, and in-app updates via a
Sparkle feed (stable and beta channels). Sparkle is **not yet integrated**. See
[`SECURITY.md`](SECURITY.md) for how signing fits the threat model.

## Versioning

The app version, the core version (`0.1.0`), the protocol version (`1.0.0`), and
a future compatibility-manifest version are **independent** version lines, all
SemVer. Pre-1.0 lines use `0.x`. Rationale:
[ADR-0006](docs/decisions/0006-independent-version-lines.md).

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — event-driven design, crate/app boundaries, ownership split.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — every protocol type and JSON envelope with real examples.
- [`docs/CAPABILITIES.md`](docs/CAPABILITIES.md) — the provider × capability matrix.
- [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) — integration-health tracking and the planned signed manifest.
- [`docs/SECURITY_BOUNDARIES.md`](docs/SECURITY_BOUNDARIES.md) — threat model and current mitigations.
- [`docs/CROSS_REPO_CHANGELOG.md`](docs/CROSS_REPO_CHANGELOG.md) — protocol/core/capability changes across repos.
- [`docs/decisions/`](docs/decisions/) — architecture decision records (ADRs).
- [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md), [`PRIVACY.md`](PRIVACY.md), [`CHANGELOG.md`](CHANGELOG.md).

## Attribution

StackPulse incorporates **OpenUsage** (`robinebers/openusage`, MIT, upstream ref
v0.7.5) as an attributed reference — its parsing and pricing logic was ported to
Rust and its app was reimplemented natively — and studied **CodexBar**
(`steipete/CodexBar`, MIT) and **Tokcat** (`handlecusion/tokcat`) for ideas. It
is **not** a fork, and it does not reuse the OpenUsage name or marks. See
[`NOTICE`](NOTICE) for the full, honest attribution.

## License

MIT © 2026 StackPulse contributors. See [`LICENSE`](LICENSE).
