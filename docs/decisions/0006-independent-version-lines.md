# ADR-0006: App, core, protocol, and compatibility-manifest versions are independent

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

StackPulse has several things that each evolve at their own pace:

- the **macOS app** (UI, packaging, native features),
- the **portable core** (detection, scanning, pricing, aggregation),
- the **wire protocol** (`stackpulse-protocol`), shared with future clients, and
- a future **compatibility manifest** (signed, out-of-band data; see
  [`COMPATIBILITY.md`](../COMPATIBILITY.md)).

If these shared a single version number, unrelated changes would force lockstep
bumps: a UI tweak would imply a "protocol change," a pricing-table refresh would
imply an "app release," and downstream consumers (a Windows client, a Chrome
host) could not tell whether a bump actually affected the contract they depend
on.

## Decision

**Maintain four independent SemVer version lines.**

- **App version** — the shippable macOS product.
- **Core version** — `stackpulse-core` (currently **0.1.0**).
- **Protocol version** — `PROTOCOL_VERSION` (currently **1.0.0**), embedded in
  every snapshot and `pong`.
- **Compatibility-manifest version** — its own line, defined when the manifest
  ships.

Rules:

- Each line follows SemVer independently. Pre-1.0 lines use `0.x`, where minor
  bumps may carry breaking changes.
- A **breaking protocol change** bumps the protocol major and is recorded in
  [`PROTOCOL.md`](../PROTOCOL.md) and
  [`CROSS_REPO_CHANGELOG.md`](../CROSS_REPO_CHANGELOG.md). Additive protocol
  changes are `#[serde(default)]` / open-enum-safe and need no major bump.
- The core can advance (e.g. a new scanner, a pricing refresh) without moving the
  protocol, and vice versa.
- The app can release without any core/protocol change.

Both the protocol version and the core version travel **inside** the snapshot, so
any client can see exactly what produced the data it is rendering.

## Consequences

- **Positive:** Downstream consumers can pin to a **protocol** version and ignore
  app/core churn that does not affect the contract.
- **Positive:** Honest signaling — a version bump means something specific about
  the surface that moved.
- **Positive:** The core and protocol can be reused by other repos on their own
  cadence.
- **Negative / cost:** Four numbers to track and reason about, and release notes
  must state which line moved (the [`CHANGELOG.md`](../CHANGELOG.md) entries call
  this out). We accept the small bookkeeping cost for the clarity it buys.
- **Compatibility guarantee:** "newer core / older client" stays safe because of
  the forward-compat rules the protocol version governs (unknown enum values and
  defaulted fields).
