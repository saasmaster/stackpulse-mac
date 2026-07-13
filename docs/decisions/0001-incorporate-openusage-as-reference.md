# ADR-0001: Incorporate OpenUsage as an attributed reference, not a hard fork

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

OpenUsage (`robinebers/openusage`, MIT, upstream ref v0.7.5) is an excellent
macOS menu-bar monitor for AI-coding usage, and it is prior art we want to
respect and credit. The obvious path would be to fork it and extend it.

However, StackPulse has a hard, non-negotiable requirement that OpenUsage's
architecture cannot satisfy: a **portable core**. StackPulse must ship the same
usage/detection/pricing logic to more than macOS — a future Windows client and a
Chrome native-messaging host — which means the logic has to live in a
platform-neutral engine. OpenUsage is ~98.6% Swift; a predominantly-Swift
codebase cannot be that shared, non-macOS-capable core.

OpenUsage also ships a `TRADEMARK.md`; its name and marks are not ours to reuse.

## Decision

**Incorporate OpenUsage as an attributed reference rather than forking it.**

- Re-implement the parsing and pricing logic in **Rust** (`stackpulse-core`),
  so it is portable and reusable by non-macOS clients.
- Re-implement the macOS application **natively** in Swift (`apps/StackPulseMac`).
- Copy **no OpenUsage source verbatim**; where behavior intentionally matches
  (path-resolution order, dedup semantics), credit it.
- Do **not** reuse the OpenUsage name or marks. StackPulse is an independent
  name and is not presented as OpenUsage or a fork thereof.
- Record the attribution honestly in [`NOTICE`](../../NOTICE), including the
  upstream reference tag **v0.7.5** and OpenUsage's MIT license text.

CodexBar (`steipete/CodexBar`, MIT) and Tokcat (`handlecusion/tokcat`, Tauri)
are studied for ideas only and are likewise credited without incorporating code.

## Consequences

- **Positive:** We get a genuinely portable core (the whole point of the
  project); a clean, native Swift app; and a clear, honest attribution story that
  respects upstream licenses and trademarks.
- **Positive:** No license entanglement from copied code; the repo is MIT and
  self-consistent.
- **Negative / cost:** More upfront work than a fork — we re-derive log formats
  and pricing in Rust and rebuild the UI. We accept that cost because the
  portable-core requirement makes a fork a dead end.
- **Ongoing obligation:** Keep `NOTICE` accurate as we track upstream ideas, and
  never let StackPulse imply endorsement by or identity with OpenUsage.
