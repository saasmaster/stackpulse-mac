# Cross-Repo Changelog

This file tracks changes to the **shared contract** — the protocol, the portable
core's observable behavior, and the capability taxonomy — that affect, or will
affect, repositories **other than this one**.

## Why a separate changelog

StackPulse's portable core and versioned protocol are meant to be reused beyond
the macOS app. Two consumers are planned:

- a **Windows client** (a native app that links the same Rust core), and
- a **Chrome extension + native-messaging host** (which speaks the same JSON
  protocol).

Those live (or will live) in separate repositories. When the protocol, the core,
or the capability set changes, those repos need to know — even before they exist,
we keep the record so their first implementations can target a known baseline.
This complements, and does not replace:

- [`../CHANGELOG.md`](../CHANGELOG.md) — user-facing changes to this repo.
- [`PROTOCOL.md`](PROTOCOL.md) — the current protocol definition.
- [`CAPABILITIES.md`](CAPABILITIES.md) — the current capability matrix.

## What belongs here

Record an entry when a change touches any of:

- **Protocol** (`stackpulse-protocol`): a new/changed/removed type or field, a
  change to envelope tagging, or a `PROTOCOL_VERSION` bump.
- **Core behavior** (`stackpulse-core`) that other clients would observe: new
  provider adapters, changed normalization/pricing conventions, new snapshot
  fields, changed path-discovery rules.
- **Capabilities**: a new `Capability` or `IntegrationHealth` variant, or a
  provider's advertised matrix changing in a way clients render.
- **Compatibility manifest**: schema or verification-rule changes (once it ships).

Do **not** record macOS-app-only UI changes here (those go in the app changelog).

## Entry format

Each entry notes the affected surface, the version line(s) that moved, whether it
is breaking for downstream consumers, and the action they should take.

```
### <date> — <short title>
- Surface: protocol | core | capabilities | manifest
- Versions: protocol x.y.z / core a.b.c / manifest m.n.p
- Breaking for downstream: yes | no
- Change: <what changed>
- Downstream action: <what a Windows/Chrome consumer must do>
```

---

## Baseline

### 2026-07-12 — Initial contract baseline (Phase 0)

- **Surface:** protocol + core + capabilities
- **Versions:** protocol **1.0.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** n/a (baseline)
- **Change:** Establishes the initial shared contract that any future Windows
  client or Chrome native-messaging host targets:
  - **Protocol 1.0.0** types: `Version`, `ProviderId` (open enum with `unknown`
    catch-all), `Capability`, `CapabilityState`, `IntegrationHealth`,
    `Provenance`, `TokenTotals`, `SpendWindow`, `ModelUsage`, `LimitWindow`,
    `ProviderUsage`, `UsageSnapshot`, `ProviderStatus`, and the `CoreRequest`
    (`op`-tagged) / `CoreResponse` (`kind`-tagged) envelopes with `CoreError` /
    `ErrorCode`.
  - **Transport:** JSON in / JSON out. The single core entry point is
    `handle_request_json(&str) -> String`; the C ABI exposes it as
    `sp_core_handle_request`, alongside `sp_core_version` and
    `sp_core_string_free` (see [ADR-0003](decisions/0003-rust-core-c-abi-bridge.md)).
  - **Core 0.1.0** behavior: registered adapters for **Claude** and **Codex**
    only; token normalization to the exclusive-input convention; embedded
    list-price estimate table (as of 2026-07); UTC date bucketing with a
    disclosed `bucket_date_utc` (see
    [ADR-0007](decisions/0007-utc-bucketing-v0.md)); env-driven path discovery
    (`$CLAUDE_CONFIG_DIR`, `$XDG_CONFIG_HOME`, `$CODEX_HOME`, `$HOME`).
  - **Capabilities:** the full matrix in [`CAPABILITIES.md`](CAPABILITIES.md);
    the eight non-Claude/Codex providers are reserved ids with no adapter yet.
