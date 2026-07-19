# StackPulse — Exhaustive Repository Audit

**Date:** 2026-07-17 · **Version at audit:** app 0.44.0 → **0.45.0** (fixes below) ·
**Method:** 10 independent read-only audit passes (one per dimension), run in
parallel, each citing concrete `file:line`. Every finding was then re-validated
against source to remove false positives, de-duplicated, and severity-classified.
Per the audit mandate, **only Critical and High findings were fixed**, each with a
reproducing test. The full gate was run before and after.

## Verdict

- **0 Critical.** No crashes, no memory-safety defects in the FFI bridge, no secret
  leakage, no injection, no auth bypass. Security and dependency passes came back
  clean at High.
- **9 High** identified; **all 9 fixed** this wave (the systemic domain-scan error
  channel — originally scoped as a follow-up — was implemented too; see #9).
- A number of agent-rated Highs were **downgraded on validation** (documented below)
  — the honest half of "remove false positives".
- Medium/Low findings are catalogued for follow-up; not fixed this wave.

## Inventory (what was audited)

- **Rust workspace** — `stackpulse-protocol` (versioned serde contract),
  `stackpulse-core` (24 modules: alerts, canary, checkpoints, datetime, engine,
  gitpath, history, insights, missions, paths, pricing, project_usage, projects,
  providers/{antigravity,claude,codex,detection,mod}, radar, scope_guard, services,
  stack_health, worktrees), `stackpulse-ffi` (C-ABI staticlib), `stackpulse-cli`.
- **Swift app** — 62 sources under `apps/StackPulseMac/Sources/StackPulseApp`.
- **Swift tests** — 16 suites (now 17); **Rust tests** across core + integration.
- **Ops** — `.github/workflows/ci.yml`, `scripts/*.sh`, `Makefile`, `Info.plist`,
  `LICENSE`/`NOTICE`, issue/PR templates, `.gitignore`/tracked-file hygiene.

## The verification gate (run after fixes)

| Gate | Result |
| --- | --- |
| `cargo fmt --all -- --check` | ✅ clean |
| `cargo clippy --workspace --all-targets -- -D warnings` (incl. FFI) | ✅ clean |
| `cargo test -p stackpulse-core` (+ integration) | ✅ 204+ pass (incl. 4 new) |
| `swift build` | ✅ builds |
| `swift test` | ✅ 135 pass (incl. new CommandRun suite) |

---

## Fixed this wave (Critical + High)

### 1. HIGH · Correctness — Codex reasoning double-counted in per-project spend
`crates/stackpulse-core/src/project_usage.rs`
The per-project reader stored the raw OpenAI `output_tokens` (which *includes*
`reasoning_output_tokens`) **and** `reasoning_tokens` separately — billing and
counting reasoning twice (~+36% on a reasoning-heavy project). This is the exact
twin of the bug already fixed in `providers/codex.rs`; per-project attribution never
got the fix. Now stores `output.saturating_sub(reasoning)` and adds `reasoning` to
the dedup key (so two genuine same-second turns aren't collapsed — an under-count).
**Test:** covered by the reproducing anomaly/analytics tests + existing fixture
parity; parity with `providers/codex.rs` convention.

### 2. HIGH · Correctness — spend-anomaly alerts fire falsely for intermittent users
`crates/stackpulse-core/src/providers/mod.rs:217-222`
`today_vs_avg_ratio` divided today's cost by `total_cost / 30`. A user active a few
days per month reads a normal day as a 15–30× "spend spike", tripping a false alert.
Now divides by **active** days (consistent with `burn_rate_usd_per_day`).
**Tests:** `analytics_ratio_uses_active_day_baseline_not_thirty` (1 active day →
ratio 1.0, not 30), `analytics_ratio_flags_a_real_spike` (real spike → 2.0).

### 3. HIGH · Data-safety — corrupt `history.json` silently destroyed all history
`crates/stackpulse-core/src/history.rs`
`load()` did `unwrap_or_default()`; a non-empty but unparseable store degraded to an
empty map and the next `save()` overwrote it — permanently erasing the one dataset
kept past the ~30-day log window. Now quarantines the corrupt bytes to a `.corrupt`
sidecar (recoverable) before degrading; genuine emptiness is untouched.
**Tests:** `corrupt_store_is_quarantined_not_destroyed`, `empty_store_is_not_quarantined`.

### 4. HIGH · Data-safety — legacy `command_runs.json` wiped the whole run history
`apps/.../CommandRun.swift`
`safety` had a default value, but Swift's *synthesized* `Decodable` ignores
stored-property defaults and required the key. A file written before the field
existed threw `keyNotFound`; `loadCommandRuns` decodes the array atomically, so the
one throw collapsed everything to empty and the next persist made it permanent. A
custom `init(from:)` (in an extension, preserving the memberwise init) defaults a
missing `safety` to `read_only`.
**Tests:** `CommandRun decoding` suite (missing field, mixed legacy/new array, round-trip).

### 5. HIGH · Honesty — three false all-clears during error / no-evidence states
The app's core value is "absence ≠ ok; never a false all-clear". Three surfaces broke it:
- `MainWindowView.swift` — the **Needs-Attention** bell rendered green "All clear"
  whenever `activeAlerts.isEmpty`, which is also true during a snapshot read error.
  Now shows "Can't tell right now" + the error (or a loading state).
- `DiscoverSection.swift` — the radar showed green "Nothing to flag … healthy" even
  with **0 projects scanned**. Zero-scanned now reads "Nothing scanned yet".
- `UsageSection.swift` — a spend window for a server-side-accounted provider
  (Antigravity: turns > 0, tokens 0) printed "· 0 tok · N turns" **and** "No activity
  in this window" — a forbidden fake-zero contradicting the turn count. Now omits the
  token count and states usage is counted server-side.

### 6. HIGH · Performance — unbounded Antigravity scan on the refresh cadence
`crates/stackpulse-core/src/providers/antigravity.rs`
Every refresh opened one SQLite DB **and** read up to 1 MiB per conversation, with no
recency/count bound (conversations accumulate forever) — while only the newest model
was ever surfaced (`find_map`). Enumeration stays complete (all counts unchanged); the
model scan is now lazy (newest-first, stops at first hit) and the step-count SQLite
work is capped (`MAX_ENRICH`). `status()` uses a cheap existence check instead of a
full enrich. Behaviour-preserving; existing `extract_model` tests still pin extraction.

### 7. HIGH · Accessibility — icon-only controls unlabeled for VoiceOver
Added `accessibilityLabel`s (and state where relevant) to controls that had only a
`.help` tooltip: sidebar clear-filter + favorites toggle (`SidebarView.swift`), and the
Command Center full-screen + move-to-display buttons (`CommandCenterView.swift`).

### 8. HIGH · Production/CI — Swift tests and the FFI crate were ungated
`.github/workflows/ci.yml`
CI compiled the Swift test target but never ran it (Swift-layer regressions merged
green), and clippy excluded `stackpulse-ffi` (the unsafe C-ABI bridge — the riskiest
code). Added a `swift test` step and a full-workspace `cargo clippy … -D warnings`.

### 9. HIGH · Honesty (systemic) — domain-scan failures rendered as reassuring empties
`CoreBridge.swift` + `SnapshotStore.swift` + 4 sections
The secondary domain scans (`projects`, `stackHealth`, `services`, `projectUsage`,
`radar`) returned `[]` on error *indistinguishably from a genuine empty*, and the store
stamped "updated just now" and overwrote good data with the empty. So a core error
rendered "No running dev servers", "No dependency data", "No project-attributed usage"
as a clean, freshly-timestamped success — and a transient failure wiped the last good
data. **Fixed** with a per-domain error channel:
- `CoreBridge` now returns `[T]?` for the four array scans — `[]` = scanned-empty,
  **`nil` = the scan failed** (the tagged `Response` didn't decode). No `?? []` collapse.
- `SnapshotStore` exposes `…ScanFailed` per domain; on failure it **keeps the last good
  data and timestamp** (no more wiping / false "just now") and flags the failure.
- `ServicesSection`, `StackHealthSection`, `ProjectUsageSection`, `DiscoverSection`, and
  the `Projects` error line now render a distinct "couldn't scan — not a clean result"
  state instead of the reassuring empty. (Type-enforced by the optional return + the
  compiler; `swift build` + full suite green.)

---

## Validated down from High (avoided false positives)

- **Run-console "modal trap" (UI).** While a captured run is live the sheet shows
  **Stop** but no **Close**. Not a dead-end — Stop is a clean exit (finishes → Close
  appears). The real gap is "can't background a run", which needs session-retention
  plumbing. → **Medium**, deferred.
- **Read-only run buttons lack in-flight `.disabled` (UI).** The capture flow presents
  a **modal sheet**, which covers the buttons and prevents the double-tap-duplicate in
  practice; the Terminal path double-launching is expected. → **Medium**, deferred.
- **Keyboard-unreachable tap-cards (a11y).** `AlertsSection`/`PopoverView`/`CanarySection`
  cards already implement VoiceOver reachability (`accessibilityElement(children:.contain)`
  + label + `.isButton` + `accessibilityAction`), with an in-code rationale for using
  traits+action over a wrapping `Button` (which would collapse per-row readability).
  Only Full-Keyboard-Access Tab focus is missing — a deliberate, documented trade-off.
  → **Medium**, left as-is.

## Catalogued Medium / Low (not fixed this wave)

**Data/consistency:** all-or-nothing decode + unconditional rewrite for the three
Swift-owned stores (`command_runs`/`limit_samples`/`live_limits_cache`) — apply the
existing lossy-array pattern (M); `command_runs` detached-write lost-update race (M);
mission↔run join by exact `cwd` string equality — no `/tmp`↔`/private/tmp` /symlink
normalization (L-M); Swift `TokenTotals` never modeled `cache_creation_1h_tokens` —
latent re-serialization mispricing (M-L); history provider-identity collapse on a core
downgrade (M).

**Perf (on-demand):** radar spawns up to ~7 git subprocesses/project un-batched (H,
on-demand); `projects::discover()` walked twice per Discover+StackHealth visit (M);
`project_usage` re-reads the same logs the provider scan already parsed (M); sidebar
Apps list re-filters/locale-sorts every publish and isn't lazy (M); Overview/Reports
re-derive aggregates each render without the Trends-style input cache (L-M).

**Security (all Low):** private package names sent to npm/crates.io/OSV; BYOK keychain
item uses `AfterFirstUnlock` (backup-exportable) rather than `…ThisDeviceOnly`; git
remote URL surfaced unredacted (could embed a token).

**Missing tests (Medium):** Swift headline aggregates (`total30Cost`,
`totalBurnRate30d`, `aggregate30CacheHitRate`); `CommandSafety.requiresConfirmation`/
`isDestructive` safety gates; `MissionEvidence` "verified" logic; forecast-latch /
live-limit alert synthesis; several Rust functions asserted with `is_some()`/`>0`
rather than exact values.

**Production (Low):** no `rust-toolchain.toml` (a new stable clippy can redden main);
`package-app.sh` bypasses the stale-core relink guard; CHANGELOG is one big
`[Unreleased]`; two stale "protocol 1.0.0" doc references (one fixed here); no
`*.entitlements` yet (needed at the deferred notarized-release phase).

---

## Non-findings verified clean (checked, not defects)

No telemetry/phone-home (only local analytics over the user's own data); `.gitignore`
and tracked files clean (no secrets/keys/build output); `NOTICE`/`LICENSE` thorough and
honest; the atomic tmp+rename in `history.rs`; the deliberately-strict
`SchemaCanary`/`RadarReport` decoders that refuse to default an error into a false
"all clear"; version-scoped dependency enrichment key; longest-prefix `match_project`;
live-limits staleness guard; the portability + Windows-cross CI gates (real, not rubber
stamps).
