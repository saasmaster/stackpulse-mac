# Compatibility & Integration Health

StackPulse integrates with third-party tools whose on-disk formats, versions,
and auth mechanisms evolve independently of us. This document describes how the
project tracks each integration's health today, and the design of the **signed
compatibility manifest** that will let StackPulse adapt to upstream changes
without shipping a new binary. The manifest is **Planned**; everything in the
"Today" sections is implemented in v0.1.0.

## Why this exists

An AI tool can, at any time, bump its CLI version, change its session-log schema,
rotate where it stores credentials, or change a limits endpoint. When that
happens, a naive monitor silently shows wrong or empty numbers. StackPulse
instead models each integration's health explicitly and degrades loudly, so a
user can see *why* a provider looks off.

## Per-integration tracking fields (Today)

Each provider reports a small set of fields on every scan. In v0.1.0 these come
directly from the adapter code; a future manifest (below) will supply reference
values to compare against.

| Field | Source in v0.1.0 | Purpose |
| --- | --- | --- |
| `installed` | Presence of the provider's config root / data dir. | Is the tool on this machine at all? |
| `authenticated` | Presence of a credential (file or, on macOS, Keychain item) — never the secret. | Can we expect fresh data? |
| `detected_version` | Parsed from logs (e.g. Codex `session_meta.cli_version`; Claude session `version`). | Which upstream version produced this data? |
| `plan_hint` | Parsed from logs where present (e.g. Codex `rate_limits.plan_type`). | Subscription tier context for limits. |
| `health` | Derived (`IntegrationHealth`). | The single status the UI badges. |
| `notes` | Human-readable strings from the scan. | Explains empty/partial results (e.g. "no priceable models found"). |
| `capabilities` | The provider's advertised matrix. | What the integration can and cannot do right now. |

### Integration-health states

`IntegrationHealth` (from `stackpulse-protocol`) enumerates the states an
integration can be in. StackPulse uses these to communicate *why* an integration
is or is not delivering data:

| State | Meaning |
| --- | --- |
| `fully_supported` | Detected and working as designed. |
| `partially_supported` | Working, but some capabilities are unavailable. |
| `app_version_untested` | The detected upstream version is newer than any we have validated. |
| `authentication_changed` | Credentials appear to have moved or changed shape. |
| `session_schema_changed` | The on-disk log schema no longer matches expectations. |
| `endpoint_changed` | A remote endpoint we rely on appears to have changed (relevant once network features ship). |
| `metrics_unavailable` | The integration is present but produced no usable metrics. |
| `temporarily_broken` | A scan hit an internal error and was skipped this cycle (graceful degradation). |
| `discontinued` | The provider/integration is no longer maintained. |
| `user_action_required` | The user must do something (e.g. sign in) to restore data. |
| `not_detected` | The provider's app/data was not found on this machine. |

In v0.1.0 the adapters primarily emit `fully_supported` (installed) or
`not_detected` (absent), and the engine emits `temporarily_broken` for a provider
whose scan panics. The remaining states become meaningful as the manifest and
richer detection land — the vocabulary is defined now so the protocol does not
need a breaking change later.

## The signed compatibility manifest (Planned)

The goal is to let StackPulse learn "version 2.3 of tool X moved its logs" or
"the known-good schema for Y is Z" **as data**, delivered out-of-band and
verified, rather than as a code change requiring a new signed app release.

### Design principles

1. **Data, never code.** The manifest is a declarative document (path patterns,
   version ranges, schema fingerprints, known-good markers, health overrides).
   It contains **no executable code, no scripts, no expressions** — it can only
   adjust matching and labeling within logic the app already ships. This is a
   hard rule (see the untrusted-manifest threat in
   [`SECURITY_BOUNDARIES.md`](SECURITY_BOUNDARIES.md)).
2. **Signed and key-pinned.** Manifests are signed by a StackPulse release key.
   The app ships with the **public key pinned** in the binary and rejects any
   manifest whose signature does not verify against it. No key discovery, no
   trust-on-first-use.
3. **Schema-validated.** A manifest must validate against a versioned schema
   before it is considered. Unknown fields are ignored (forward compatible);
   malformed or out-of-range values reject the whole document.
4. **Last-known-good.** The app retains the last manifest that both verified and
   validated. If a fetched manifest fails verification/validation, the app keeps
   the last-known-good one and reports the failure — it never falls back to an
   unverified document.
5. **Fail safe, not open.** If no valid manifest is available, the app uses its
   compiled-in defaults. A missing or bad manifest degrades to "built-in
   behavior," never to "trust arbitrary input."
6. **Independent version line.** The manifest has its **own** version, distinct
   from app/core/protocol versions (see
   [ADR-0006](decisions/0006-independent-version-lines.md)).

### Anticipated manifest shape (illustrative, not final)

```jsonc
{
  "manifest_version": "1.0.0",     // its own version line
  "generated_at_unix": 1784000000,
  "integrations": {
    "codex": {
      "known_good_versions": ["1.0.0", "1.2.3"],
      "session_globs": ["sessions/**/*.jsonl", "archived_sessions/**/*.jsonl"],
      "schema_fingerprint": "sha256:…",   // shape check, not content
      "health_override": null              // e.g. "discontinued" if upstream dies
    }
  },
  "signature": "…"                  // verified against the pinned public key
}
```

The fields above are declarative selectors and labels. Crucially, there is no
place in this document to express a command, a URL to execute, or a code path to
run — only which files to match, which versions are known-good, and which health
label to surface.

### Verification pipeline (Planned)

```
  fetch/read manifest
        │
        ▼
  verify signature ── fails ──▶ keep last-known-good, report failure
        │ ok
        ▼
  validate against schema ── fails ──▶ keep last-known-good, report failure
        │ ok
        ▼
  apply (matching + labeling only) ──▶ becomes new last-known-good
```

## How compatibility interacts with versioning

- A **protocol** change (new `IntegrationHealth` variant, new capability) is
  recorded in [`PROTOCOL.md`](PROTOCOL.md) and
  [`CROSS_REPO_CHANGELOG.md`](CROSS_REPO_CHANGELOG.md).
- A **core** change to a scanner (new upstream schema support) ships in a core
  release and is noted in [`CHANGELOG.md`](../CHANGELOG.md).
- A **manifest** change (new known-good version, path pattern) will ship as a
  signed manifest bump with its own version — no app rebuild required.

Keeping these lines independent is what lets StackPulse react quickly to upstream
churn while keeping the trusted binary stable.