- **Downstream action:** A new consumer should target protocol **1.0.0**, decode
  open enums leniently (treat unknown provider ids / health / provenance values
  as pass-through, mirroring `#[serde(other)]`), and treat all additive struct
  fields as optional. Reuse `stackpulse-core` unchanged rather than reimplementing
  scanning.

### 2026-07-12 — Detection adapters + efficiency analytics (protocol 1.1.0)

- **Surface:** protocol + core + capabilities
- **Versions:** protocol **1.1.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:**
  - **Core:** registered **detection-only adapters** for the eight previously
    reserved providers (Antigravity, Copilot, Cursor, Devin, Grok, OpenCode,
    OpenRouter, Z.ai) — installed/auth detection (presence-only) + an honest
    capability matrix; cloud/API-key providers report `not_detected`. Every
    snapshot now lists all ten providers.
  - **Protocol 1.1.0 (additive):** new `DailyUsage` and `ProviderAnalytics`
    types and a new optional `ProviderUsage.analytics` field. Analytics carry
    measured cache savings (`Measured`), estimated burn rate + daily history
    (`LocalEstimate`), a 30-day cache-hit rate, and a `today_vs_avg_ratio`
    anomaly signal. `analytics` is `null` for detection-only providers.
- **Downstream action:** target protocol **1.1.0**; treat `analytics` (and its
  scalar fields) as optional/nullable. No 1.0.0 reader breaks — the field is
  ignored if unknown.

### 2026-07-12 — Needs-attention alerts (protocol 1.2.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.2.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:**
  - **Protocol 1.2.0 (additive):** new `Alert`, `AlertSeverity`, and `AlertKind`
    (open enum) types and a new `UsageSnapshot.alerts` list.
  - **Core:** derives alerts locally from each snapshot (usage-limit thresholds,
    degraded integration health, spend anomalies) — no network. Sorted
    most-severe first; empty when nothing needs attention.
- **Downstream action:** target protocol **1.2.0**; treat `alerts` as an
  optional/defaulted list and `AlertKind` as an open enum (unknown ⇒ `other`).
  The Chrome extension's "alerts" surface can consume this list directly.

### 2026-07-12 — Gemini provider (protocol 1.3.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.3.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no — `ProviderId` is an open enum (`#[serde(other)]`),
  so a new `gemini` value decodes as `unknown` in older readers.
- **Change:** added a `Gemini` variant to `ProviderId` and a detection-only
  Gemini adapter (Gemini CLI markers: `gemini` on `$PATH`,
  `~/.gemini/oauth_creds.json`). Snapshots now list eleven providers.
- **Downstream action:** target protocol **1.3.0**; keep decoding `ProviderId`
  leniently. Live Gemini quota (Google OAuth usage API) is future work.

### 2026-07-12 — Project Navigator (protocol 1.4.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.4.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:**
  - **Protocol 1.4.0 (additive):** new `Project`, `DiscoveredCommand`,
    `CommandSource` (open enum), and `CommandSafety` types; a new
    `CoreRequest::GetProjects { roots, max_depth }` op and a
    `CoreResponse::Projects { projects }` reply.
  - **Core:** `projects::discover` scans approved roots for project markers,
    detects frameworks / package manager / git, and discovers + safety-classifies
    commands. Read-only; never executes anything; never follows symlinks; only
    reads inside the approved roots.
- **Downstream action:** target protocol **1.4.0**; a Windows/Chrome client can
  issue `get_projects` with user-approved roots. Command *execution* is a client
  responsibility, gated by the `CommandSafety` classification the core provides
  (the core never runs commands).

> Live provider usage (Claude OAuth usage API) is implemented in the **macOS app
> layer**, not the portable core — it needs the Keychain + network, which stay
> platform-side. No protocol change; it populates the existing `LimitWindow`
> (`provenance: provider_reported`).

