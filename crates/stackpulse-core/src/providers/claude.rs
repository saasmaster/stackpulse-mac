//! Claude (Claude Code) adapter.
//!
//! Local cost scan reads assistant turns from `{root}/projects/**/*.jsonl`,
//! where `root` follows Claude Code's own config resolution (see
//! [`crate::paths::claude_roots`]). Token counts come from `message.usage.*`;
//! Claude's `input_tokens` already excludes cached tokens, so it maps directly
//! onto our exclusive-input convention.
//!
//! We read only credential *presence* (never contents) for auth detection, and
//! we never make a network call in this version — everything here is local and
//! offline (spec: local-first, useful without an AI key).

use super::{aggregate, caps, compute_analytics, Provider, UsageRecord};
use crate::datetime::parse_iso_date;
use crate::paths;
use serde::Deserialize;
use stackpulse_protocol::{
    Capability as Cap, CapabilityState, IntegrationHealth, ProviderId, ProviderStatus,
    ProviderUsage, TokenTotals,
};
use std::collections::{HashMap, HashSet};
use std::io::BufRead;
use std::path::PathBuf;

/// Only scan session files modified within this many days — bounds work over a
/// large history and keeps the scan aligned with the 30-day window.
const SCAN_WINDOW_DAYS: i64 = 35;

pub struct ClaudeProvider;

#[derive(Deserialize)]
struct Line {
    #[serde(default, rename = "requestId")]
    request_id: Option<String>,
    #[serde(default)]
    timestamp: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    message: Option<Message>,
}

#[derive(Deserialize)]
struct Message {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Usage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
}

impl ClaudeProvider {
    fn credentials_present(&self) -> bool {
        // Presence only — we never read the token itself (that, and the macOS
        // Keychain path, are handled outside the portable core).
        for root in paths::claude_roots() {
            if root.join(".credentials.json").is_file() {
                return true;
            }
        }
        std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
            .map(|v| !v.is_empty())
            .unwrap_or(false)
    }
}

impl Provider for ClaudeProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Claude
    }

    fn capabilities(&self) -> Vec<(Cap, CapabilityState)> {
        // Honest matrix: strong local visibility, no remote control in this
        // build. Live limits exist behind an OAuth API we have not wired yet,
        // so they are Unavailable (implementable) rather than Unsupported.
        let mut c = caps(
            &[
                Cap::InstalledAppDetection,
                Cap::VersionDetection,
                Cap::AuthDetection,
                Cap::LocalCostScan,
                Cap::ModelBreakdown,
                Cap::CacheMetrics,
                Cap::LocalSessionHistory,
                Cap::ProjectAssociation,
            ],
            &[
                Cap::Reply,
                Cap::ApproveReject,
                Cap::Stop,
                Cap::Resume,
                Cap::RemoteTaskState,
                Cap::ConversationPreview,
                Cap::ToolCallVisibility,
            ],
        );
        for cap in [Cap::SessionLimits, Cap::WeeklyLimits, Cap::CreditsAndSpend] {
            c.push((cap, CapabilityState::Unavailable));
        }
        c
    }

    fn status(&self) -> ProviderStatus {
        let installed = !paths::claude_roots().is_empty();
        ProviderStatus {
            provider: ProviderId::Claude,
            display_name: ProviderId::Claude.display_name().to_string(),
            installed,
            authenticated: self.credentials_present(),
            health: if installed {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            detected_version: None,
        }
    }

    fn scan(&self, now_unix: i64) -> ProviderUsage {
        let roots = paths::claude_roots();
        let installed = !roots.is_empty();
        let authenticated = self.credentials_present();

        let mut records: Vec<UsageRecord> = Vec::new();
        let mut seen: HashSet<(String, String)> = HashSet::new();
        let mut version_counts: HashMap<String, u32> = HashMap::new();
        let mut notes: Vec<String> = Vec::new();
        let mtime_cutoff = now_unix - SCAN_WINDOW_DAYS * 86_400;

        for root in &roots {
            let projects = root.join("projects");
            if !projects.is_dir() {
                continue;
            }
            let files = paths::collect_files(&projects, 6, &|name| name.ends_with(".jsonl"));
            for file in files {
                if !recently_modified(&file, mtime_cutoff) {
                    continue;
                }
                scan_file(&file, &mut records, &mut seen, &mut version_counts);
            }
        }

        let (windows, models, unpriceable) = aggregate(&records, now_unix);
        if !unpriceable.is_empty() {
            notes.push(format!(
                "{} model(s) had no pricing and are excluded from cost estimates: {}",
                unpriceable.len(),
                unpriceable.join(", ")
            ));
        }
        if installed && records.is_empty() {
            notes.push("No Claude session activity in the last 35 days.".into());
        }

        let detected_version = version_counts
            .into_iter()
            .max_by_key(|(_, n)| *n)
            .map(|(v, _)| v);

        ProviderUsage {
            provider: ProviderId::Claude,
            display_name: ProviderId::Claude.display_name().to_string(),
            health: if installed {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            installed,
            authenticated,
            detected_version,
            plan_hint: None,
            windows,
            models,
            limits: Vec::new(), // live limits require the OAuth API (future)
            capabilities: self.capabilities(),
            notes,
            analytics: Some(compute_analytics(&records, now_unix)),
            balance: None,
        }
    }
}

fn recently_modified(path: &PathBuf, cutoff_unix: i64) -> bool {
    match std::fs::metadata(path).and_then(|m| m.modified()) {
        Ok(mtime) => mtime
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64 >= cutoff_unix)
            .unwrap_or(true),
        Err(_) => true, // if we can't tell, don't silently skip it
    }
}

