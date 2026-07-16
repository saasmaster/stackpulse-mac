//! # stackpulse-core
//!
//! The portable StackPulse engine. It detects supported AI-coding providers on
//! the machine, scans their local logs for token usage, estimates cost, and
//! returns a normalized [`stackpulse_protocol::UsageSnapshot`].
//!
//! **Portability contract (ADR-0005):** this crate must build for non-macOS
//! targets. It contains no AppKit/SwiftUI, no Keychain access, and no hardcoded
//! platform paths — only `std` and environment-driven discovery. macOS-specific
//! concerns live in the Swift app; the Chrome native host and a future Windows
//! client reuse this crate unchanged.
//!
//! The two public entry points are [`Engine`] (typed) and
//! [`handle_request_json`] (string-in / string-out, used by the FFI and CLI).

pub mod alerts;
pub mod datetime;
pub mod engine;
pub mod history;
pub mod insights;
pub mod missions;
pub mod paths;
pub mod pricing;
pub mod project_usage;
pub mod projects;
pub mod providers;
pub mod radar;
pub mod scope_guard;
pub mod services;
pub mod stack_health;

pub use engine::{core_version, Engine};

/// Convenience wrapper: parse a JSON [`stackpulse_protocol::CoreRequest`],
/// dispatch it, and return a JSON [`stackpulse_protocol::CoreResponse`].
///
/// A fresh [`Engine`] is cheap to build, so callers that only make occasional
/// requests can use this directly; long-lived callers should hold an `Engine`.
pub fn handle_request_json(request_json: &str) -> String {
    Engine::new().handle_json(request_json)
}

/// The core's own semantic version, as a string (e.g. "0.1.0").
pub fn version_string() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
