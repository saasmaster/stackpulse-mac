//! Request dispatcher and snapshot assembler.
//!
//! The engine owns the provider registry and turns a [`CoreRequest`] into a
//! [`CoreResponse`]. Every provider scan is isolated: a panic or error in one
//! provider is caught and downgraded to a degraded [`ProviderUsage`] so the
//! rest of the snapshot still renders (spec: graceful degradation).

use crate::datetime::{now_unix, utc_date};
use crate::pricing::PRICING_AS_OF;
use crate::providers::{
    antigravity::AntigravityProvider, claude::ClaudeProvider, codex::CodexProvider,
    detection::detection_providers, Provider,
};
use stackpulse_protocol::{
    CoreError, CoreRequest, CoreResponse, ErrorCode, IntegrationHealth, ProviderId, ProviderUsage,
    UsageSnapshot, Version, PROTOCOL_VERSION,
};

/// The core engine. Cheap to construct; holds the provider registry.
pub struct Engine {
    providers: Vec<Box<dyn Provider>>,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    pub fn new() -> Self {
        // Full local scanners first (Claude, Codex, Antigravity), then the eight
        // detection-only providers in the ProviderId enum's declared order
        // (Copilot, Cursor, Devin, Gemini, Grok, OpenCode, OpenRouter, Zai).
        // Every snapshot therefore lists all eleven providers.
        let mut providers: Vec<Box<dyn Provider>> = vec![
            Box::new(ClaudeProvider),
            Box::new(CodexProvider),
            Box::new(AntigravityProvider),
        ];
        for p in detection_providers() {
            providers.push(Box::new(p));
        }
        Engine { providers }
    }

    pub fn core_version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    /// Handle a typed request. Never panics.
    pub fn handle(&self, request: CoreRequest) -> CoreResponse {
        match request {
            CoreRequest::Ping => CoreResponse::Pong {
                protocol_version: PROTOCOL_VERSION,
                core_version: self.core_version(),
            },
            CoreRequest::GetProviderStatus => CoreResponse::ProviderStatus {
                providers: self.providers.iter().map(|p| p.status()).collect(),
            },
            CoreRequest::GetUsageSnapshot { providers } => {
                CoreResponse::UsageSnapshot(self.snapshot(providers.as_deref()))
            }
            CoreRequest::GetProjects { roots, max_depth } => CoreResponse::Projects {
                projects: crate::projects::discover(&roots, max_depth.unwrap_or(4)),
            },
            CoreRequest::RecordHistory { data_dir, days } => {
                let snap = self.snapshot(None);
                CoreResponse::History {
                    points: crate::history::record(&data_dir, &snap, now_unix(), days),
                }
            }
            CoreRequest::GetHistory { data_dir, days } => CoreResponse::History {
                points: crate::history::query(&data_dir, days, now_unix()),
            },
            CoreRequest::GetStackHealth {
                roots,
                max_depth,
                check_updates,
            } => CoreResponse::StackHealth {
                projects: crate::stack_health::analyze(
                    &roots,
                    max_depth.unwrap_or(4),
                    check_updates,
                ),
            },
            CoreRequest::GetServices { roots } => CoreResponse::Services {
                services: crate::services::detect(&roots),
            },
            CoreRequest::GetRadar { roots, max_depth } => {
                CoreResponse::Radar(crate::radar::analyze(&roots, max_depth.unwrap_or(4)))
            }
            CoreRequest::GetProjectUsage => CoreResponse::ProjectUsage {
                projects: crate::project_usage::analyze(now_unix()),
            },
            CoreRequest::CreateCheckpoint {
                project_path,
                label,
            } => {
                let (checkpoints, note) =
                    crate::checkpoints::create(&project_path, label.as_deref(), now_unix());
                CoreResponse::Checkpoints { checkpoints, note }
            }
            CoreRequest::ListCheckpoints { project_path } => {
                let (checkpoints, note) = crate::checkpoints::list(&project_path);
                CoreResponse::Checkpoints { checkpoints, note }
            }
            CoreRequest::ListWorktrees { project_path } => {
                let (worktrees, note) = crate::worktrees::list(&project_path);
                CoreResponse::Worktrees { worktrees, note }
            }
            CoreRequest::CreateWorktree {
                project_path,
                worktrees_dir,
                name,
            } => {
                let (worktrees, note) =
                    crate::worktrees::create(&project_path, &worktrees_dir, &name);
                CoreResponse::Worktrees { worktrees, note }
            }
        }
    }

