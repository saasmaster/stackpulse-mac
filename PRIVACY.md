# Privacy

StackPulse is built to be **local-first and private-by-design**. This document
describes, plainly, what it reads, what it does not, and where your data goes
(nowhere).

## The short version

- StackPulse runs entirely on your Mac.
- In v0.1.0 it makes **no network calls** and sends **no telemetry**.
- It reads AI-tool session logs that already exist under your home directory.
- It never reads your credentials — only checks whether they exist.
- Nothing you see in StackPulse leaves your machine.

## What StackPulse reads

To compute usage and cost, the core scans local session logs written by the AI
tools you already use:

- **Claude (Claude Code):** JSON-lines session files under the Claude config
  root, resolved in this order: `$CLAUDE_CONFIG_DIR` → `$XDG_CONFIG_HOME/claude`
  → `~/.config/claude` → `~/.claude`, at `{root}/projects/**/*.jsonl`. From each
  assistant turn it reads the model name, a timestamp, and token counts
  (`message.usage.*`). It reads message/request identifiers only to deduplicate
  replayed turns.
- **Codex (OpenAI Codex CLI):** JSON-lines session files under `$CODEX_HOME`
  (default `~/.codex`) at `sessions/**/*.jsonl` and `archived_sessions/**/*.jsonl`.
  From each turn it reads the active model, CLI version, per-turn token counts,
  and the provider-reported rate-limit block (5-hour / weekly window state).

Scanning is bounded to roughly the last 35 days of activity (files older than
that are skipped by modification time) and to a limited directory depth.

## What StackPulse does *not* do

- **No network.** v0.1.0 does not call any provider API or any StackPulse
  server. There is no account, no login, and no cloud sync.
- **No reading of secrets.** Auth detection checks only whether a credential
  exists (a file on disk, or a macOS Keychain item). The Keychain probe requests
  no secret data, so it does not even trigger the macOS "allow access" prompt.
- **No telemetry or analytics.** StackPulse does not phone home, count launches,
  or report crashes to us.
- **No writing to your logs.** Scanning is read-only. StackPulse does not modify,
  move, or delete provider data.
- **No transmission of log contents.** The textual content of your sessions
  (prompts, code, conversation) is not parsed for meaning and is never sent
  anywhere; only numeric usage fields are aggregated.

## Where your data lives

Everything StackPulse computes stays in memory and in the app's own local state.
The current version computes snapshots on demand from your logs and does not
persist a usage database (see
[ADR-0004](docs/decisions/0004-storage-strategy.md)); a later version may add a
**local** SQLite history that never leaves your machine.

## About cost numbers

Costs shown in StackPulse are **estimates**, derived locally from an embedded
price table of approximate public list prices (as of 2026-07), and are always
labeled as local estimates. They are **not** billed amounts.

If you pay for a provider through a **subscription or plan** rather than metered
usage, treat these figures as *equivalent metered list-price* estimates — an
indication of what the same token usage would cost at published per-token list
prices, not what you actually paid. StackPulse has no access to your invoices
and cannot show your real bill.

## Credentials and the Keychain (macOS)

The portable core cannot access the macOS Keychain by design. On macOS, the
Swift app additionally checks the Keychain for the *presence* of Claude Code
credentials (service name `Claude Code-credentials` and related), requesting no
secret data. This is presence-only detection to show an "authenticated" badge;
the token itself is never fetched or displayed.

## Planned features and privacy

Some roadmap items would change the data-flow picture, and each will be opt-in
and clearly disclosed before it ships:

- **Live provider limit APIs** (for example, Claude's OAuth usage endpoint) would
  introduce outbound network calls to the provider — never to StackPulse.
- **Remote pricing catalogs** (litellm, models.dev) would fetch a public price
  file; this involves no personal data.
- **Local usage history** (SQLite) would persist aggregates on your machine only.

Until those ship and you enable them, v0.1.0 remains fully offline.

## Contact

Questions about privacy: **privacy@stackpulse.dev**. Security concerns follow
[`SECURITY.md`](SECURITY.md).
