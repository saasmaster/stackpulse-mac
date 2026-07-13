# Security Boundaries & Threat Model

StackPulse reads sensitive local data and is designed to be conservative by
default. This document enumerates the threats the project takes seriously and
how the **current v0.1.0 design** mitigates each. Some threats apply only to
**Planned** features (network APIs, a native-messaging host, a signed manifest);
those are marked, with the intended mitigation described so the design is set
before the code exists.

For how to report a vulnerability, see [`SECURITY.md`](../SECURITY.md). For the
manifest design referenced below, see [`COMPATIBILITY.md`](COMPATIBILITY.md).

## Security posture in one line

v0.1.0 is **read-only, local-only, and network-free**: it scans local logs,
detects credentials by presence only, executes nothing, follows no symlinks, and
sends no data anywhere.

## Threat model

Each threat below lists its status in v0.1.0 and the mitigation.

### 1. Malicious repository content

**Threat:** A repository a user works in contains hostile content (file names,
code, or data) intended to trick a monitoring tool into misbehaving.

**Mitigation (Today):** StackPulse never opens, executes, or interprets
repository files. It only reads AI-tool **session logs** under the user's config
roots, and from those it extracts numeric usage fields — not code to run. There
is no path by which repository contents drive StackPulse behavior.

### 2. Prompt / log injection

**Threat:** Session logs contain attacker-influenced text (pasted from web pages,
tool output, or a repo) crafted to be interpreted as instructions.

**Mitigation (Today):** Log text is treated as **untrusted data**, never as
instructions. The scanners parse structured fields (`message.usage.*`, token
counts, timestamps, model names, rate-limit blocks) and ignore free-form
content. StackPulse contains no component that evaluates or acts on the natural-
language content of a log. Malformed or partial lines are skipped, not trusted.

### 3. Command injection

**Threat:** Crafted data causes StackPulse to build and run a shell command.

**Mitigation (Today):** StackPulse **executes no external commands** in v0.1.0.
There is no shell invocation, no `Command`/`exec`, and no template that turns
data into a command line. Detection is done by inspecting the filesystem, not by
running provider CLIs.

### 4. Symlink attacks / path traversal

**Threat:** A symlink inside a scanned directory points outside the intended
root (or into a loop), causing the scanner to read unintended files or spin.

**Mitigation (Today):** The recursive file collector **does not follow symlinked
directories** (it checks `file_type().is_symlink()` and skips them), which
prevents both symlink loops and escaping an approved root. Traversal is also
**depth-bounded** (Claude depth 6, Codex depth 7) to cap work on a mis-pointed
root, and only files matching the expected extension are read.

### 5. Untrusted / tampered compatibility manifests (Planned feature)

**Threat:** A malicious "compatibility manifest" reconfigures the app or injects
behavior.

**Mitigation (Planned):** Manifests will be **signed** and verified against a
**public key pinned in the binary**; they must **validate against a versioned
schema**; and they are **declarative data only** — no executable code, scripts,
or expressions. On any verification/validation failure the app keeps its
**last-known-good** manifest, and with no valid manifest it uses compiled-in
defaults. See [`COMPATIBILITY.md`](COMPATIBILITY.md). No manifest fetching exists
in v0.1.0, so the current attack surface here is zero.

### 6. Native-messaging host impersonation (Planned feature)

**Threat:** A rogue local process pretends to be the Chrome extension (or the
StackPulse host) to exfiltrate data or issue commands over the native-messaging
channel.

**Mitigation (Planned):** The native host is not built yet, so there is no such
channel in v0.1.0. When it ships, the design calls for the browser's native-
messaging manifest to pin the **allowed extension ID(s)**, the host to speak only
the versioned JSON protocol, and the host to expose read-only operations by
default — mirroring the core's read-only posture. Until then, there is nothing to
impersonate.

### 7. Localhost API exposure (Planned feature)

**Threat:** A locally bound HTTP/IPC server lets any local process (or a web page
via DNS-rebinding-style tricks) read usage data or drive the app.

