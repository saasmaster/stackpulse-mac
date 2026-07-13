# ADR-0007: Bucket usage windows by UTC date in v0.1.0

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

Usage windows (today / yesterday / last 30 days) require deciding which calendar
day a timestamped log record belongs to. That decision depends on a timezone:
"today" in local time differs from "today" in UTC, and near midnight a record can
fall on different days under different rules. Getting local-time bucketing right
means handling the host offset and DST transitions — real complexity, and a
source of subtle, hard-to-test bugs.

The core is also deliberately dependency-light and portable (ADR-0005): it uses
its own small date math (Howard Hinnant's `days_from_civil` / `civil_from_days`)
rather than pulling in a timezone library. Log timestamps are ISO-8601, and for
day-granularity bucketing we only need the `YYYY-MM-DD` portion.

## Decision

**In v0.1.0, bucket all windows by UTC date, and disclose that in the snapshot.**

- The core reads the wall clock once (`now_unix`) and derives "today" as the
  **UTC** civil date; "yesterday" and the 30-day cutoff are computed from it.
- Each log record's date is the UTC calendar date parsed from the `YYYY-MM-DD`
  prefix of its ISO-8601 timestamp (time-of-day and offset are ignored for
  bucketing).
- The snapshot carries **`bucket_date_utc`** (the UTC date used for "today") so
  the UI can honestly label windows as UTC-based. The macOS popover surfaces this
  (e.g. "UTC 2026-07-12").

A future version can apply the host's local offset for local-day bucketing; that
refinement is deferred, not precluded.

## Consequences

- **Positive:** Deterministic and simple — no timezone database, no DST edge
  cases, fully unit-testable given an injected clock. Keeps the core portable and
  tiny.
- **Positive:** Transparent — because `bucket_date_utc` is disclosed and shown,
  users are never misled about what "today" means.
- **Negative / cost:** For users far from UTC, "today" may not match their local
  calendar day, especially near midnight; a late-evening session in a
  UTC-negative timezone can land in the next UTC day. This is a known, disclosed
  limitation for v0.1.0.
- **Future work:** Add local-offset bucketing (and possibly a user setting),
  keeping the disclosure field so the UI can always state which basis is in use.
  Such a change would be additive to the protocol and recorded in
  [`CROSS_REPO_CHANGELOG.md`](../CROSS_REPO_CHANGELOG.md).
