# Security Policy

StackPulse runs on your machine, reads sensitive local files (AI-tool session
logs), and detects the presence of credentials. We take its security posture
seriously, and we designed it to be conservative by default.

## Supported versions

StackPulse is pre-1.0. Security fixes are applied to the latest released version
(currently the `0.1.x` line). There is no long-term support branch yet.

| Version | Supported |
| --- | --- |
| 0.1.x | Yes (latest) |
| < 0.1.0 | No |

## Reporting a vulnerability

**Please do not open a public GitHub issue for a security vulnerability.**

Report privately using GitHub's **"Report a vulnerability"** (Security Advisories)
on the repository, or email **security@stackpulse.dev**. Include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- Affected version(s) and your environment (macOS, Rust, Swift versions).
- Any suggested remediation.

Please **redact secrets and personal data** from anything you send. Never
include full session logs, tokens, or Keychain contents.

### What to expect

- We aim to acknowledge a report within **3 business days**.
- We will work with you on a fix and a coordinated disclosure timeline.
- We will credit reporters who wish to be credited once a fix ships.

## Security design summary

StackPulse's design intentionally minimizes attack surface. The full threat
model and per-threat mitigations are documented in
[`docs/SECURITY_BOUNDARIES.md`](docs/SECURITY_BOUNDARIES.md). Highlights:

- **Read-only, local-only.** v0.1.0 scans local logs and makes **no network
  calls**. It executes no provider commands and writes nothing to provider data.
- **Credentials are never read.** Auth detection checks only for the *presence*
  of a credential file or Keychain item. The macOS Keychain probe explicitly
  requests no secret data (`kSecReturnData: false`), which also avoids the
  interactive "allow access" prompt.
- **No symlink following.** The filesystem scanner does not traverse symlinked
  directories, guarding against symlink loops and path traversal outside an
  intended root.
- **Bounded, resilient parsing.** Log traversal is depth-bounded; malformed or
  partial log lines are skipped rather than trusted; a panic in one provider is
  caught and downgraded so it cannot corrupt or abort the rest of a scan.
- **Small, explicit FFI contract.** The C ABI is JSON-in / JSON-out with a
  documented single-owner memory contract; unwinding is caught at the boundary.

## Handling of untrusted input

Session logs are treated as **untrusted data**, because their contents can
include text pasted from repositories, web pages, or tool output (potential
prompt/log-injection payloads). StackPulse parses these logs for numeric usage
data only; it does not execute, evaluate, or act on their textual content.

## Distribution integrity (Planned)

The planned release pipeline is Developer ID signing + hardened runtime +
notarization, distributed as a signed DMG with a published SHA-256, and updated
through a Sparkle appcast (stable and beta channels) with signed updates.
Sparkle is **not yet integrated**; until it is, build from source or verify any
provided artifact's signature and checksum yourself.

## Scope

In scope: the Rust core, the FFI bridge, the CLI, and the macOS app in this
repository. Out of scope: vulnerabilities in the third-party AI tools whose logs
StackPulse reads, and issues that require an already-compromised local account.
