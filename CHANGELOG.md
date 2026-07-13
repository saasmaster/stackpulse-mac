# Changelog

All notable changes to StackPulse are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Note that StackPulse tracks **four independent version lines** — the app, the
core, the protocol, and (later) a compatibility manifest — as described in
[ADR-0006](docs/decisions/0006-independent-version-lines.md). Entries below note
which line changed. Protocol- and core-level changes that affect other repos are
also recorded in [`docs/CROSS_REPO_CHANGELOG.md`](docs/CROSS_REPO_CHANGELOG.md).

## [Unreleased] — Phase 0 foundation

First working foundation. Everything below is proven against real Claude Code and
Codex CLI logs on macOS (Apple Silicon).

Version lines at this point: **core 0.1.0**, **protocol 1.0.0**, app pre-release.

### Added

- **Portable Rust core (`stackpulse-core`, 0.1.0).** A platform-neutral engine
  that detects supported providers, scans their local logs, normalizes tokens,
  estimates cost, aggregates windows, and dispatches requests. Builds for
  non-macOS targets (no platform-specific code). Entry points: `Engine` and
  `handle_request_json(&str) -> String`.
- **Versioned protocol (`stackpulse-protocol`, `PROTOCOL_VERSION = 1.0.0`).**
  Serde contracts shared across the ecosystem: `ProviderId`, `Capability`,
  `CapabilityState`, `IntegrationHealth`, `Provenance`, `TokenTotals`,
  `SpendWindow`, `ModelUsage`, `LimitWindow`, `ProviderUsage`, `UsageSnapshot`,
  and the `CoreRequest`/`CoreResponse` envelopes with `CoreError`/`ErrorCode`.
  Forward-compatible by design (`#[serde(other)]` for unknown provider ids,
  `#[serde(default)]` for additive fields).
- **Claude (Claude Code) local-cost scanner.** Reads `{root}/projects/**/*.jsonl`
  with config-root resolution (`$CLAUDE_CONFIG_DIR` → `$XDG_CONFIG_HOME/claude`
  → `~/.config/claude` → `~/.claude`); sums `message.usage.*` token counts;
  deduplicates by `(message.id, requestId)`; reports per-model breakdown and
  cache metrics. Claude's `input_tokens` already excludes cache, matching the
  core's exclusive-input convention. Auth is detected by credential presence
  only (file or Keychain), never by reading the secret.
- **Codex (OpenAI Codex CLI) local-cost scanner.** Reads
  `$CODEX_HOME/sessions/**/*.jsonl` and `archived_sessions/**/*.jsonl`; sums the
  per-turn `last_token_usage` delta (not the cumulative total); tracks the active
  model from `turn_context`; captures **provider-reported 5-hour and weekly
  rate-limit windows** from `payload.rate_limits` with **zero network calls**.
  OpenAI's `input_tokens` (which includes cached) is normalized to
  `fresh_input = input - cached`.
- **Detection-only adapters** for the other nine providers (Antigravity, GitHub
  Copilot, Cursor, Devin, **Gemini**, Grok, OpenCode, OpenRouter, Z.ai), driven
  by a single data-driven `DetectableProvider`. Honest installed/authenticated
  detection (presence-only; secrets never opened), best-effort markers annotated
  with confidence, and a fully-enumerated capability matrix. Cloud/API-key
  providers with no local footprint (Devin, OpenRouter, Z.ai) report
  `not_detected`.
- **Gemini (Google) provider** (protocol **1.3.0** — `ProviderId` gained a
  `Gemini` variant). Detected via the Gemini CLI's own markers (`gemini` on
  `$PATH`, `~/.gemini/oauth_creds.json`); the shared `~/.gemini` directory is
  deliberately not treated as a marker because Antigravity writes there too.
  Live quota (Google OAuth usage API) is Planned; detection-only for now.
- **Efficiency analytics** per provider (protocol **1.1.0**, additive): measured
  cache savings (USD the prompt cache saved vs. paying full input rate), estimated
  burn rate ($/active-day), 30-day cache-hit rate, a 30-day daily history for
  charts, and a `today_vs_avg_ratio` spend-anomaly signal. Surfaced in the
  Overview and Usage sections. Measured vs. estimated values are labeled distinctly.
- **Needs-attention alerts** (protocol **1.2.0**, additive): the core derives
  alerts locally from each snapshot — usage-limit thresholds (≥75% warning, ≥90%
  critical), degraded integration health, and spend anomalies — with no network.
  Surfaced as a menu-bar badge, a popover "Needs attention" block, and a
  Needs-Attention inbox in the main window (acknowledge/dismiss).
- **Edge sidebar** — an always-on-top, non-activating `NSPanel` pinned to the
  screen edge with a compact provider + alerts summary, toggled by ⌥⌘S.
- **Keep Awake** — an opt-in power assertion that prevents system sleep while
  monitoring (idle-system-sleep only; display may still sleep).
- **Liquid Glass design system** — a hand-crafted glass material (frosted base +
  diagonal refraction sheen + rim-light edges + colored glow), glossy pill
  segmented controls with a sliding knob, glazed active navigation states, and a
  glass button style. Reduce-Transparency and Reduce-Motion aware; premium in
  both light and dark. (The native macOS 26 `glassEffect` API is unavailable
  under the macOS 15.2 Command Line Tools SDK, so the look is built from SwiftUI
  primitives that run on macOS 14+.)
