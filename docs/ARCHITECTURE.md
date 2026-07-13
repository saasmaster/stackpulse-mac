# Architecture

StackPulse is an event-driven, local-first monitor with a strict separation
between a **portable engine** and a **native macOS shell**. This document
explains the moving parts, who owns what, and the design rules that keep the
system honest, portable, and resilient.

## Design goals

1. **Portable core.** All platform-neutral logic lives in Rust and must build
   for non-macOS targets. The macOS app is a thin native shell over it. A future
   Windows client and a Chrome native-messaging host reuse the same core.
2. **Local-first, privacy-first.** Read the user's own logs; make no network
   calls in v0.1.0; be useful without an AI API key.
3. **Honesty by construction.** Every number carries a provenance; capabilities
   are a matrix, not a boolean; estimates are labeled as estimates.
4. **Graceful degradation.** A failure in one provider or one log line never
   takes down the snapshot.
5. **No god-singleton.** State is owned by explicit, testable modules with clear
   inputs; nothing reaches into a global mutable blob.

## The three ownership domains

The spec divides responsibility into three domains. Keeping code on the correct
side of these lines is the single most important architectural rule.

### `stackpulse-protocol` owns — *the contract*

- The versioned wire types every surface shares (`ProviderId`, `Capability`,
  `CapabilityState`, `IntegrationHealth`, `Provenance`, `TokenTotals`,
  `SpendWindow`, `ModelUsage`, `LimitWindow`, `ProviderUsage`, `UsageSnapshot`,
  `ProviderStatus`).
- The request/response envelopes (`CoreRequest`, `CoreResponse`) and the error
  model (`CoreError`, `ErrorCode`).
- `PROTOCOL_VERSION` and the forward-/backward-compatibility rules.
- **Nothing** platform-specific: no paths, no OS APIs, no I/O.

### `stackpulse-core` owns — *the shared engine*

- Provider **detection** (installed / authenticated / health) and the provider
  registry.
- Local **log scanning** and token **normalization** to the exclusive-input
  convention.
- **Pricing** (embedded estimate table) and **aggregation** (windows, per-model
  breakdowns, limit windows).
- The **dispatcher** (`Engine`) that turns a `CoreRequest` into a `CoreResponse`,
  and the JSON entry point used by the FFI and CLI.
- Environment-driven **path discovery** (never hardcoded platform paths).
- **No** AppKit, SwiftUI, Keychain, or macOS frameworks (ADR-0005).

### The macOS repo (`apps/StackPulseMac`) owns — *the native shell*

- The `NSStatusItem` menu-bar lifecycle and the SwiftUI liquid-glass popover.
- Decoding protocol JSON (forward-compatible: enums decoded as strings).
- macOS-only detail the core cannot see: the **Keychain** presence probe today;
  security-scoped bookmarks, notifications, the sidebar/main-app/Command-Center
  surfaces, and Sparkle updates in the future.
- Packaging: signing, notarization, DMG, update feed (Planned).

```
        CONTRACT                 SHARED ENGINE                  NATIVE SHELL
  ┌────────────────────┐   ┌────────────────────────┐   ┌──────────────────────┐
  │ stackpulse-        │   │ stackpulse-core        │   │ apps/StackPulseMac   │
  │ protocol           │◀──│  detection             │   │  NSStatusItem        │
  │  versioned types   │   │  scanning + normalize  │   │  SwiftUI popover     │
  │  envelopes         │──▶│  pricing + aggregate   │   │  KeychainProbe       │
  │  PROTOCOL_VERSION  │   │  Engine (dispatch)     │   │  SnapshotStore       │
  └────────────────────┘   │  env path discovery    │   │  (owns UI state)     │
            ▲              └───────────┬────────────┘   └──────────▲───────────┘
            │                          │ JSON                       │ JSON
            │             ┌────────────┴───────────┐                │
            └─────────────│ stackpulse-ffi (C ABI) │────────────────┘
                          │ stackpulse-cli (bin)   │  decodes the SAME JSON
                          └────────────────────────┘
```

## Event-driven data flow

The product vision is a normalized event pipeline feeding several UI surfaces:

```
  Providers ┐
  Scanner   ├─▶  Normalized Event Bus  ─▶  Local Store + Derived State  ─▶  ┌ Menu Bar
  Processes ┤                                                               ├ Sidebar        (Planned)
  Commands  ┘                                                               ├ Main App        (Planned)
                                                                            ├ Command Center  (Planned)
                                                                            └ Notifications   (Planned)
```

**What exists in v0.1.0:**

- **Providers + Scanner** are implemented as the Claude and Codex adapters that
  read local session logs.
- The **Normalized Event Bus** is realized today as a request/response scan: the
  core produces one normalized `UsageSnapshot` per request. Records are
  normalized to a common token convention before aggregation, which is the
  essential "normalized event" property. A continuous streaming bus is Planned.
