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

### Repository Radar / Discover (app 0.9.0 / protocol 1.11.0)

- **New Discover section (Repository Radar).** The core scans your approved
  project roots and emits **deterministic, explainable, project-grounded**
  recommendations — never a generic feed. Each card answers the spec's "must
  explain" questions: why it's relevant, **which projects** it affects, the
  **evidence**, **effort**, **risk**, and **whether no change is safer**. Rules
  (all from local facts — filesystem + `git`, no network): missing agent
  instructions (CLAUDE.md/AGENTS.md → agents re-discover the layout each
  session), generated folders not `.gitignore`d, no test command where the stack
  is testable, `.env.example` with no `.env`, stale projects with uncommitted
  work, git repos with no remote/backup, and TypeScript projects with no
  typecheck script. Cards aggregate across projects (with the affected list) to
  stay high-signal; a clean scan shows an honest "nothing to flag" state. Copy a
  single card or **Copy all** as text to paste into a task or an agent prompt.
- Protocol 1.11.0 adds `Recommendation` / `RadarCategory` / `RadarEffort` /
  `RadarRisk` / `RadarReport` + the `get_radar` op and `radar` response. The
  radar engine (`radar.rs`) is portable and offline; **89 → 97 core tests**.
- Verified against the real machine: 29 projects scanned → 6 grounded
  recommendations (e.g. 21 projects with no agent-instructions file, 5 idle
  projects holding uncommitted work), all with real project names + evidence.

### Web Preview + Sidebar tabs + dev-server control (app 0.8.0)

