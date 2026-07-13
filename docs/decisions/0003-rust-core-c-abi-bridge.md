# ADR-0003: Bridge Swift to the Rust core with a JSON-over-C-ABI FFI

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

The Swift app needs to call the Rust core. Options for the boundary include:

1. Mirror every Rust type in Swift and marshal rich C structs across the FFI.
2. Run the core as a subprocess and pipe data (e.g. the CLI).
3. A tiny C ABI that passes **JSON strings** in and out, linked in-process.

Mirroring structs (1) creates a large, brittle surface: every protocol change
means matching Swift struct changes and hand-written marshaling, and it is easy
to get memory ownership wrong across the boundary. A subprocess (2) adds process
management, latency, and an IPC channel to secure. We already serialize the whole
protocol to JSON for the CLI, and Swift has first-class JSON decoding.

## Decision

**Expose the core through a minimal C ABI whose entire data surface is JSON
strings**, and link it into the Swift app in-process.

The C ABI (in `stackpulse-ffi`, built as `staticlib` + `cdylib`) is three
functions:

- `char *sp_core_handle_request(const char *request_json)` — decode a
  `CoreRequest`, dispatch it, return a `CoreResponse` as JSON.
- `char *sp_core_version(void)` — return the core version string.
- `void  sp_core_string_free(char *s)` — free a string returned by this library.

Swift sends `{"op":"..."}` requests and decodes the returned JSON into value
types — the **same JSON** the `stackpulse` CLI prints. There is no struct mirror
to keep in sync; a protocol change is absorbed by JSON decoding rules (unknown
keys ignored, open enums decoded as strings).

## Memory contract

Every `char*` returned by the library is heap-allocated by Rust and **must** be
released exactly once via `sp_core_string_free` — never with C `free`, never
twice. Input pointers are borrowed for the duration of the call and never freed
by the library. A null or non-UTF-8 input returns a JSON error object rather than
crashing. The header (`stackpulse_core.h`) documents this contract and must stay
in sync with the Rust implementation. On the Swift side, `CoreBridge` frees every
returned string in a `defer`, honoring the contract.

## Panic safety

Unwinding across an FFI boundary is undefined behavior, so every entry point
wraps its work in `catch_unwind` and converts a panic into a JSON error string.

## Consequences

- **Positive:** A tiny, stable ABI surface — three functions — that rarely
  changes even as the protocol grows.
- **Positive:** Swift decodes exactly what the CLI emits, so the CLI is a faithful
  debugging stand-in for the app, and there is a single serialization format to
  reason about.
- **Positive:** In-process linking means no subprocess, no socket, no IPC channel
  to secure (see [`SECURITY_BOUNDARIES.md`](../SECURITY_BOUNDARIES.md)).
- **Negative / cost:** JSON (de)serialization on each call has a small overhead
  versus passing structs directly. For a monitor that scans on a multi-second
  cadence, this is negligible, and the scan itself dominates.
- **Negative:** The caller must respect the manual memory contract; we mitigate
  by documenting it in the header and centralizing frees in `CoreBridge`.
