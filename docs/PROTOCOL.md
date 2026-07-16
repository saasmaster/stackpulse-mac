# Protocol

The `stackpulse-protocol` crate defines the versioned, platform-neutral wire
contract shared by every StackPulse surface: the Rust core, the macOS app (over
the C ABI), the `stackpulse` CLI, and — in the future — a Chrome
native-messaging host and a Windows client.

- **Current version:** `PROTOCOL_VERSION = 1.14.0`. Additive history (older
  readers keep parsing):
  - **1.3.0** — added a `Gemini` variant to the (open) `ProviderId` enum; the
    engine now lists eleven providers.
  - **1.4.0** — Project Navigator: `Project`, `DiscoveredCommand`,
    `CommandSource` (open enum), `CommandSafety` types + the `get_projects` op
    and `projects` response.
  - **1.5.0** — Agent Mission Control: `Mission` + `MissionStatus` (open enum)
    types and the `UsageSnapshot.missions` list.
  - **1.6.0** — Usage history: `HistoryPoint` type + the `record_history` /
    `get_history` ops and the `history` response.
  - **1.7.0** — BYOK balances: `ProviderBalance` type + the optional
    `ProviderUsage.balance` field (filled by the client layer, not the core).
  - **1.8.0** — Insights: `Insight` + `InsightImpact` / `InsightKind` (open enum)
    types and the `UsageSnapshot.insights` list (derived intelligence, computed
    locally by the core).
  - **1.9.0** — Stack Health + Services: `ProjectStack` / `Dependency` /
    `Advisory` / `DependencyStatus` / `AdvisorySeverity` / `StackSummary` types +
    the `get_stack_health` op and `stack_health` response; `RunningService` +
    the `get_services` op and `services` response. The core produces an offline
    dependency inventory and detects running dev servers by listening port;
    latest-version / advisory enrichment happens in the client layer (network).
  - **1.10.0** — richer Missions: two additive `Mission` fields —
    `changed_files` (from `git status` of the mission's project) and
    `last_message_preview` (a short, local, sanitized snippet of the latest turn).
  - **1.11.0** — Repository Radar: `Recommendation` + `RadarCategory` /
    `RadarEffort` / `RadarRisk` (open enums) / `RadarReport` types + the
    `get_radar` op and `radar` response. The core discovers projects under the
    approved roots, then emits deterministic, explainable, project-grounded
    recommendations from local facts only (filesystem + `git`, no network).
  - **1.12.0** — Scope Guard: `ScopeFlag` + `ScopeFlagKind` (open enum) /
    `ScopeSeverity` types + an additive `Mission.scope_flags` field. The core
    classifies a mission's already-gathered `changed_files` into risk categories
    (secrets, migrations, dependencies, lockfiles, security code, tests, build
    config) by path pattern — no diff content, no file reads, no network.
  - **1.13.0** — Project usage: `ProjectUsage` type + the `get_project_usage` op
    and `project_usage` response. The core attributes local spend to the project
    each session ran in by grouping session records on their recorded working
    directory, reusing `SpendWindow` ("today" / "last_30_days"). Offline; costs
    remain local estimates.
  - **1.14.0** — Checkpoints: `Checkpoint` type + the `create_checkpoint` /
    `list_checkpoints` ops and the `checkpoints` response (with an honest `note`
    for the "nothing to capture" cases). Capture is **non-destructive** — the core
    uses `git stash create` (which writes a commit object without touching the
    working tree, the index, or HEAD) and keeps it alive under
    `refs/stackpulse/checkpoints/*`. The core never restores; it only reports
    `restore_command` for the client to gate behind a confirmation.
  - **1.1.0** — `ProviderAnalytics` / `DailyUsage` types and the optional
    `ProviderUsage.analytics` field.
  - **1.2.0** — `Alert` / `AlertSeverity` / `AlertKind` types and the
    `UsageSnapshot.alerts` list (needs-attention, derived locally).
- **Transport:** JSON strings. A client sends a JSON `CoreRequest`; the core
  returns a JSON `CoreResponse`. That is the entire surface (see
  [ADR-0003](decisions/0003-rust-core-c-abi-bridge.md)).
- **Encoding rules:** enums are `snake_case`; request and response envelopes are
  serde **internally-tagged** (a `tag` field selects the variant); additive
  fields are `#[serde(default)]` for forward compatibility.

## Versioning and compatibility

`PROTOCOL_VERSION` is independent of the app, core, and (future) compatibility-
manifest versions (see [ADR-0006](decisions/0006-independent-version-lines.md)).

- **Breaking change** (rename/remove a field, change a type, change tagging):
  bump the protocol **major** and record it in this file and in
  [`CROSS_REPO_CHANGELOG.md`](CROSS_REPO_CHANGELOG.md).
- **Additive change** (new field, new enum variant): does not require a major
  bump, but new struct fields **must** be `#[serde(default)]` and new open enums
  keep an unknown-catch variant, so an older peer keeps parsing a newer payload.

### The forward-compatibility rule

Two mechanisms make "newer core, older client" safe:

- **`ProviderId`** carries `#[serde(other)] Unknown`, so an unrecognized provider
  id deserializes to `Unknown` instead of failing.
- Every optional/collection field on `ProviderUsage`, and `detected_version` on
  `ProviderStatus`, is `#[serde(default)]`, so missing fields fill in defaults.

On the Swift side the same principle is applied by decoding open enums
(`health`, `provenance`, `provider`) as plain `String` and interpreting them in
the view layer — a value the app has never seen is displayed rather than fatal.

> **Producers should be strict, consumers lenient.** Emit the current shape;
> tolerate unknown keys and unknown enum values when reading.

---

## Envelope: `CoreRequest`

Internally tagged by **`op`** (`#[serde(tag = "op", rename_all = "snake_case")]`).

| `op` | Meaning | Extra fields |
| --- | --- | --- |
| `ping` | Liveness + version report. | — |
| `get_provider_status` | Cheap detection only (installed / auth / health). No log scanning. Suitable for frequent polling. | — |
| `get_usage_snapshot` | Full scan of local provider data. | `providers` (optional array of `ProviderId`; if present, only those are scanned) |
| `get_projects` *(1.4.0)* | Discover projects + commands under approved roots. | `roots` (array of absolute paths), `max_depth` (optional int) |
| `record_history` *(1.6.0)* | Fold today's usage into the durable store, then return history. | `data_dir` (writable abs path), `days` (optional int) |
| `get_history` *(1.6.0)* | Read accumulated history without recording. | `data_dir`, `days` (optional int) |

Examples:

```json
{"op":"ping"}
```

```json
{"op":"get_provider_status"}
```

```json
{"op":"get_usage_snapshot"}
```

```json
{"op":"get_usage_snapshot","providers":["claude","codex"]}
```

```json
{"op":"get_projects","roots":["/Users/me/code"],"max_depth":4}
```

## Envelope: `CoreResponse`

Internally tagged by **`kind`** (`#[serde(tag = "kind", rename_all = "snake_case")]`).

| `kind` | Payload |
| --- | --- |
| `pong` | `protocol_version` (`Version`), `core_version` (string) |
| `provider_status` | `providers`: array of `ProviderStatus` |
| `usage_snapshot` | the fields of `UsageSnapshot`, flattened next to `kind` |
| `projects` *(1.4.0)* | `projects`: array of `Project` |
| `history` *(1.6.0)* | `points`: array of `HistoryPoint` (date asc) |
| `error` | the fields of `CoreError` (`code`, `message`), flattened next to `kind` |

Because `usage_snapshot` and `error` are newtype variants that wrap a struct,
serde **flattens** that struct's fields alongside the `kind` tag. That is why the
Swift decoder can decode a `UsageSnapshot` straight out of the response, simply
ignoring the extra `"kind":"usage_snapshot"` key.

### `pong`

```json
{
  "kind": "pong",
  "protocol_version": { "major": 1, "minor": 0, "patch": 0 },
  "core_version": "0.1.0"
}
```

### `error`

```json
{
  "kind": "error",
  "code": "bad_request",
  "message": "could not parse request: expected value at line 1 column 1"
}
```

---

## Types

### `Version`

A `const`-friendly semantic version. `PROTOCOL_VERSION` is `1.10.0`.

```json
{ "major": 1, "minor": 0, "patch": 0 }
```

### `ProviderId` (open enum)

Serialized as a lowercase/`snake_case` string. Known values:

`antigravity`, `claude`, `codex`, `copilot`, `cursor`, `devin`, `grok`,
`opencode`, `openrouter`, `zai`. Any unrecognized value deserializes to the
catch-all `unknown`.

### `Capability` (enum)

A single fine-grained capability. Integrations advertise a **matrix** of these,
not one boolean. Serialized as `snake_case`:

`installed_app_detection`, `version_detection`, `auth_detection`,
`session_limits`, `weekly_limits`, `credits_and_spend`, `local_cost_scan`,
`model_breakdown`, `cache_metrics`, `local_session_history`,
`live_task_detection`, `completion_detection`, `waiting_for_input_detection`,
`tool_call_visibility`, `project_association`, `conversation_preview`, `reply`,
`approve_reject`, `stop`, `resume`, `deep_link`, `remote_task_state`.

### `CapabilityState` (enum)

Whether a capability is actually available right now:

- `supported` — implemented and currently working.
- `unavailable` — implementable, but a precondition is missing (e.g. not
  authenticated, or it needs network and we are offline / it is not wired yet).
- `unsupported` — the provider does not expose this; do not pretend otherwise.

### `IntegrationHealth` (open enum)

Health of an integration:

`fully_supported`, `partially_supported`, `app_version_untested`,
`authentication_changed`, `session_schema_changed`, `endpoint_changed`,
`metrics_unavailable`, `temporarily_broken`, `discontinued`,
`user_action_required`, `not_detected`.

### `Provenance` (enum)

How a numeric value was obtained — surfaced so users never mistake an estimate
for a fact:

- `measured` — directly measured from local logs (e.g. summed tokens).
- `provider_reported` — reported by the provider's own state/API (e.g. Codex
  rate-limit windows).