- **One-tap web preview from Projects.** Each web project gains a **Preview on
  Web** button: StackPulse infers the dev command (a discovered `dev`/`start`/
  `serve` command, else `<pm> dev`) and the localhost port (parsed from the
  command — `--port`/`-p`/`PORT=` — else the framework's default), runs it
  **visibly in Terminal**, then opens the browser the moment the port is actually
  listening (a Network-framework readiness poll, no blind delay). If a matching
  dev server is already running it becomes **Open Preview** and opens directly.
- **Sidebar tabs.** The edge sidebar now has a frosted **Cards / Live / Web**
  segmented control (persisted across launches): *Cards* is the rich per-provider
  list, *Live* is active coding sessions + anything needing attention, and *Web*
  lists locally-running dev servers with one-tap Open.
- **Stop a dev server (safe, confirmed).** The Services section can now stop a
  detected dev server — a confirmation dialog, then a graceful `SIGTERM` (never
  `SIGKILL`) so it frees its port cleanly. Read-only everywhere else; this is the
  only mutating action and it's always one explicit, targeted tap.
- Swift-only wave — no protocol or core change. Integrated build clean.

### Richer Missions + Reports (app 0.7.0 / protocol 1.10.0)

- **Missions now show what an agent actually did.** Each mission gains **changed
  files** (from `git status` of the session's project) and a **preview of the
  latest turn**, plus safe **quick actions** (Reveal in Finder, Copy). Protocol
  1.10.0 adds `Mission.changed_files` + `Mission.last_message_preview`, both
  computed locally (git + the existing session-tail read; no network).
- **New Reports section** — a shareable, composed report of your usage, cache
  efficiency, insights, active work, and per-project stack health, with export to
  **Markdown / CSV / JSON** and a copy-summary. Built from data already local; the
  main-window "Monitor" group gains a Reports entry.

### Settings is its own window; the main window is data-only (app 0.6.3 — app-only)

Full separation of configuration from data:
- **New dedicated Settings window** (⌘, or the gear) with two tabs: **Settings**
  (appearance, refresh, notifications, edge sidebar, live limits, power, provider
  connections/API keys, tools, About) and **Integrations** — all the
  configuration, in its own window like a standard macOS preferences window.
- **The main window is now purely dashboards** — Overview, Missions, Insights,
  Usage, Trends, Needs Attention, Projects, Stack Health, Services. **Settings and
  Integrations were removed from its sidebar.** A "Settings" gear sits in the
  sidebar footer (and ⌘,) to open the separate window.
- The popover gear and the ⌘, shortcut both open the Settings window.

### Settings holds only settings (app 0.6.2 — app-only)

Settings was showing live *data* that belongs in the dashboards. It now holds
only controls:

- Removed from Settings: **Last updated**, **UTC bucket**, the refresh **cadence
  read-out** (the control already shows it), and the live-limits **"Last checked"
  + status** (all shown on the Claude card / popover / sidebar).
- Reordered into **preferences & options** first (appearance, refresh, notifications,
  edge sidebar, live limits, power, provider connections), then **tools** (Command
  Center, export), then a clearly-separated **About** footer for the static
  reference the spec requires there (versions, cost methodology, accessibility).

### Navigation reorganized (app 0.6.1 — app-only)

The information (Overview, Missions, Insights, Usage, Trends…) all sat in one flat
list you reached via the Settings gear, with Settings lumped in among it. Now:

- **Main-window sidebar is grouped** — **Monitor** (Overview, Missions, Insights,
  Usage, Trends, Needs Attention), **Build** (Projects, Stack Health, Services),
  **Providers** (Integrations) — with **Settings pinned separately at the bottom**
  so it reads as app settings, not another dashboard.
- **The popover "Open" button lands on the Overview dashboard**, not wherever the
  window was last (often Settings). The gear still goes straight to Settings.
- **The edge sidebar ("side card") gained an "Open in app" launcher** — one tap
  jumps to Overview / Usage / Trends / Missions / Insights / Stack Health, so the
  useful views are one click away instead of buried.

### Stack Health + Services — Phase 4 begins (app 0.6.0 / protocol 1.9.0)

The app was heavy on *watching* (usage/analytics) and light on the spec's
differentiators. This starts closing that gap with two new main-window sections.

- **Stack Health** — "is each project's stack current, compatible, and secure?"
  The portable core parses your **npm + Cargo** manifests/lockfiles into an
  offline dependency inventory (installed versions); the macOS app then fetches
  **latest versions** from the npm/crates registries and **security advisories**
  from **OSV**, flagging what's outdated (minor vs. major) or vulnerable. Network
  lives in the app layer, not the core, so the core stays pure/portable.
- **Services** — "what's running right now?" The core detects local **dev servers
  by listening TCP port** (`lsof`) and matches them to your projects; the app
  lists them grouped by project with the port, kind, and an **Open** action.
- Protocol **1.9.0** (additive): `ProjectStack` / `Dependency` / `Advisory` /
  `DependencyStatus` / `AdvisorySeverity` / `StackSummary` + `get_stack_health`;
  `RunningService` + `get_services`.

### Richer edge sidebar, sidebar positioning, quick Settings, deeper Antigravity (app 0.5.0)

- **The edge sidebar is actually useful now.** It was a name + one percentage per
  provider; it now leads with a **totals strip** (today's spend + tokens, live
  session count, items-to-check), an **Active-now** block, needs-attention, and
  **rich per-provider rows** — tokens · turns · cache% for measured providers, or
  sessions · model for activity-only ones (Antigravity), plus the hottest limit
  meter.
- **Sidebar can pin left or right.** A **⇄ quick toggle** in the sidebar header
  flips the edge live, plus a Left/Right control in **Settings → Edge sidebar**.
  Persisted; the panel re-pins instantly.
- **Quick Settings from the menu bar.** The popover now has a clear **gear →
  Settings** button (Command Center moved after it, still one click / ⌘⇧C).
- **Deeper Antigravity.** Real **agent-step counts** per conversation, read from
  the SQLite trajectories via `rusqlite` scoped to the **macOS target only** (the
  portable-core Linux/Windows CI gates never pull a C toolchain; the DB is opened
  read-only and coexists safely with Antigravity writing it). Antigravity missions
  now show real activity (e.g. "464 steps") instead of "0 turns", and the card
  notes total agent steps.

### Claude live-limits: stale-token handling (app 0.4.1 — app-only)

- **Fixed the misleading "Sign in to Claude" message.** StackPulse reads Claude
  Code's saved OAuth token (and never refreshes it — refreshing could rotate the
  token and sign you *out* of Claude Code). When that saved token expires, the
  card used to say "Sign in to Claude Code," which reads as *signed out* even
  though you aren't. It now says the saved login has expired and will resume when
  Claude Code renews it. A genuine 401 (real re-auth needed) is worded distinctly.
- **The last-known % now survives.** Live limits are persisted to disk and shown
  with an honest **"as of …"** label when a fresh value can't be fetched (expired
  token, offline, rate-limited) — instead of the card blanking. The cache window
  extends to a few days since Claude's dominant window is weekly (slow-moving).

### Antigravity real-data scanner (app 0.4.0 — core behavior, no protocol change)

