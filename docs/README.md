# Documentation

Reference documentation for StackPulse. Start with **ARCHITECTURE** to learn
where code belongs, then read the doc closest to what you're changing.

| Document | What's in it |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The portable engine / native-shell split — the moving parts, who owns what, and the rules that keep the system honest, portable, and resilient. Read this first. |
| [CAPABILITIES.md](CAPABILITIES.md) | Why each integration is described as a matrix of fine-grained capabilities rather than a single "supported" boolean, and what each state means. |
| [COMPATIBILITY.md](COMPATIBILITY.md) | How the project tracks each integration's health as third-party formats and auth evolve, and the design of the signed compatibility manifest. |
| [PROTOCOL.md](PROTOCOL.md) | The `stackpulse-protocol` versioned, platform-neutral wire contract shared by the core, the macOS app (over the C ABI), the CLI, and future clients. |
| [SECURITY_BOUNDARIES.md](SECURITY_BOUNDARIES.md) | The threat model — the threats the project takes seriously and how the current v0.1.0 design mitigates each (see also [SECURITY.md](../SECURITY.md) for reporting). |
| [USAGE.md](USAGE.md) | How to build it, run it, read it, and know when not to trust it — describing what the code does today, and saying so where it doesn't. |

**Design decisions** live in [`decisions/`](decisions/) as numbered ADRs
(0001 onward) — one per architectural choice, with its context and consequences.

**Cross-repo contract changes** — protocol, portable-core behavior, and the
capability taxonomy — are logged in
[CROSS_REPO_CHANGELOG.md](CROSS_REPO_CHANGELOG.md).
