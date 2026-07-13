# ADR-0005: Keep the core portable — no AppKit, paths, or Keychain in Rust

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

The entire reason StackPulse re-implements its logic in Rust (rather than forking
a Swift app, ADR-0001) is to have **one portable engine** reusable by more than
macOS: a future Windows client and a Chrome native-messaging host. That only
holds if the core contains nothing platform-specific. It is easy to accidentally
break portability — a hardcoded `/Users/...`, a Keychain call, an AppKit import —
and such breakage is invisible until someone tries to build for another target.

At the same time, some data genuinely requires platform APIs. On macOS, Claude
Code stores its OAuth token in the Keychain (service `Claude Code-credentials`),
which the portable core cannot read.

## Decision

**The `stackpulse-protocol` and `stackpulse-core` crates must build for
non-macOS targets and contain no platform-specific code.** Concretely:

- No AppKit / SwiftUI / macOS frameworks.
- No Keychain or other OS credential-store access.
- No hardcoded platform paths. Filesystem roots are resolved from **environment
  variables** with sensible fallbacks that mirror the provider CLIs themselves:
  Claude via `$CLAUDE_CONFIG_DIR` → `$XDG_CONFIG_HOME/claude` → `~/.config/claude`
  → `~/.claude`; Codex via `$CODEX_HOME` → `~/.codex`; home via `$HOME` /
  `%USERPROFILE%`.
- Only `std` plus a tiny dependency set (serde / serde_json).

**Platform-specific detail lives in the native shell.** On macOS, the Swift
`KeychainProbe` performs a **presence-only** Keychain check (requesting no secret
data) and merges the result into the effective auth state. Security-scoped
bookmarks, notifications, and update handling will also live app-side.

The `stackpulse-cli` binary is the **portability smoke-test target**: if it
builds and runs, the core stayed portable.

## Consequences

- **Positive:** The same core powers macOS today and Windows / Chrome tomorrow
  with no rewrite. The boundary is explicit and reviewable.
- **Positive:** The security posture improves: the core literally cannot read the
  Keychain, so token-theft via the core is impossible (see
  [`SECURITY_BOUNDARIES.md`](../SECURITY_BOUNDARIES.md)).
- **Positive:** Env-driven discovery makes the core trivially testable against
  fixtures, on any OS.
- **Negative / cost:** Some capabilities are split across the boundary (e.g.
  Claude auth = core file check *or* Swift Keychain probe), which is slightly more
  code and requires the app to merge results. We accept this as the natural shape
  of the boundary.
- **Discipline required:** Contributors must keep platform code out of the core;
  the CLI build is the guardrail, and the rule is restated in
  [`CONTRIBUTING.md`](../CONTRIBUTING.md).