### 2026-07-12 — Agent Mission Control (protocol 1.5.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.5.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:**
  - **Protocol 1.5.0 (additive):** new `Mission` and `MissionStatus` (open enum)
    types and a new `UsageSnapshot.missions` list.
  - **Core:** `missions::discover` normalizes recently-active AI coding sessions
    (Claude, Codex) from local logs into missions (project/branch/model, last
    activity, token velocity, activity status). Read-only; no network; no
    process control — activity-based status only.
- **Downstream action:** target protocol **1.5.0**; treat `missions` as an
  optional/defaulted list and `MissionStatus` as an open enum. A Chrome/Windows
  client can render the same live-activity view.

### 2026-07-12 — Usage history (protocol 1.6.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.6.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:**
  - **Protocol 1.6.0 (additive):** new `HistoryPoint` type, `record_history` and
    `get_history` ops, and a `history` response.
  - **Core:** `history` module persists per-day, per-provider usage totals to a
    plain JSON store under a client-provided `data_dir` (seeded from the 30-day
    analytics, then accumulating beyond log rotation). No new dependencies (no
    SQLite) — revisits [ADR-0004](decisions/0004-storage-strategy.md); the data
    is tiny and this keeps the core C-toolchain-free and portable.
- **Downstream action:** target protocol **1.6.0**; a Windows/Chrome client can
  call `record_history`/`get_history` with its own writable `data_dir`.

### 2026-07-12 — BYOK provider balance (protocol 1.7.0)

- **Surface:** protocol
- **Versions:** protocol **1.7.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:** new `ProviderBalance` type and an optional `ProviderUsage.balance`
  field. It is filled by the **client layer** (BYOK key + the provider's balance
  API), NOT the portable core — the core always emits `balance: null`, keeping it
  offline. First fetchers: OpenRouter, LiteLLM.
- **Downstream action:** target protocol **1.7.0**; treat `balance` as optional.
  A Windows/Chrome client that stores API keys can populate it the same way the
  macOS app does.

### 2026-07-13 — Derived insights (protocol 1.8.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.8.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:** new `Insight` type with `InsightImpact` (`low|medium|high`) and
  `InsightKind` (open enum: `low_cache_efficiency`, `spend_anomaly`,
  `approaching_limit`, `idle_provider`, `cost_concentration`, `stalled_session`,
  `other`), plus an additive `UsageSnapshot.insights` list. Insights are derived
  **locally by the portable core** from the same scan (efficiency/cost/idle
  observations + possibly-stalled coding sessions) — no network. They are
  observations for the user to consider, distinct from `alerts`.
- **Downstream action:** target protocol **1.8.0**; treat `insights` as an
  additive, possibly-empty list and keep decoding `InsightKind`/`InsightImpact`
  with an unknown-value fallback. Any client linking the core gets insights for
  free.

### 2026-07-13 — Antigravity activity scanner (core behavior)

- **Surface:** core (no protocol change — still 1.8.0)
- **Versions:** protocol **1.8.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no
- **Change:** Antigravity moves from a detection-only adapter to a **full local
  activity scanner** (`providers::antigravity`). It reads
  `~/.gemini/antigravity/conversations/*.db` (a Windsurf/Codeium-style store) for
  conversation count, recency, and the Gemini model — recovered by a bounded
  byte-scan, **no SQLite dependency added** — and feeds in-progress conversations
  to Mission discovery. Token/cost stays absent (Antigravity accounts server-side).
  The engine now registers three full scanners (Claude, Codex, Antigravity) and
  eight detection-only providers; the total is still eleven. Antigravity's
  advertised capability matrix gains `auth_detection`, `local_session_history`,
  and `live_task_detection` = Supported.
- **Downstream action:** none required — any client linking the core gets the
  richer Antigravity `ProviderUsage` and Antigravity missions automatically. A
  client that hard-coded "Antigravity is detection-only" should drop that
  assumption.