- `local_estimate` — computed locally from measured inputs and the pricing table
  (an estimate; all cost figures are this).
- `heuristic` — a suggestion, not a hard number.

### `TokenTotals`

Token categories kept separate so cache economics are visible. All fields are
`u64` and default to `0`.

```json
{
  "input_tokens": 120000,
  "output_tokens": 8200,
  "cache_creation_tokens": 15000,
  "cache_read_tokens": 240000,
  "reasoning_tokens": 0
}
```

`input_tokens` is the **exclusive** (fresh, uncached) prompt count in this
protocol. Providers normalize into this convention before it reaches the wire
(Claude already excludes cache; Codex is normalized to `input - cached`).

### `SpendWindow`

Aggregated spend + tokens over a named window. `label` is `today`, `yesterday`,
or `last_30_days`. `estimated_cost_usd` is `null` when no priceable model was
found.

```json
{
  "label": "today",
  "tokens": {
    "input_tokens": 120000, "output_tokens": 8200,
    "cache_creation_tokens": 15000, "cache_read_tokens": 240000,
    "reasoning_tokens": 0
  },
  "estimated_cost_usd": 1.83,
  "records": 42
}
```

### `ModelUsage`

Per-model breakdown within the 30-day window. Same shape as `SpendWindow` but
keyed by `model`.