- The **Local Store + Derived State** is the Swift `SnapshotStore`: it holds the
  latest snapshot, loading/error flags, and derived values (e.g. the menu-bar
  string, effective auth combining core + Keychain).
- The **Menu Bar** surface is implemented (popover). **Sidebar, Main App,
  Command Center, Processes/Commands ingestion, and Notifications are Planned.**

## Request lifecycle (v0.1.0)

A menu-bar refresh follows this path:

1. The Swift `SnapshotStore` triggers a refresh (on launch, on a 3-minute timer,
   or on user action), and does a cheap, non-prompting Keychain probe on the
   main actor.
2. It calls the core **off the main actor** (`Task.detached`) — the scan reads
   many log files and must never block the UI.
3. `CoreBridge` sends `{"op":"get_usage_snapshot"}` across the C ABI
   (`sp_core_handle_request`) and frees the returned string per the memory
   contract.
4. The core's `Engine` dispatches the request, scans each registered provider in
   isolation, aggregates windows and per-model breakdowns, prices records, and
   serializes a `UsageSnapshot` to JSON.
5. Swift decodes that JSON into value types and publishes them on the main actor;
   the popover and menu-bar button re-render.

The `stackpulse` CLI follows the same core path (same JSON), which is why the
CLI is a faithful stand-in for the app when debugging.

## Concurrency model

- **Structured concurrency in Swift.** The scan runs on a detached utility-
  priority task; results are hopped back to `@MainActor` before touching
  published state. All model types are value types and `Sendable`, so a snapshot
  crosses the actor boundary safely under Swift 6 language mode. A coalescing
  flag prevents overlapping refreshes.
- **The core is synchronous and pure-ish.** `Engine::handle` is deterministic
  given the clock value it is passed; `now_unix()` is the single point that reads
  the wall clock, which makes aggregation unit-testable. The engine holds a
  `Vec<Box<dyn Provider>>` registry and is cheap to construct.
- **Isolation per provider.** Each provider scan runs inside `catch_unwind`; a
  panic is downgraded to a degraded `ProviderUsage` so one bad adapter cannot
  abort the snapshot.

## Dependency injection and testability

- Providers implement a small, object-safe `Provider` trait
  (`id` / `capabilities` / `status` / `scan`). The `Engine` depends on the trait,
  not concrete types, so adding a provider is "add a module, register it" — no
  caller changes.
- Path discovery is environment-driven (`$CLAUDE_CONFIG_DIR`, `$CODEX_HOME`,
  `$XDG_CONFIG_HOME`, `$HOME`), so tests and non-macOS hosts can point the core
  at fixtures without touching real user data.
- Pure functions (`aggregate`, `pricing::estimate_cost`, the date math) are unit
  tested directly; scanners are tested against small synthetic log fixtures.
- The clock is injected into aggregation (`aggregate(records, now_unix)`), so
  window bucketing is deterministic in tests.

## Per-module state and health

Rather than a single global object, StackPulse models state as small owned
pieces:

- **Per provider:** `IntegrationHealth` (e.g. `FullySupported`, `NotDetected`,
  `TemporarilyBroken`) plus `installed` / `authenticated` flags and a capability
  matrix. This is how the UI shows *why* a provider looks the way it does.
- **Per value:** `Provenance` (`Measured`, `ProviderReported`, `LocalEstimate`,
  `Heuristic`) so the UI can distinguish a summed token count from an estimated
  dollar figure from a provider-reported limit.
- **Per snapshot:** protocol/core versions, generation time, and the disclosed
  `bucket_date_utc`.
- **App-side derived state:** the `SnapshotStore` computes the menu-bar string
  and effective auth from the snapshot; it does not mutate the snapshot.

The result is that no module is a "god singleton": the engine composes providers,
each provider owns its scan, aggregation is a pure function, and the Swift store
owns only presentation-derived state.

## Portability boundary in practice

The clearest example of the boundary is credential detection. The core detects
**file-based** credentials (e.g. `~/.claude/.credentials.json`, `~/.codex/auth.json`,
or an environment token) because that logic is portable. It cannot read the
macOS Keychain — so the Swift `KeychainProbe` adds a **presence-only** check for
Claude's Keychain item and merges it into the effective auth state. The core
stays portable; the app adds the native detail. See
[ADR-0005](decisions/0005-portable-core-boundary.md).

## Related documents

- [`PROTOCOL.md`](PROTOCOL.md) — every protocol type and JSON envelope.
- [`CAPABILITIES.md`](CAPABILITIES.md) — the provider × capability matrix.
- [`COMPATIBILITY.md`](COMPATIBILITY.md) — integration health and the planned manifest.
- [`SECURITY_BOUNDARIES.md`](SECURITY_BOUNDARIES.md) — threat model and mitigations.
- [`decisions/`](decisions/) — the ADRs referenced throughout.