### 2026-07-13 — Stack Health + Services (protocol 1.9.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.9.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:** two new capabilities.
  - **Stack Health** — `ProjectStack` / `Dependency` / `Advisory` /
    `DependencyStatus` (open enum) / `AdvisorySeverity` (open enum) /
    `StackSummary` types, plus `get_stack_health` → `stack_health`. The portable
    core produces an **offline dependency inventory** (parses npm + cargo
    manifests/lockfiles); it does NOT hit the network — latest-version / advisory
    enrichment is a **client-layer** concern (the macOS app uses the npm/crates
    registries + OSV), keeping the core free of a TLS/C crypto dependency that
    would break the Windows-cross gate.
  - **Services** — `RunningService` type + `get_services` → `services`. Detects
    locally-running dev servers by listening TCP port (via `lsof` on macOS) and
    matches them to approved project roots. Read-only.
- **Downstream action:** target protocol **1.9.0**; treat both responses as
  additive. A Windows/Linux client reusing the core gets the offline inventory
  and (on macOS) service detection; it would supply its own registry/OSV
  enrichment and its own port-enumeration for non-macOS.

### 2026-07-13 — Richer Missions (protocol 1.10.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.10.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:** two additive `Mission` fields — `changed_files` (relative paths from
  `git status` of the mission's project, capped) and `last_message_preview` (a
  short, single-line, sanitized snippet of the session's latest turn). Both
  computed locally by the core (git + the existing session-tail read); no network.
- **Downstream action:** target protocol **1.10.0**; treat both as additive and
  possibly-empty. Any client linking the core gets them for free.

---

### 2026-07-13 — Repository Radar (protocol 1.11.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.11.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:** `Recommendation` + `RadarCategory` / `RadarEffort` / `RadarRisk`
  (open enums) / `RadarReport` types, plus the `get_radar` op and `radar`
  response. The core discovers projects under the approved roots and runs
  deterministic rules over local facts (filesystem + `git`) to emit explainable,
  project-grounded recommendations — no network, no code execution. Rules
  aggregate across projects (one card each, with the affected list) to keep
  signal high. Any client linking the core gets the radar for free.
- **Downstream action:** target protocol **1.11.0**; `get_radar` is optional and
  the report's `recommendations` may be empty. Category/effort/risk are open
  enums — treat unknown values as a passthrough string.

---

### 2026-07-13 — Scope Guard on missions (protocol 1.12.0)

- **Surface:** protocol + core
- **Versions:** protocol **1.12.0** / core **0.1.0** / manifest *(not yet defined)*
- **Breaking for downstream:** no (purely additive)
- **Change:** `ScopeFlag` + `ScopeFlagKind` (open enum) / `ScopeSeverity` types
  and an additive `Mission.scope_flags` field. The core classifies each mission's
  existing `changed_files` into risk categories (secrets, migrations,
  dependencies, lockfiles, security code, tests, build config) by path pattern —
  no diff content, no file reads, no network. Any client linking the core gets
  the flags on missions for free.
- **Downstream action:** target protocol **1.12.0**; `scope_flags` may be empty.
  `kind`/`severity` are open enums — treat unknown values as passthrough strings.

---

## Pending / anticipated (not yet shipped)

These are flagged so downstream repos can plan. They are **not** implemented and
carry no version yet.

- **Claude live usage API.** Would move Claude's `session_limits` /
  `weekly_limits` / `credits_and_spend` capabilities from `unavailable` toward
  `supported` and introduce provider-reported limit windows. Additive; expected
  non-breaking for the protocol.
- **Signed compatibility manifest.** Introduces a new, independent manifest
  version line and a verification/validation pipeline (see
  [`COMPATIBILITY.md`](COMPATIBILITY.md)).
- **Local history storage (SQLite).** A core-level, client-visible addition (new
  query ops likely). Would be a protocol addition recorded here when designed
  (see [ADR-0004](decisions/0004-storage-strategy.md)).