**Mitigation (Today):** StackPulse **opens no listening socket**. The macOS app
links the core **in-process** over the C ABI — there is no localhost server, no
port, and no IPC endpoint to reach. If a local API is ever introduced it will be
opt-in, authenticated, and off by default.

### 8. Secret leakage

**Threat:** Secrets (tokens, keys) end up in logs, snapshots, crash output, or
the UI.

**Mitigation (Today):** StackPulse **never reads secret values**. Auth is
detected by the *presence* of a credential file or Keychain item. The
`UsageSnapshot` contains only usage/pricing data — no credential material — so
there is nothing sensitive to leak through the protocol, the CLI's `--json`
output, or the popover. There is no telemetry that could carry a secret off the
machine.

### 9. Token theft

**Threat:** The tool is used as a vector to read and steal a provider auth token.

**Mitigation (Today):** The portable core **cannot** read the macOS Keychain by
design. The Swift Keychain probe queries with `kSecReturnData: false`, i.e. it
asks "does an item exist?" and explicitly requests **no** secret data — which
also means it does not trigger the Keychain "allow access" prompt and cannot
return the token. File-based credential checks likewise test for existence, not
contents. StackPulse holds no code path that materializes a token.

### 10. Unsafe package / postinstall scripts

**Threat:** Installing or building the tool runs arbitrary code via dependency
install hooks or lifecycle scripts.

**Mitigation (Today):** The core has a **minimal dependency surface** (serde /
serde_json) and no build scripts that fetch or execute remote content. The macOS
app is built with SwiftPM from source in this repo. There is no `npm`/postinstall
step in the shipping product. Contributors should keep the dependency set small
and review any new dependency's build scripts (see
[`CONTRIBUTING.md`](../CONTRIBUTING.md)).

### 11. Destructive automation

**Threat:** The tool deletes, moves, or overwrites user data, or takes
irreversible actions.

**Mitigation (Today):** All scanning is **read-only**. StackPulse never writes to,
moves, or deletes provider data, and performs no remote control actions (reply /
approve / stop / resume are all `unsupported` for the active providers — see
[`CAPABILITIES.md`](CAPABILITIES.md)). The only files the app writes are its own
local UI state.

## Cross-cutting hardening

Beyond the per-threat mitigations:

- **Panic containment.** A panic inside a provider scan is caught
  (`catch_unwind`) and downgraded to a `temporarily_broken` provider record; a
  panic at the FFI boundary is caught and converted to a JSON error (unwinding
  across FFI is undefined behavior, so this is a correctness *and* safety
  measure).
- **Explicit FFI memory contract.** Every string the core returns is owned by
  the caller and freed exactly once via `sp_core_string_free`; input pointers are
  borrowed and validated (null and non-UTF-8 inputs yield JSON errors, not
  crashes). See [ADR-0003](decisions/0003-rust-core-c-abi-bridge.md).
- **Bounded work.** Scans are limited to ~35 days of recently modified files and
  a fixed directory depth, bounding both time and the blast radius of a
  mis-configured root.
- **Deterministic, testable core.** The clock is injected, so behavior is
  reproducible under test — which makes security-relevant parsing logic auditable.

## Trust boundaries summary

| Boundary | Trusted? | Notes |
| --- | --- | --- |
| Local session logs | **No** (untrusted data) | Parsed for numbers only; never executed or interpreted. |
| The Rust core (in-process) | Yes | No network, no exec, read-only. |
| The C ABI surface | Yes, with a strict memory/UTF-8 contract | JSON in / JSON out; panic-safe. |
| macOS Keychain | Read presence only | Never fetches secret data. |
| Compatibility manifest (Planned) | Only if signed + schema-valid | Declarative data, key-pinned, last-known-good. |
| Native host / local API | N/A in v0.1.0 | Not built; designed read-only when they are. |

## Non-goals for v0.1.0

StackPulse v0.1.0 does not attempt to defend against a **compromised local user
account** (an attacker who already runs code as the user can read the same logs
directly), nor against vulnerabilities inside the third-party AI tools whose logs
it reads. These are out of scope, consistent with [`SECURITY.md`](../SECURITY.md).