```json
{
  "model": "claude-sonnet-4",
  "tokens": {
    "input_tokens": 90000, "output_tokens": 6000,
    "cache_creation_tokens": 12000, "cache_read_tokens": 180000,
    "reasoning_tokens": 0
  },
  "estimated_cost_usd": 1.20,
  "records": 30
}
```

### `DailyUsage` *(since 1.1.0)*

One day of usage for daily-history charts. `estimated_cost_usd` is `null` when no
priceable model ran that day.

```json
{ "date": "2026-07-12", "tokens": { "input_tokens": 50000, "output_tokens": 4000, "cache_creation_tokens": 0, "cache_read_tokens": 900000, "reasoning_tokens": 1200 }, "estimated_cost_usd": 0.42, "records": 18 }
```

### `ProviderAnalytics` *(since 1.1.0)*

Derived efficiency analytics over the 30-day window, computed locally from
measured tokens. `cache_savings_usd` is **measured** (a token-count difference);
`burn_rate_usd_per_day` and the daily costs are **`local_estimate`s** (they use
the same price table as the spend windows). `daily` always has 30 entries
(zeros filled), oldest → newest.

```json
{
  "cache_savings_usd": 223788.9,
  "burn_rate_usd_per_day": 1233.34,
  "cache_hit_rate": 0.971,
  "today_vs_avg_ratio": 0.28,
  "daily": [ /* 30 DailyUsage objects, oldest -> newest */ ]
}
```

