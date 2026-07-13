# Capability Matrix

StackPulse describes each integration as a **matrix of fine-grained
capabilities**, not a single "supported/unsupported" boolean. This is a
deliberate honesty mechanism: a provider can have excellent local cost
visibility while offering no remote control, and the UI should say exactly that.

Every `(Capability, CapabilityState)` pair a provider advertises is carried in
its `ProviderUsage.capabilities` field (see [`PROTOCOL.md`](PROTOCOL.md)). This
document renders the v0.1.0 matrix for all eleven providers.

## Legend

| Symbol | `CapabilityState` | Meaning |
| --- | --- | --- |
| **S** | `supported` | Implemented and currently working. |
| **U** | `unavailable` | Implementable, but a precondition is missing (not authenticated, needs network, or not wired yet). |
| **X** | `unsupported` | The provider does not expose this; StackPulse will not fake it. |
| **—** | *(not advertised)* | Not part of this provider's matrix in v0.1.0. |

## v0.1.0 reality check

All eleven providers are registered in the engine and appear in every snapshot.

- **Claude** and **Codex** have **full local cost scanners** — their cells
  reflect exactly what the adapter code advertises, and their usage/cost/cache
  numbers are read from real local logs.
- The other nine — **Antigravity, GitHub Copilot, Cursor, Devin, Gemini, Grok,
  OpenCode, OpenRouter, Z.ai** — ship as **detection-only adapters** (one
  data-driven `DetectableProvider`). They honestly report whether the tool looks
  installed and/or authenticated (presence-only; secrets are never opened) and
  advertise a fully-enumerated matrix in which every usage / cost / limit /
  control capability is `unavailable` or `unsupported`. **Local usage/cost
  scanning for these nine is Planned**, not yet implemented. **Gemini** detects
  via the Gemini CLI's markers (`gemini` on `$PATH`,
  `~/.gemini/oauth_creds.json`) and advertises install + auth detection like the
  other app/CLI providers; the tables below list the original ten by name, and
  Gemini's row matches the app/CLI detection-only pattern (install/auth **S**,
  everything else **X**/**U**).

The matrix is grouped by capability family for readability. Rows are providers;
columns are `Capability` variants.

### Detection

| Provider | installed_app_detection | version_detection | auth_detection |
| --- | :--: | :--: | :--: |
| Claude | S | S | S |
| Codex | S | S | S |
| Antigravity | S | X | X |
| GitHub Copilot | S | X | S |
| Cursor | S | X | X |
| Devin | X | X | X |
| Grok | S | X | X |
| OpenCode | S | X | S |
| OpenRouter | X | X | X |
| Z.ai | X | X | X |

- The five app/CLI-based providers (Antigravity, Copilot, Cursor, Grok,
  OpenCode) implement an install probe, so `installed_app_detection` is **S**
  whether or not the tool is present on a given machine.
- `auth_detection` is **S** only where a non-secret credential *presence* marker
  exists (Copilot's `~/.config/github-copilot/*.json`, OpenCode's
  `auth.json`); the file is never read.
- Devin, OpenRouter, and Z.ai are cloud / API-key services with no local
  footprint, so their detection cells are **X** and they always report
  `not_detected` until an API-key integration is added.
- `version_detection` is **X** for all eight (no version string is parsed in
  detection-only mode).

### Usage & cost

| Provider | local_cost_scan | model_breakdown | cache_metrics | local_session_history |
| --- | :--: | :--: | :--: | :--: |
| Claude | S | S | S | S |
| Codex | S | S | S | S |
| Antigravity | X | X | X | X |
| GitHub Copilot | X | X | X | X |
| Cursor | X | X | X | X |
| Devin | X | X | X | X |
| Grok | X | X | X | X |
| OpenCode | X | X | X | X |
| OpenRouter | X | X | X | X |
| Z.ai | X | X | X | X |

The eight detection-only providers do not scan usage in v0.1.0 (**X**), so their
snapshots carry empty spend windows and a note saying so. Porting each
provider's usage source (following the OpenUsage adapters) is the roadmap.

### Limits & credits

| Provider | session_limits | weekly_limits | credits_and_spend |
| --- | :--: | :--: | :--: |
| Claude | U | U | U |
| Codex | S | S | U |
| Antigravity | U | U | U |
| GitHub Copilot | U | U | U |
| Cursor | U | U | U |
| Devin | U | U | U |
| Grok | U | U | U |
| OpenCode | U | U | U |
| OpenRouter | U | U | U |
| Z.ai | U | U | U |

- **Claude:** session/weekly limits are `unavailable` because they live behind
  the OAuth usage API, which is **not yet wired** (Planned). `credits_and_spend`
  is likewise `unavailable`.
- **Codex:** session (5-hour) and weekly limits are `supported` and read from
  local logs with **no network call**. `credits_and_spend` is `unavailable`.
- The eight detection-only providers mark all three `unavailable` — reachable in
  principle through a future authenticated API, but not wired now.

### Association & preview

| Provider | project_association | conversation_preview | tool_call_visibility |
| --- | :--: | :--: | :--: |
| Claude | S | X | X |
| Codex | U | X | — |
| Antigravity | X | X | X |
| GitHub Copilot | X | X | X |
| Cursor | X | X | X |
| Devin | X | X | X |
| Grok | X | X | X |
| OpenCode | X | X | X |
| OpenRouter | X | X | X |
| Z.ai | X | X | X |

### Live agent state

| Provider | live_task_detection | completion_detection | waiting_for_input_detection | remote_task_state |
| --- | :--: | :--: | :--: | :--: |
| Claude | — | — | — | X |
| Codex | — | — | — | X |
| Antigravity | X | X | X | X |
| GitHub Copilot | X | X | X | X |
| Cursor | X | X | X | X |
| Devin | X | X | X | X |
| Grok | X | X | X | X |
| OpenCode | X | X | X | X |
| OpenRouter | X | X | X | X |
| Z.ai | X | X | X | X |

Live-agent-mission surfaces (detecting a running task, completion, or a
"waiting for input" state) are part of the product vision but have **no
implementation in v0.1.0**. Claude/Codex do not advertise the three detection
capabilities (**—**) and mark `remote_task_state` `unsupported`; the
detection-only providers mark the whole family `unsupported`.

### Control & interaction

| Provider | reply | approve_reject | stop | resume | deep_link |
| --- | :--: | :--: | :--: | :--: | :--: |
| Claude | X | X | X | X | — |
| Codex | X | X | X | X | — |
| Antigravity | X | X | X | X | X |
| GitHub Copilot | X | X | X | X | X |
| Cursor | X | X | X | X | X |
| Devin | X | X | X | X | X |
| Grok | X | X | X | X | X |
| OpenCode | X | X | X | X | X |
| OpenRouter | X | X | X | X | X |
| Z.ai | X | X | X | X | X |

StackPulse performs **no remote control** in v0.1.0. Reply / approve-reject /
stop / resume are `unsupported` everywhere. Claude/Codex do not advertise
`deep_link` (**—**); the detection-only providers mark it `unsupported`.

## How to read a cell

- **S** means you can rely on it now.
- **U** means the capability is coming or is blocked by a precondition — the UI
  should explain the precondition (e.g. "sign in", or "requires a future
  release").
- **X** means it is fundamentally not available from that provider; StackPulse
  will never invent a value for it.
- **—** means the provider does not advertise the capability at all in this
  version.

## Roadmap for this matrix

- Wire Claude's OAuth usage API to move Claude's `session_limits` /
  `weekly_limits` / `credits_and_spend` from **U** toward **S**.
- Port real usage/cost scanning for the eight detection-only providers (moving
  their Usage & cost columns from **X** toward **S**), following the
  corresponding OpenUsage adapters.
- Introduce live-agent-mission capabilities as those surfaces are built.

Changes to this matrix that affect the protocol or other repos are also recorded
in [`CROSS_REPO_CHANGELOG.md`](CROSS_REPO_CHANGELOG.md).