    /// Handle a JSON request string, returning a JSON response string. This is
    /// the single entry point used by the FFI and the CLI.
    pub fn handle_json(&self, request_json: &str) -> String {
        let response = match serde_json::from_str::<CoreRequest>(request_json) {
            Ok(req) => self.handle(req),
            Err(e) => CoreResponse::Error(CoreError::new(
                ErrorCode::BadRequest,
                format!("could not parse request: {e}"),
            )),
        };
        // Serializing our own types cannot fail; fall back defensively.
        serde_json::to_string(&response).unwrap_or_else(|_| {
            r#"{"kind":"error","code":"internal","message":"serialization failed"}"#.to_string()
        })
    }

    fn snapshot(&self, filter: Option<&[ProviderId]>) -> UsageSnapshot {
        let now = now_unix();
        let mut provider_usages: Vec<ProviderUsage> = Vec::new();

        for provider in &self.providers {
            if let Some(ids) = filter {
                if !ids.contains(&provider.id()) {
                    continue;
                }
            }
            // Isolate each scan: catch panics so one bad provider can't abort
            // the snapshot. `AssertUnwindSafe` is sound here — on panic we drop
            // any partial state and emit a degraded record.
            let id = provider.id();
            let result =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| provider.scan(now)));
            match result {
                Ok(usage) => provider_usages.push(usage),
                Err(_) => provider_usages.push(degraded(id)),
            }
        }

        let missions = crate::missions::discover(now);
        let alerts = crate::alerts::derive_alerts(&provider_usages, now);
        let insights = crate::insights::derive(&provider_usages, &missions, now);

        UsageSnapshot {
            protocol_version: PROTOCOL_VERSION,
            core_version: self.core_version(),
            generated_at_unix: now,
            bucket_date_utc: utc_date(now).iso(),
            providers: provider_usages,
            alerts,
            missions,
            insights,
            pricing_note: format!(
                "Costs are local estimates from an embedded price table (list prices as of {PRICING_AS_OF}); verify against your provider billing."
            ),
        }
    }
}

/// A minimal, safe placeholder emitted when a provider scan panics.
fn degraded(id: ProviderId) -> ProviderUsage {
    ProviderUsage {
        provider: id,
        display_name: id.display_name().to_string(),
        health: IntegrationHealth::TemporarilyBroken,
        installed: false,
        authenticated: false,
        detected_version: None,
        plan_hint: None,
        windows: Vec::new(),
        models: Vec::new(),
        limits: Vec::new(),
        capabilities: Vec::new(),
        notes: vec!["This integration hit an internal error and was skipped for this scan.".into()],
        analytics: None,
        balance: None,
    }
}

/// Free-standing version accessor for callers without an `Engine`.
pub fn core_version() -> Version {
    // Parse from Cargo, tolerant of a missing patch.
    let raw = env!("CARGO_PKG_VERSION");
    let mut it = raw.split('.').map(|p| p.parse::<u16>().unwrap_or(0));
    Version {
        major: it.next().unwrap_or(0),
        minor: it.next().unwrap_or(0),
        patch: it.next().unwrap_or(0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_roundtrips_through_json() {
        let engine = Engine::new();
        let out = engine.handle_json(r#"{"op":"ping"}"#);
        assert!(out.contains("pong"));
        assert!(out.contains("core_version"));
    }

    #[test]
    fn bad_request_is_structured_error() {
        let engine = Engine::new();
        let out = engine.handle_json("not json");
        assert!(out.contains("\"kind\":\"error\""));
        assert!(out.contains("bad_request"));
    }

    #[test]
    fn snapshot_is_well_formed() {
        let engine = Engine::new();
        let out = engine.handle_json(r#"{"op":"get_usage_snapshot"}"#);
        assert!(out.contains("usage_snapshot"));
        assert!(out.contains("bucket_date_utc"));
        // Both registered providers appear regardless of local install state.
        assert!(out.contains("\"claude\""));
        assert!(out.contains("\"codex\""));
    }
}