fn scan_file(
    file: &PathBuf,
    records: &mut Vec<UsageRecord>,
    seen: &mut HashSet<(String, String)>,
    version_counts: &mut HashMap<String, u32>,
) {
    let f = match std::fs::File::open(file) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = std::io::BufReader::new(f);
    for line in reader.lines().map_while(Result::ok) {
        if line.is_empty() {
            continue;
        }
        let parsed: Line = match serde_json::from_str(&line) {
            Ok(p) => p,
            Err(_) => continue, // tolerate malformed / partial lines
        };
        if let Some(v) = &parsed.version {
            *version_counts.entry(v.clone()).or_insert(0) += 1;
        }
        let Some(msg) = parsed.message else { continue };
        let Some(usage) = msg.usage else { continue };
        // Only assistant turns carry usage; require a model to price it.
        let model = msg.model.unwrap_or_default();
        if model.is_empty() {
            continue;
        }
        let total = usage.input_tokens
            + usage.output_tokens
            + usage.cache_creation_input_tokens
            + usage.cache_read_input_tokens;
        if total == 0 {
            continue;
        }
        // Dedup by (message.id, requestId) — replays across resumed sessions
        // repeat the same turn. Fall back to always-include when id is absent.
        if let Some(id) = &msg.id {
            let key = (id.clone(), parsed.request_id.clone().unwrap_or_default());
            if !seen.insert(key) {
                continue;
            }
        }
        let date = match parsed.timestamp.as_deref().and_then(parse_iso_date) {
            Some(d) => d,
            None => continue, // undated turns can't be bucketed
        };
        records.push(UsageRecord {
            model,
            date,
            tokens: TokenTotals {
                input_tokens: usage.input_tokens,
                output_tokens: usage.output_tokens,
                cache_creation_tokens: usage.cache_creation_input_tokens,
                cache_read_tokens: usage.cache_read_input_tokens,
                reasoning_tokens: 0,
            },
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_dedups_lines() {
        let line = r#"{"requestId":"req_1","timestamp":"2026-07-12T10:00:00Z","version":"2.1.0","message":{"id":"msg_1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":20}}}"#;
        let dir = std::env::temp_dir().join(format!("sp-claude-test-{}", std::process::id()));
        let projects = dir.join("projects").join("proj");
        std::fs::create_dir_all(&projects).unwrap();
        let file = projects.join("s.jsonl");
        // Two identical (id,requestId) lines → should dedup to one record.
        std::fs::write(&file, format!("{line}\n{line}\n")).unwrap();

        let mut records = Vec::new();
        let mut seen = HashSet::new();
        let mut vc = HashMap::new();
        scan_file(&file, &mut records, &mut seen, &mut vc);
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].tokens.input_tokens, 100);
        assert_eq!(records[0].tokens.cache_read_tokens, 20);
        assert_eq!(vc.get("2.1.0"), Some(&2)); // version counted per line

        std::fs::remove_dir_all(&dir).ok();
    }
}