Any of the scalar fields may be `null` when there is not enough data (e.g. no
priceable cache activity ⇒ `cache_savings_usd: null`; zero average ⇒
`today_vs_avg_ratio: null`). `today_vs_avg_ratio` well above `1.0` is a spend
anomaly worth surfacing.

### `LimitWindow`

A live limit window reported by the provider (e.g. Codex 5-hour / weekly),
captured from local logs with no network call where possible.

```json
{
  "label": "5h",
  "used_percent": 37.4,
  "window_minutes": 300,
  "resets_at_unix": 1779942915,
  "provenance": "provider_reported"
}
```

### `ProviderUsage`

Everything known about one provider at snapshot time. Note `capabilities` is an
array of `[capability, state]` **pairs** (serde serializes a `(Capability,
CapabilityState)` tuple as a two-element JSON array).

```json
{
  "provider": "codex",
  "display_name": "Codex",
  "health": "fully_supported",
  "installed": true,
  "authenticated": true,
  "detected_version": "1.2.3",
  "plan_hint": "plus",
  "windows": [
    { "label": "today", "tokens": { "input_tokens": 50000, "output_tokens": 4000, "cache_creation_tokens": 0, "cache_read_tokens": 30000, "reasoning_tokens": 1200 }, "estimated_cost_usd": 0.11, "records": 18 },
    { "label": "yesterday", "tokens": { "input_tokens": 0, "output_tokens": 0, "cache_creation_tokens": 0, "cache_read_tokens": 0, "reasoning_tokens": 0 }, "estimated_cost_usd": null, "records": 0 },
    { "label": "last_30_days", "tokens": { "input_tokens": 900000, "output_tokens": 70000, "cache_creation_tokens": 0, "cache_read_tokens": 600000, "reasoning_tokens": 21000 }, "estimated_cost_usd": 2.04, "records": 260 }
  ],
  "models": [
    { "model": "gpt-5-codex", "tokens": { "input_tokens": 900000, "output_tokens": 70000, "cache_creation_tokens": 0, "cache_read_tokens": 600000, "reasoning_tokens": 21000 }, "estimated_cost_usd": 2.04, "records": 260 }
  ],
  "limits": [
    { "label": "5h", "used_percent": 37.4, "window_minutes": 300, "resets_at_unix": 1779942915, "provenance": "provider_reported" },
    { "label": "weekly", "used_percent": 12.9, "window_minutes": 10080, "resets_at_unix": 1780529715, "provenance": "provider_reported" }
  ],
  "capabilities": [
    ["installed_app_detection", "supported"],
    ["version_detection", "supported"],
    ["auth_detection", "supported"],
    ["local_cost_scan", "supported"],
    ["model_breakdown", "supported"],
    ["cache_metrics", "supported"],
    ["local_session_history", "supported"],
    ["session_limits", "supported"],
    ["weekly_limits", "supported"],
    ["reply", "unsupported"],
    ["approve_reject", "unsupported"],
    ["stop", "unsupported"],
    ["resume", "unsupported"],
    ["remote_task_state", "unsupported"],
    ["conversation_preview", "unsupported"],
    ["credits_and_spend", "unavailable"],
    ["project_association", "unavailable"]
  ],
  "notes": [],
  "analytics": { "cache_savings_usd": 653.67, "burn_rate_usd_per_day": 7.57, "cache_hit_rate": 1.0, "today_vs_avg_ratio": 0.2, "daily": [ /* 30 DailyUsage */ ] }
}
```

