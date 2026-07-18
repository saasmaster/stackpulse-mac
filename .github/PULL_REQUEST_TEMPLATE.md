<!--
Keep PRs focused: one concern per PR. Link the relevant ADR or doc.
See CONTRIBUTING.md for the guiding principles and per-area rules.
-->

## What & why

<!-- What does this change, and why? Link the issue or ADR it relates to. -->

## Checklist

Gates (must pass locally — these mirror CI):

- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --all-targets -- -D warnings`
- [ ] `cargo test` (protocol, core, providers)
- [ ] `cd apps/StackPulseMac && swift build` (Swift-affecting changes)

Rules that apply when relevant:

- [ ] New behavior has tests; new user-facing behavior has a `CHANGELOG.md` entry under `[Unreleased]`.
- [ ] Portable core stays portable — no macOS frameworks, Keychain, or hardcoded paths in `stackpulse-protocol` / `stackpulse-core` (ADR-0005).
- [ ] Honesty preserved — every number keeps its `Provenance`; estimates stay labeled; unsupported capabilities report `Unsupported`, not a fake value.
- [ ] Protocol change: `PROTOCOL_VERSION` bumped if breaking, and `docs/PROTOCOL.md` + `docs/CROSS_REPO_CHANGELOG.md` updated.
- [ ] Pricing change: `PRICING_AS_OF` bumped, rates kept as approximate public list prices, arithmetic pinned by tests.
- [ ] No real user logs, secrets, or session data committed.