- **Antigravity now shows real local data** instead of a detection-only "no
  data" state. It's a Windsurf/Codeium-style agent IDE (talks to Gemini); the new
  `providers::antigravity` scanner reads `~/.gemini/antigravity/conversations/*.db`
  for **conversation count, recency, and the model** (`gemini-3-flash-agent`,
  recovered by a bounded byte-scan — **no SQLite dependency**). Token and cost are
  managed **server-side** by Gemini and aren't available locally, so they are
  honestly not shown (no fabricated numbers) — the card explains this.
- **In-progress Antigravity sessions surface as Missions** — they appear in the
  Missions view and the menu-bar ▶N active-session count, alongside Claude/Codex.
- **Activity-aware provider card.** A provider with local activity but no local
  token/cost accounting (Antigravity) now shows a **session + model row** instead
  of a misleading "$0 · 0 tokens" spend row.
- The engine registers three full scanners (Claude, Codex, Antigravity) + eight
  detection-only providers (still eleven total). Antigravity's capability matrix
  gains auth / local-session-history / live-task-detection. +3 tests.

### Insights & reporting (app 0.3.0 / protocol 1.8.0)

- **Derived insights engine (core, protocol 1.8.0).** New `Insight` /
  `InsightImpact` / `InsightKind` types + an additive `UsageSnapshot.insights`
  list. The portable core now turns each scan into ranked, actionable
  observations — all computed **locally**, no network: **low cache efficiency**
  (savings left unclaimed), **spend anomaly** (today vs. the 30-day average),
  **approaching limit** (a heads-up band that sits a notch below the alert
  threshold so the two never double-fire), **idle provider** (detected but unused
  30 days), **cost concentration** (one model dominating spend), and a hedged
  **possibly-stalled session** (an AI coding session idle mid-task — surfaced for
  you to judge, never auto-acted upon). Ranked most-useful-first. 19 new tests.
- **Insights section (app).** A new **Insights** sidebar destination with a count
  badge, impact-grouped Liquid-Glass cards (High → Medium → Low), each showing the
  provider, a highlighted metric, and a relative time — plus a friendly empty
  state and a "these are suggestions; nothing changes automatically" reassurance.
- **Data export & reporting (app).** Export your usage as **CSV or JSON** and a
  one-click **Copy summary** — snapshot export + Copy summary live in Settings
  ("Data & export"), history export lives in Trends. Saves go through a standard
  save panel (you pick the location); everything stays on your Mac.

### Notifications & proactive alerting (app 0.2.0 — app-only, no protocol/core change)

- **Native macOS notifications for needs-attention alerts.** When a new alert
  appears (a usage limit nearing its cap, a spend anomaly, an integration issue),
  StackPulse now raises a system notification — a menu-bar app is far more useful
  when it can tap you on the shoulder instead of only showing state when opened.
  Clicking a notification opens the app on the needs-attention section.
  Everything stays local: notifications only ever surface an alert already derived
  from your own data; nothing is originated or sent anywhere.
- **Transition-based, non-spammy delivery.** A pure, self-tested gate
  (`NotificationGate`) notifies only when an alert *newly* becomes active — the
  first snapshot after launch seeds silently (no burst for pre-existing state),
  a persisting alert never re-fires, and a cleared-then-returning condition
  notifies again. Re-delivery replaces (not stacks) by alert id.
- **Proactive Claude live-limit alerts.** The offline core can't see Claude's
  live session/weekly limits, so it never alerted on them. The app now synthesizes
  needs-attention alerts from the merged live limits — warning at ≥ 80%, critical
  at ≥ 95% — surfaced across the popover, inbox, and menu-bar badge, and eligible
  for notification. Codex limit alerts continue to come from the core (no dupes).
- **Notification preferences (Settings).** Master toggle, a severity threshold
  (All / Warnings+ / Critical), quiet hours (a from/to window that may wrap
  midnight, muting banners while keeping alerts in-app), a one-click *Send a test
  notification* button, and a hint when banners are disabled in System Settings.
  All persisted in `UserDefaults`.
- **Self-tests + a diagnostic.** `--selftest-parsers` now also asserts the
  notification gate and quiet-hours logic; `--selftest-notify` posts a test banner
  and reads it back from Notification Center as an end-to-end delivery probe.
- **Fixed:** a Swift 6 actor-isolation trap (`dispatch_assert_queue_fail`) that
  crashed the app on launch — the `UNUserNotificationCenter` Objective-C
  completion bridge, invoked from a `@MainActor` context, resumed its continuation
  with a main-actor isolation check that failed on the daemon's background queue.
  The center calls now run from a `nonisolated static` helper, hopping back to the
  main actor only to publish results.

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