`analytics` *(since 1.1.0)* is a `ProviderAnalytics` or `null` — it is `null`
for detection-only providers with no measured usage.

### `Alert` *(since 1.2.0)*

A needs-attention item derived **locally** by the core from the snapshot (no
network). `UsageSnapshot.alerts` is sorted most-severe first.

- `severity`: `info` | `warning` | `critical`.
- `kind` (open enum; unknown ⇒ `other`): `usage_threshold` | `limit_reset_soon`
  | `integration_issue` | `spend_anomaly` | `other`.
- `id` is a stable key (`provider:kind:discriminator`) for dedup / acknowledge.

```json
{ "id": "Codex:usage:5h", "provider": "codex", "severity": "critical", "kind": "usage_threshold",
  "title": "Codex 5h limit at 96%", "detail": "The 5h window is 96% consumed — resets in 1h 12m.",
  "created_at_unix": 1784000000 }
```

Default thresholds: usage ≥ 90% ⇒ critical, ≥ 75% ⇒ warning; degraded
integration health ⇒ warning/critical; today's spend ≥ 2.5× the 30-day daily
average ⇒ warning. An empty `alerts` array means nothing needs attention.

### `Insight` *(since 1.8.0)*

A derived, actionable observation or recommendation — efficiency, cost, idle
resources, a possibly-stalled session — computed **locally** by the core. Distinct
from an `Alert` (a needs-attention condition): insights are for the user to
consider, never auto-acted upon. `UsageSnapshot.insights` is sorted most-useful
first.

- `impact`: `low` | `medium` | `high` (drives ordering / accent).
- `kind` (open enum; unknown ⇒ `other`): `low_cache_efficiency` | `spend_anomaly`
  | `approaching_limit` | `idle_provider` | `cost_concentration` |
  `stalled_session` | `other`.
- `provider` is optional (the provider the insight is about, when applicable).
- `metric` is an optional highlighted figure (e.g. `"42% cache"`, `"3.1× avg"`).
- `id` is a stable key (`insight:kind:discriminator`) for dedup / ordering.

```json
{ "id": "insight:low_cache:claude", "impact": "medium", "kind": "low_cache_efficiency",
  "provider": "claude", "title": "Low cache efficiency on Claude",
  "detail": "Only 42% of your Claude input is served from cache — keeping prompts and context stable raises this and lowers cost.",
  "metric": "42% cache", "created_at_unix": 1784000000 }
```

An empty `insights` array is normal (nothing worth surfacing this scan).

### `UsageSnapshot`

The top-level object every UI surface renders — one scan produces one snapshot.
As a `usage_snapshot` response, these fields are flattened next to `"kind"`.

