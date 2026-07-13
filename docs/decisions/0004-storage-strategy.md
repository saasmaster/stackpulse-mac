# ADR-0004: v0.1.0 computes from logs with no database; SQLite planned later

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

StackPulse aggregates usage over windows (today / yesterday / last 30 days) and
per model. A natural instinct is to persist this into a database so history is
cheap to query and survives restarts. But a database adds schema, migrations, a
storage dependency, and a place for data to drift out of sync with the source of
truth — the provider logs themselves.

For v0.1.0 the required windows are short (≤30 days) and the source logs are
already on disk, bounded, and fast to scan (traversal is limited to ~35 days of
recently modified files and a fixed depth). We do not yet need long-term history
or cross-session trends.

## Decision

**v0.1.0 computes every snapshot on demand directly from the logs, and persists
no usage database.** The output is a `UsageSnapshot` (in memory / serialized to
JSON on request). The macOS app holds the latest snapshot in its `SnapshotStore`
and refreshes on a timer; it does not write a usage store.

**A local SQLite store (via `rusqlite`) is Planned for a later phase** to enable
long-range history and trends. It was chosen in principle because:

- it is embedded, file-based, and requires no server;
- it is **portable** — it keeps working on the non-macOS targets the core must
  support (ADR-0005); and
- it fits the local-first, private-by-design model (data stays on the machine;
  see [`PRIVACY.md`](../PRIVACY.md)).

When it lands, it will live behind the core so all clients benefit, and it will
introduce new query operations recorded in
[`CROSS_REPO_CHANGELOG.md`](../CROSS_REPO_CHANGELOG.md).

## Consequences

- **Positive:** Simplest possible v0.1.0 — no schema, no migrations, no storage
  bugs, and results are always consistent with the current logs (the source of
  truth).
- **Positive:** Nothing sensitive is persisted, which keeps the privacy story
  trivial for the first release.
- **Negative / cost:** No history beyond what the logs retain; each refresh
  re-scans (bounded, so acceptable). Trends over months are not available until
  the SQLite phase.
- **Negative:** Recomputing on every refresh is slightly more CPU than reading a
  cache; mitigated by the 3-minute refresh cadence and the bounded scan window.
- **Future work:** Design the SQLite schema and the incremental-ingest path so it
  augments (not replaces) log scanning, and keep it portable.