- **Appearance control** — a System / Light / Dark switcher (glass pill) in
  Settings, applied app-wide (popover, main window, edge sidebar) and persisted.
- **Claude live usage limits** (opt-in, network) — reads the local Claude Code
  login from the macOS Keychain and fetches Anthropic's official OAuth usage API
  (`GET /api/oauth/usage`), giving Claude a real session/weekly limit % in the
  menu bar and popover like Codex. Token stays in memory, HTTPS to Anthropic only,
  never logged/persisted; expired tokens are not refreshed. Off = fully offline.
  A Settings toggle controls it (default on, since the user consented).
- **Project Navigator & Command Memory** (protocol **1.4.0** — `Project`,
  `DiscoveredCommand`, `GetProjects`). Scans user-approved folders for projects
  (git/node/rust/swift/python/go/docker/…), detects frameworks + package manager
  + git branch/remote, and discovers & **safety-classifies** their commands
  (package scripts, Makefile/justfile/Taskfile targets, framework conventions).
  Read-only; never executes anything in the core. A **Projects** section runs the
  right test/build/dev command (copy or run-in-Terminal, with a confirmation for
  anything not read-only).
- **Gemini live quota** wiring is stubbed for a future release; Gemini remains
  detection-only for now.
- **Agent Mission Control** (protocol **1.5.0** — `Mission`, `MissionStatus`,
  `UsageSnapshot.missions`). The core normalizes recently-active AI coding
  sessions from local logs (Claude, Codex) into missions — project, branch,
  model, last activity, token velocity, and an activity status
  (active / idle / recent) — read-only, no network, no process control.
  Surfaced in a Missions section, the Command Center live-activity panel, and an
  active-count indicator in the menu bar + popover.
- **Usage history & trends** (protocol **1.6.0** — `HistoryPoint`,
  `record_history` / `get_history` ops). A durable per-day, per-provider history
  is persisted to a plain JSON store under the app's Application Support dir,
  seeded from the 30 days already in the analytics and then accumulating beyond
  the log-rotation window. A **Trends** section charts multi-month cost/token
  history with a 30d / 90d / All range and a per-provider breakdown. (A plain
  JSON store, not SQLite — the data is tiny and it keeps the core dependency-light.)
- **BYOK provider connections** (protocol **1.7.0** — `ProviderBalance`, optional
  `ProviderUsage.balance`). A Settings "Provider connections" card lets you enter
  API keys for API-key providers; keys are stored in StackPulse's own macOS
  Keychain and sent only to that provider's API. **OpenRouter** and **LiteLLM**
  report a real credit balance (remaining / used / limit) shown on the provider
  card + Integrations. Populated in the app layer, so the portable core stays
  offline. Other API-key providers are connectable now, with balance fetchers to
  follow.
- **Embedded pricing table** of approximate public list prices per 1M tokens
  (as of 2026-07) for the Claude (Opus/Sonnet/Haiku) and OpenAI GPT-5/Codex
  families. All derived costs are labeled `LocalEstimate` and never presented as
  billed amounts. Unpriceable models are excluded from cost totals and surfaced
  in a note.
- **C ABI FFI bridge (`stackpulse-ffi`, `staticlib` + `cdylib`).** Functions
  `sp_core_handle_request(json) -> json`, `sp_core_version()`, and
  `sp_core_string_free()`, with a documented single-owner memory contract and
  panic-safety at the boundary.
- **`stackpulse` CLI.** `snapshot` (human summary or `--json`), `status`,
  `ping`, and raw `request` subcommands. Also serves as the portability
  smoke-test target.
- **macOS menu-bar app (`apps/StackPulseMac`, SwiftPM).** An `NSStatusItem`
  accessory app (no Dock icon) with a SwiftUI liquid-glass popover that links the
  Rust static library and decodes the same protocol JSON as the CLI. Includes a
  presence-only macOS Keychain probe for Claude credentials, a background scan
  off the main actor, and headless `--dump` / `--version` verification modes.
- **UTC date bucketing.** Windows (today / yesterday / last 30 days) are bucketed
  by UTC date in this version; the snapshot discloses `bucket_date_utc` so the UI
  can label windows as UTC-based. See
  [ADR-0007](docs/decisions/0007-utc-bucketing-v0.md).
- **Documentation set.** Architecture, protocol, capability matrix, compatibility,
  security boundaries, cross-repo changelog, and the initial ADRs.

### Security

- No network access in this version; scanning is read-only; symlinked directories
  are not followed during traversal; credentials are detected by presence only.
  See [`docs/SECURITY_BOUNDARIES.md`](docs/SECURITY_BOUNDARIES.md).

### Known limitations

- Only **Claude** and **Codex** have full local usage/cost scanners. The other
  eight (Antigravity, GitHub Copilot, Cursor, Devin, Grok, OpenCode, OpenRouter,
  Z.ai) are **detection-only** — installed/authenticated detection and a
  capability matrix, but no usage scanning yet.
- No live provider usage APIs (Claude's OAuth usage endpoint is not wired).
- No persisted history/database; snapshots are computed on demand.
- No code signing, notarization, DMG, or Sparkle auto-update yet.
- Cost figures are list-price **estimates**, not billed amounts.

[Unreleased]: https://github.com/stackpulse/stackpulse-mac