```json
{
  "kind": "usage_snapshot",
  "protocol_version": { "major": 1, "minor": 2, "patch": 0 },
  "core_version": "0.1.0",
  "generated_at_unix": 1784000000,
  "bucket_date_utc": "2026-07-12",
  "providers": [ /* ProviderUsage objects */ ],
  "alerts": [ /* Alert objects, most severe first (since 1.2.0) */ ],
  "missions": [ /* Mission objects, most-recently-active first (since 1.5.0) */ ],
  "insights": [ /* Insight objects, most-useful first (since 1.8.0) */ ],
  "pricing_note": "Costs are local estimates from an embedded price table (list prices as of 2026-07); verify against your provider billing."
}
```

### `Mission` *(since 1.5.0)*

An observed AI coding session, normalized from local logs (no network, no
process control). `status` ∈ `active | idle | recent | stalled | unknown`
(open enum) — activity-based, derived from how long since the last log event.

```json
{ "provider": "claude", "session_id": "…", "status": "active",
  "project_path": "/Users/me/code/app", "project_name": "app", "branch": "main",
  "model": "claude-opus-4-8", "started_at_unix": 1784000000,
  "last_activity_unix": 1784003600, "message_count": 42,
  "last_activity": "Using Edit", "tokens_last_hour": 1500000 }
```

`bucket_date_utc` is disclosed so the UI can label windows as UTC-based in this
version (see [ADR-0007](decisions/0007-utc-bucketing-v0.md)).

### `ProviderStatus`

The cheap per-provider result of `get_provider_status`, without a full scan.
`detected_version` is `#[serde(default)]` (emitted as `null` when unknown).

```json
{
  "provider": "claude",
  "display_name": "Claude",
  "installed": true,
  "authenticated": true,
  "health": "fully_supported",
  "detected_version": null
}
```

### `Project` and `DiscoveredCommand` *(since 1.4.0)*

A `projects` response carries `Project` objects. The core discovers these by
reading files only — it **never executes** anything; command *execution* is the
client's responsibility, gated by the `safety` classification.

`CommandSource` (open enum): `package_script | makefile | justfile | taskfile |
compose_service | readme | framework_convention | other`.
`CommandSafety`: `read_only | local_dev | modifies_files | installs_deps |
changes_database | network | destructive`.

```json
{
  "name": "stackpulse-mac",
  "path": "/Users/me/code/stackpulse-mac",
  "markers": ["git", "rust"],
  "frameworks": ["serde"],
  "package_manager": "cargo",
  "git_branch": "main",
  "git_remote": null,
  "last_modified_unix": 1784000000,
  "commands": [
    { "label": "Test", "command": "make test", "cwd": "/Users/me/code/stackpulse-mac", "source": "makefile", "safety": "read_only", "confidence": 0.9, "raw_key": "test" }
  ],
  "warnings": ["No git remote"]
}
```

### `CoreError` and `ErrorCode`

Structured, stable error codes for cross-repo interoperability.

`ErrorCode` values (`snake_case`): `bad_request`, `provider_scan_failed`,
`permission_denied`, `internal`.

```json
{ "code": "bad_request", "message": "could not parse request: ..." }
```

As an envelope, the fields flatten under `"kind":"error"` (see the `error`
example above).

---

## Full round-trip example

Request:

```json
{"op":"ping"}
```

Response:

```json
{"kind":"pong","protocol_version":{"major":1,"minor":0,"patch":0},"core_version":"0.1.0"}
```

You can reproduce every shape here from a real machine:

```sh
./target/release/stackpulse request '{"op":"ping"}'
./target/release/stackpulse request '{"op":"get_provider_status"}'
./target/release/stackpulse snapshot --json
```

## Robustness notes

- **Serialization never fails silently.** The core serializes its own types
  (which cannot fail); if it somehow could, it falls back to a hand-written
  `{"kind":"error","code":"internal", ...}` string.
- **Bad input is structured, not fatal.** Unparseable request JSON returns
  `{"kind":"error","code":"bad_request", ...}` rather than crashing.
- **Panics are contained.** At the FFI boundary a panic is caught and converted
  to a JSON error; inside a scan a panic is downgraded to a degraded
  `ProviderUsage`.
