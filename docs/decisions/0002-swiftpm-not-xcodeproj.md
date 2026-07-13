# ADR-0002: Build the macOS app as a Swift Package, not an Xcode project

- **Status:** Accepted
- **Date:** 2026-07-12

## Context

The macOS app must link the Rust portable core (a static library) and run as an
`NSStatusItem` menu-bar accessory with a SwiftUI popover. There are two common
ways to structure a macOS app: an Xcode project (`.xcodeproj` built with
`xcodebuild`), or a Swift Package (`Package.swift` built with SwiftPM).

Constraints on the build environment:

- The development machine has **Command Line Tools only** — no full Xcode — so
  `xcodebuild` and `.xcodeproj`-centric workflows are not available. SwiftPM
  (`swift build` / `swift run`) is.
- The repository path can contain spaces, which breaks fragile absolute paths in
  build settings.
- We want the app to link the Rust core **in-process** as a static archive, with
  a C ABI header exposed as a system-library target.
- OpenUsage (our reference) is also a SwiftPM executable, so this keeps us close
  to a known-good structure.

## Decision

**Ship the macOS app as a SwiftPM executable package** (`apps/StackPulseMac`),
targeting macOS 14+, Swift 6 language mode.

- A `systemLibrary` target (`CStackPulseCore`) exposes the C ABI header via a
  module map.
- An `executableTarget` (`StackPulseApp`) links `libstackpulse_ffi.a` (produced
  by `cargo build -p stackpulse-ffi --release`) using linker flags, plus the
  system frameworks the Rust std references on macOS (CoreFoundation, Security,
  SystemConfiguration, iconv).
- The static-library search path is **relative** (`-L ../../target/release`) so a
  repo path with spaces does not break the build; the app is built from the
  `apps/StackPulseMac` directory.

## Consequences

- **Positive:** Builds with only Command Line Tools; no Xcode dependency; simple
  `swift build` / `swift run` workflow, including headless `--dump` / `--version`
  verification modes.
- **Positive:** Single binary — the Rust core is linked in-process, so there is
  no subprocess or IPC (which also removes a class of security concerns; see
  [`SECURITY_BOUNDARIES.md`](../SECURITY_BOUNDARIES.md)).
- **Positive:** Relative link path tolerates spaces in the repository path.
- **Negative / cost:** Xcode-only conveniences (asset catalogs, Interface
  Builder, some signing/packaging UI) are not available; packaging (signing,
  notarization, DMG, Sparkle) will be scripted rather than driven by Xcode. That
  is acceptable and is the Planned distribution approach.
- **Negative:** Linker settings use `unsafeFlags`, which prevents the package
  from being consumed as a dependency by other packages — irrelevant here since
  it is a leaf application target.
