# StackPulse — Usage Guide

How to build it, run it, read it, and know when not to trust it.

This guide describes what the code does today. Where something is not built, it
says so. Where a number is a guess, it says that too.

- [Build and install](#build-and-install)
- [First run](#first-run)
- [The menu bar](#the-menu-bar)
- [The sections](#the-sections)
- [Reading the numbers honestly](#reading-the-numbers-honestly)
- [What StackPulse does not know](#what-stackpulse-does-not-know)
- [What touches the network](#what-touches-the-network)
- [The CLI](#the-cli)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)

---

## Build and install

There is no signed release. You build it from source. There is no installer, no
DMG, and no auto-update — see [Not built](#not-built) below.

### Prerequisites

- macOS 14+ (Apple Silicon; developed on macOS 26.5).
- **Rust** — workspace MSRV is 1.80 (`rust-version` in `Cargo.toml`).
- **Swift 6** with the Command Line Tools. **Full Xcode is not required and not
  used** — the app is a Swift Package built with SwiftPM ([ADR-0002](decisions/0002-swiftpm-not-xcodeproj.md)).

### Build and run

```sh
# Rust core + CLI + FFI static library, then the Swift app.
make app          # scripts/build-app.sh: build-core.sh release + swift build -c release
make run          # build, then launch the menu-bar app

# Or assemble a double-clickable bundle:
make package      # → dist/StackPulse.app  (ad-hoc signed, LOCAL USE ONLY)
open dist/StackPulse.app
```

Doing it by hand is the same three steps:

```sh
cargo build --release                       # core + CLI
cargo build -p stackpulse-ffi --release     # libstackpulse_ffi.a
cd apps/StackPulseMac && swift build -c release
```

> **Build the Swift app from `apps/StackPulseMac`.** The linker search path for
> the static archive is relative (`-L ../../target/release`) so that a repository
> path containing spaces still builds.

`make package` produces an **ad-hoc-signed** bundle. It runs on the machine that
built it. It is not signed with a Developer ID and not notarized, so it is not
distributable to anyone else.

### Verify without launching the GUI

```sh
make dump                                        # snapshot JSON via the app → FFI → core
.build/release/StackPulseApp --version           # core version through the C ABI
.build/release/StackPulseApp --selftest-parsers  # deterministic parser/gate self-tests
```

---

## First run

StackPulse is a **menu-bar accessory** (`LSUIElement`) — no Dock icon until you
open the main window. Click the menu-bar readout to open the popover.

On first launch it scans local logs the AI tools already wrote. Nothing is
imported, no account is created, and no API key is required.

Two things ask for your consent, and both are worth understanding before you
click through them:

1. **Approved folders.** Projects, Stack Health, Services, Discover, and By
   Project only look inside roots you explicitly add. The core reads nothing
   outside them.
2. **The Keychain prompt.** If Claude live limits is on (**it is on by default**
   — see [What touches the network](#what-touches-the-network)) and your Claude
   Code token is in the Keychain rather than in `~/.claude/.credentials.json`,
   macOS will ask you to allow StackPulse to read `Claude Code-credentials`. That
   prompt is real: granting it lets StackPulse read your actual OAuth token and
   send it to Anthropic's usage endpoint. Denying it costs you the live-limit
   percentage and nothing else.

---

## The menu bar

The readout is labeled per provider, e.g. `Cl 247M  Cx 9%` — Claude's token
volume, Codex's limit utilization. A badge appears when the alerts engine has
something for you; `▶N` shows the count of AI coding sessions it currently sees
as active.

| Shortcut | Does |
| --- | --- |
| `⌥⌘S` | Toggle the edge sidebar |
| `⇧⌘C` | Toggle the Command Center (built for a second monitor) |

---

## The sections

The sidebar's primary sections are **Home, Launcher, Projects, Missions, Usage,
Advisor**. The rest are reachable as sub-panes.

| Section | Answers |
| --- | --- |
| **Home** | What's happening right now — today's spend, live limits, active sessions, anything needing attention. |
| **Launcher** | Launch a web app in your folders in one tap, with a copy-paste command and a URL. |
| **Projects** | Your code and what's running — remembered commands, live dev servers, one-tap web preview. |
| **Missions** | Live and recent AI coding sessions observed on this Mac, read from local logs. |
| **Usage** | Where tokens and money go — per-model and per-window breakdowns. |
| **Advisor** | Everything you could improve — efficiency, projects, dependency health. |
| **Needs Attention** | What the core's alerts engine flagged: thresholds, resets, integration issues. |
| **Insights** | Local rules over your own usage — low cache hit rate, spend anomaly, approaching limit, idle provider, cost concentration, stalled session. |
| **Overview** | At-a-glance spend, volume, and limits across every detected provider. |
| **Trends** | Long-run spend/token trends from the durable history store, which outlives the ~30-day log window. |
| **By Project** | Which projects the spend went to, attributed from each session's recorded working directory. |
| **Reports** | A shareable snapshot — export as text, Markdown, CSV, or JSON. |
| **Discover** | Explainable, project-grounded recommendations. Filesystem + git only, no network. |
| **Stack Health** | Whether each project's dependencies are current and free of known advisories. |
| **Services** | Dev servers running right now, their ports, and which project owns them. |
| **Integrations** | Per-provider detection, health, and the capability matrix. |
| **Settings** | Versions, refresh cadence, cost methodology, connections, notifications, theme. |

---

## Reading the numbers honestly

### Costs are local list-price estimates. They are not your bill.

Every dollar figure StackPulse shows is computed **on your machine** by
multiplying token counts from your local logs against an **embedded table of
approximate public list prices** (`crates/stackpulse-core/src/pricing.rs`,
`PRICING_AS_OF = "2026-07-16"`). Costs are always tagged `LocalEstimate`.

StackPulse has no access to your invoice, your plan, your discounts, your
credits, or your actual charges. It does not know what you paid.

If you are on a subscription (Claude Pro/Max, ChatGPT Plus), the estimate is an
**equivalent metered list-price** figure: roughly what the same token volume
would cost at pay-as-you-go rates. It is not what you were billed. It is
frequently much higher than what you were billed. That gap is the point — it
tells you what your plan is worth — but it is not a bill.

### Provenance labels

Values carry their origin. `LocalEstimate` is computed here from list prices.
Provider-reported values (Codex's 5-hour and weekly limit windows, read from
local logs) are labeled as such. Measured values (token counts, cache reads) come
straight from the logs. The UI does not blur these together.

### UTC bucketing

Daily windows bucket on **UTC**, not your local timezone
([ADR-0007](decisions/0007-utc-bucketing-v0.md)). "Today" may not match your
provider's dashboard if you are far from UTC.

### The 30-day horizon

Scans only read session files modified in the last ~35 days, and windows cover
today / yesterday / last 30 days. Older logs rotate away. The **Trends** section
exists because of this: it accumulates a durable history store
(`~/Library/Application Support/StackPulse/history.json`) that outlives the logs.

---

## What StackPulse does not know

This section is the important one.

### A model with no price contributes $0 to every cost figure

`rates_for()` returns `None` for a model it does not recognize — an unknown
family, **or an unrecognized version of a known family**. The core deliberately
**refuses to guess a price it does not know**.

The consequence: **tokens are still counted, but cost is silently omitted.** Your
totals under-report, and nothing about a smaller number looks wrong.

#### Schema canaries name the gap

Because that failure is silent, every snapshot carries a per-provider **canary**
(`UsageSnapshot.canaries`, protocol 1.18.0):

| Status | Means |
| --- | --- |
| `ok` | Files were parsed and everything in them was understood. |
| `drifted` | Something was found that this core doesn't fully understand — the numbers are incomplete **in a way we can name**. |
| `no_data` | Nothing local to check. Explicitly *not* `ok` — there was nothing to verify. |

A `drifted` canary lists each unpriced model with its record count and tokens, so
the gap is measurable rather than a footnote. Canaries cover **Claude and Codex**
only — the two providers with local token accounting to verify. Emitting rows for
the detection-only providers would mean nothing.

Check it directly:

```sh
./target/release/stackpulse snapshot --json | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["canaries"], indent=1))'
```

#### Why the table is strict (a real incident)

`rates_for()` used to do tolerant substring matching: anything containing `opus`
got the Opus card. That priced **Opus 4.8 at Opus 4.1's rates — 3× the real
price** — silently, for as long as the card sat un-updated, overstating a real
month's spend by **2.7×**. A wrong rate looks exactly like a right one.

It now parses the version, and an unrecognized version returns `None` rather than
borrowing a sibling's price. Strictness is only safe *because* the canary surfaces
the gap — the two are a pair.

Fixing an unpriced model means adding it to `rates_for()` in
`crates/stackpulse-core/src/pricing.rs`, and moving `PRICING_AS_OF` with it.

### The price table's known inaccuracies

Stated in `pricing.rs` rather than hidden. All three are live today:

1. **Cache writes are priced at the 5-minute rate.** Anthropic bills a 5-minute
   cache write at 1.25× input and a **1-hour** write at **2×**. Claude's logs do
   distinguish them, but `TokenTotals` carries a single `cache_creation_tokens`,
   so the split is lost before it reaches pricing. On a real machine **86% of
   cache writes were 1-hour** — so this **understates**. Fixing it means carrying
   the split through the protocol and the adapters.
2. **OpenAI / Codex rates are unverified.** The Claude cards were read off
   Anthropic's published price list. The GPT/Codex cards were not — they are
   inherited from an earlier revision. Tightening them without verification would
   only trade one unverified answer for another.
3. **Sonnet 5 is on introductory pricing** through **2026-08-31**
   (`SONNET_5_INTRO_ENDS`), after which it rises to the standard Sonnet rate.
   `rates_for()` has no clock, so on that date the table silently becomes wrong
   for Sonnet 5 until someone updates it.

Rates are hand-maintained and go stale. `PRICING_AS_OF` (`2026-07-16`) is the only
thing telling you how stale — it must move whenever the table does. There is no
remote price feed.

### Only two providers have a full local usage scan

Eleven providers are registered and appear in every snapshot. That is not the
same as eleven providers being supported.

| Providers | What they actually do |
| --- | --- |
| **Claude, Codex** (2) | Full local cost scan — per-model breakdown, cache metrics, real numbers from real logs. Codex additionally reports its 5-hour and weekly limit windows from local logs with no network. |
| **Antigravity** (1) | **Activity only** — conversation count, recency, model, and step counts from `~/.gemini/antigravity`. Token and cost accounting is server-side at Google and **is not available locally, so it is not shown**. Not fabricated, not estimated. |
| **GitHub Copilot, Cursor, Devin, Gemini, Grok, OpenCode, OpenRouter, Z.ai** (8) | **Detection-only.** They report whether the tool looks installed and/or authenticated, presence-only. **No usage. No cost. No limits.** Devin, OpenRouter, and Z.ai have no local footprint at all and read `not_detected`. |

So: 2 of 11 have usage/cost scanning. Anything implying otherwise is wrong. The
full matrix is in [`CAPABILITIES.md`](CAPABILITIES.md).

### Auth detection is presence-only

Detecting "authenticated" means a credential file or Keychain **item exists**.
StackPulse does not open it, and an existing credential may be expired or
revoked. The one exception is the Claude live-limits path, which genuinely reads
the token — see below.

### Not built

Do not expect these. They do not exist:

- **Chrome native-messaging host** — no extension exists to talk to it.
- **Signed / notarized releases, DMG, Sparkle auto-update** — needs an Apple
  Developer certificate. `make package` produces an ad-hoc bundle for local use.
- **Windows client** — the core is portable and CI cross-compiles it for
  `x86_64-pc-windows-gnu`, but no Windows UI exists.
- **Remote pricing feed** (litellm / models.dev) and a **signed compatibility
  manifest** — designed, not implemented.

---

## What touches the network

**The Rust core never makes a network call.** Not "usually" — it has no HTTP
client. Its entire dependency set is `serde`, `serde_json`, and (macOS-only)
`rusqlite`. `GetStackHealth` accepts a `check_updates` flag and **ignores it**;
the core returns a local-only inventory. This is [ADR-0005](decisions/0005-portable-core-boundary.md).

Every request that **leaves your machine** lives in the Swift layer. There are
exactly three, and this is the complete list:

| Feature | Endpoint(s) | Sends | Default |
| --- | --- | --- | --- |
| **Claude live limits** | `https://api.anthropic.com/api/oauth/usage` | Your **Claude Code OAuth token** as a Bearer header | **ON** |
| **BYOK balances** | `https://openrouter.ai/api/v1/credits`, `<your-litellm-host>/key/info`, `https://api.deepseek.com/user/balance` | The API key **you** saved for that provider | OFF (no key = never contacted) |
| **Stack Health enrichment** | `https://registry.npmjs.org/`, `https://crates.io/api/v1/crates/`, `https://api.osv.dev/v1/querybatch` | Package **names and versions** from your approved roots | Off unless you run a check |

### Local-only connections (nothing leaves the machine)

Not in the table above, because they never reach the internet:

- **Project web preview** opens a TCP probe to `127.0.0.1:<port>` and renders your
  own dev server in a web view.
- **Services** detection reads listening ports via `lsof` — no connection at all.
- `LocalNetwork` reads your LAN IPv4 from the interface list (to build the
  shareable `http://192.168.x.x:<port>` demo URL). It makes no request.

StackPulse **opens no listening socket** of its own. The core is linked
in-process over the C ABI — there is no port, no localhost server, and no IPC
endpoint to reach it on.

### Claude live limits, in detail

This is the one that deserves your attention, because it is **on by default** and
it reads a real secret.

- It reads your Claude Code OAuth token — from `~/.claude/.credentials.json`
  first (never prompts), otherwise via `/usr/bin/security find-generic-password`
  against `Claude Code-credentials` (**this triggers the macOS "allow access"
  prompt** and fetches the actual secret).
- It sends that token as `Authorization: Bearer …` to **one** endpoint,
  `api.anthropic.com/api/oauth/usage`, and nowhere else.
- The token is never logged, printed, or written to disk.
- Response bodies are never logged on error — only status codes — because the
  body can echo account context.
- The fetched percentage is cached (`liveLimitsCacheURL`) so a transient 429 does
  not blank the display, and so StackPulse does not hammer the endpoint.

**Turn it off in Settings** if you want StackPulse fully offline. With it off, the
app makes no network call unless you have saved a BYOK key or asked for a Stack
Health check. The trade-off: Claude's session/weekly percentages come only from
this endpoint, so without it Claude has no live limit readout (Codex's limits
still work — they come from local logs).

### The core does execute commands

Read-only, but worth knowing: the core shells out to **`git`** (missions,
worktrees, checkpoints, radar) and **`lsof`** (detecting dev servers by listening
port). Checkpoints use `git stash create` plus a ref under `refs/stackpulse/` and
never alter your working tree, index, or HEAD.

The app can also **run a remembered command in Terminal**, which is explicit,
confirmed, and requires `NSAppleEventsUsageDescription`. That is you asking it to
run something, not it deciding to.

---

## The CLI

The same core, same JSON, no GUI. Useful for scripting and for seeing exactly
what the app sees.

```sh
./target/release/stackpulse snapshot            # human-readable summary
./target/release/stackpulse snapshot --json     # full UsageSnapshot JSON
./target/release/stackpulse status              # cheap per-provider detection
./target/release/stackpulse missions [--json]   # recently-active AI sessions
./target/release/stackpulse projects <root>… [--json]
./target/release/stackpulse history <data_dir> [--days N] [--json]
./target/release/stackpulse ping                # core + protocol versions
./target/release/stackpulse request '<json>'    # raw CoreRequest → JSON reply
```

`stackpulse ping` is the authoritative answer for which core and protocol
versions you are actually running.

The `snapshot` summary prints the unpriced-model note described above. If you are
about to trust a cost number, run it.

---

## Settings

- **Auto-refresh cadence** — Manual, 1m, 2m, 5m, 15m. Manual runs no timer.
- **Claude live limits** — the network toggle. **On by default.** Off = offline.
- **Provider connections (BYOK)** — store an API key per provider in StackPulse's
  **own** Keychain service (so it never prompts for another app's items). Eight
  providers can store a key; **three have a working balance fetcher** (OpenRouter,
  LiteLLM, DeepSeek). The rest store the key and say "coming soon" — honestly.
- **Notifications** — banners for new alerts, with a severity threshold, quiet
  hours, and a Send-test button.
- **Export** — CSV/JSON of usage and history, plus a copy-summary.
- **Theme** — System / Light / Dark.

---

## Troubleshooting

**Claude shows `auth ✗` but works.** Auth detection is presence-only. If your
token is in the Keychain and not in `~/.claude/.credentials.json`, the core (which
cannot read the Keychain by design) sees nothing; the Swift probe merges the real
answer in the app.

**Live limits show nothing / "access denied".** The Keychain prompt is pending or
was denied. macOS remembers a Deny. Fix it in Keychain Access, or put the app in
a stable location — an ad-hoc-signed bundle changes identity on every rebuild,
which is exactly why the token read goes through `/usr/bin/security` (its code
identity is stable, so "Always Allow" survives your rebuilds).

**A cost number looks too low.** Check the canaries — a `drifted` status names any
model whose tokens are counted but whose cost is omitted. Cache writes are also
known to be understated (see
[known inaccuracies](#the-price-tables-known-inaccuracies)).

**Costs do not match my bill.** They never will. They are list-price estimates
computed locally. StackPulse has no access to your billing.

**"Today" disagrees with my provider's dashboard.** Buckets are UTC.

**The app won't relink after I rebuilt the Rust core.** SwiftPM does not notice a
changed `.a` on its own. Touch a Swift source, or `rm -rf .build`.

**A provider is blank.** One provider failing is caught and downgraded to a
degraded record with a note — the rest of the snapshot still renders. Read the
note on the card.

---

## Verifying a change

The gates, all real:

```sh
cargo fmt --all -- --check
cargo clippy -p stackpulse-protocol -p stackpulse-core -p stackpulse-cli --all-targets -- -D warnings
cargo test --workspace
cd apps/StackPulseMac && swift build -c release
./.build/release/StackPulseApp --selftest-parsers
```

CI additionally builds and tests the portable crates on **Linux** and
cross-compiles them for **Windows** — that is the guardrail that keeps platform
code out of the core.

See [`CONTRIBUTING.md`](../CONTRIBUTING.md).
