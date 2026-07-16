//! Codex (OpenAI Codex CLI) adapter.
//!
//! Local cost scan reads `$CODEX_HOME/sessions/**/*.jsonl` and
//! `archived_sessions/**/*.jsonl`. Session files are JSON-lines of
//! `{timestamp, type, payload}`:
//! - `turn_context` payload carries the active `model`.
//! - `session_meta` payload carries `cli_version` and `model_provider`.
//! - `event_msg` payload of type `token_count` carries `info.last_token_usage`
//!   (the per-turn delta — we sum these, NOT the cumulative `total_token_usage`)
//!   and `rate_limits` (real 5-hour / weekly windows, captured with no network).
//!
//! OpenAI counts `input_tokens` as the *total* prompt including the cached
//! portion, so we normalize to the exclusive-input convention:
//! `fresh_input = input - cached`, `cache_read = cached`.

use super::{aggregate, caps, compute_analytics, Provider, UsageRecord};
use crate::datetime::parse_iso_date;
use crate::paths;
use serde_json::Value;
use stackpulse_protocol::{
    Capability as Cap, CapabilityState, IntegrationHealth, LimitWindow, Provenance, ProviderId,
    ProviderStatus, ProviderUsage, TokenTotals,
};
use std::collections::HashSet;
use std::io::BufRead;
use std::path::PathBuf;

const SCAN_WINDOW_DAYS: i64 = 35;

pub struct CodexProvider;

/// Mutable state threaded through a single scan.
#[derive(Default)]
struct ScanState {
    records: Vec<UsageRecord>,
    seen: HashSet<(String, u64, u64)>,
    detected_version: Option<String>,
    plan_hint: Option<String>,
    latest_limits_ts: Option<String>,
    latest_limits: Vec<LimitWindow>,
}

impl CodexProvider {
    fn auth_present(&self) -> bool {
        for root in paths::codex_roots() {
            if root.join("auth.json").is_file() {
                return true;
            }
        }
        // Codex also honors ~/.config/codex/auth.json.
        if let Some(home) = paths::home_dir() {
            if home
                .join(".config")
                .join("codex")
                .join("auth.json")
                .is_file()
            {
                return true;
            }
        }
        std::env::var("OPENAI_API_KEY")
            .map(|v| !v.is_empty())
            .unwrap_or(false)
    }
}

impl Provider for CodexProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Codex
    }

    fn capabilities(&self) -> Vec<(Cap, CapabilityState)> {
        let mut c = caps(
            &[
                Cap::InstalledAppDetection,
                Cap::VersionDetection,
                Cap::AuthDetection,
                Cap::LocalCostScan,
                Cap::ModelBreakdown,
                Cap::CacheMetrics,
                Cap::LocalSessionHistory,
                // Codex logs embed provider-reported rate-limit windows.
                Cap::SessionLimits,
                Cap::WeeklyLimits,
            ],
            &[
                Cap::Reply,
                Cap::ApproveReject,
                Cap::Stop,
                Cap::Resume,
                Cap::RemoteTaskState,
                Cap::ConversationPreview,
            ],
        );
        c.push((Cap::CreditsAndSpend, CapabilityState::Unavailable));
        c.push((Cap::ProjectAssociation, CapabilityState::Unavailable));
        c
    }

    fn status(&self) -> ProviderStatus {
        let installed = !paths::codex_roots().is_empty();
        ProviderStatus {
            provider: ProviderId::Codex,
            display_name: ProviderId::Codex.display_name().to_string(),
            installed,
            authenticated: self.auth_present(),
            health: if installed {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            detected_version: None,
        }
    }

    fn scan(&self, now_unix: i64) -> ProviderUsage {
        let roots = paths::codex_roots();
        let installed = !roots.is_empty();
        let authenticated = self.auth_present();
        let mtime_cutoff = now_unix - SCAN_WINDOW_DAYS * 86_400;

        let mut state = ScanState::default();
        for root in &roots {
            for sub in ["sessions", "archived_sessions"] {
                let dir = root.join(sub);
                if !dir.is_dir() {
                    continue;
                }
                let files = paths::collect_files(&dir, 7, &|name| name.ends_with(".jsonl"));
                for file in files {
                    if !recently_modified(&file, mtime_cutoff) {
                        continue;
                    }
                    scan_file(&file, now_unix, &mut state);
                }
            }
        }

        let (windows, models, unpriceable) = aggregate(&state.records, now_unix);
        let analytics = compute_analytics(&state.records, now_unix);
        let mut notes = Vec::new();
        if !unpriceable.is_empty() {
            notes.push(format!(
                "{} model(s) had no pricing and are excluded from cost estimates: {}",
                unpriceable.len(),
                unpriceable.join(", ")
            ));
        }
        if installed && state.records.is_empty() {
            notes.push("No Codex session activity in the last 35 days.".into());
        }

        ProviderUsage {
            provider: ProviderId::Codex,
            display_name: ProviderId::Codex.display_name().to_string(),
            health: if installed {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            installed,
            authenticated,
            detected_version: state.detected_version,
            plan_hint: state.plan_hint,
            windows,
            models,
            limits: state.latest_limits,
            capabilities: self.capabilities(),
            notes,
            analytics: Some(analytics),
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
        Err(_) => true,
    }
}

fn scan_file(file: &PathBuf, now_unix: i64, state: &mut ScanState) {
    let f = match std::fs::File::open(file) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = std::io::BufReader::new(f);
    // The active model comes from the most recent `turn_context` in this file.
    let mut current_model = String::new();

    for line in reader.lines().map_while(Result::ok) {
        if line.is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = v.get("type").and_then(Value::as_str).unwrap_or("");
        let ts = v.get("timestamp").and_then(Value::as_str).unwrap_or("");
        let payload = match v.get("payload") {
            Some(p) => p,
            None => continue,
        };

        match kind {
            "turn_context" => {
                if let Some(m) = payload.get("model").and_then(Value::as_str) {
                    current_model = m.to_string();
                }
            }
            "session_meta" => {
                if state.detected_version.is_none() {
                    if let Some(cv) = payload.get("cli_version").and_then(Value::as_str) {
                        state.detected_version = Some(cv.to_string());
                    }
                }
            }
            "event_msg" => {
                if payload.get("type").and_then(Value::as_str) != Some("token_count") {
                    continue;
                }
                capture_rate_limits(payload, ts, now_unix, state);
                let Some(last) = payload.get("info").and_then(|i| i.get("last_token_usage")) else {
                    continue;
                };
                let input = last
                    .get("input_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let cached = last
                    .get("cached_input_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let output = last
                    .get("output_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let reasoning = last
                    .get("reasoning_output_tokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                if input + output + reasoning == 0 {
                    continue;
                }
                // Dedup across sessions/ vs archived_sessions/ duplicates.
                let key = (ts.get(0..19).unwrap_or(ts).to_string(), input, output);
                if !state.seen.insert(key) {
                    continue;
                }
                let date = match parse_iso_date(ts) {
                    Some(d) => d,
                    None => continue,
                };
                let fresh_input = input.saturating_sub(cached);
                state.records.push(UsageRecord {
                    model: if current_model.is_empty() {
                        "unknown".to_string()
                    } else {
                        current_model.clone()
                    },
                    date,
                    tokens: TokenTotals {
                        input_tokens: fresh_input,
                        output_tokens: output,
                        cache_creation_tokens: 0,
                        cache_read_tokens: cached,
                        reasoning_tokens: reasoning,
                    },
                });
            }
            _ => {}
        }
    }
}

/// Track the most recent `rate_limits` block seen across all files; it reflects
/// the current 5-hour / weekly window state as of the last logged turn.
fn capture_rate_limits(payload: &Value, ts: &str, now_unix: i64, state: &mut ScanState) {
    let Some(rl) = payload.get("rate_limits") else {
        return;
    };
    // Only keep the newest by timestamp string (ISO-8601 sorts lexicographically).
    if let Some(prev) = &state.latest_limits_ts {
        if ts <= prev.as_str() {
            return;
        }
    }
    let mut windows = Vec::new();
    for (key, default_minutes) in [("primary", 300u32), ("secondary", 10_080u32)] {
        if let Some(w) = rl.get(key) {
            if w.is_null() {
                continue;
            }
            let used = w.get("used_percent").and_then(Value::as_f64).unwrap_or(0.0);
            let minutes = w
                .get("window_minutes")
                .and_then(Value::as_u64)
                .map(|m| m as u32)
                .unwrap_or(default_minutes);
            let resets = w.get("resets_at").and_then(Value::as_i64);
            // A window whose reset time has passed no longer exists: usage started
            // over from zero. Reporting the last-seen percentage for it isn't
            // merely stale, it's false — and it reaches the user loudly, because
            // `alerts.rs` raises a *critical* "Codex 5h limit at 96%" from it and
            // the app turns new alerts into macOS notifications. Sessions are
            // scanned for 35 days back, so an old file's expired 5-hour window
            // would otherwise be replayed as current for weeks.
            //
            // Dropped rather than zeroed: we don't know the new window's usage
            // until Codex writes one, and inventing 0% would be its own lie.
            if let Some(resets_at) = resets {
                if resets_at < now_unix {
                    continue;
                }
            }
            windows.push(LimitWindow {
                // Label from the actual window duration, not the primary/secondary
                // slot — Codex sometimes reports only one window, so a weekly
                // window must never be mislabeled "5h".
                label: window_label(minutes),
                used_percent: used,
                window_minutes: minutes,
                resets_at_unix: resets,
                provenance: Provenance::ProviderReported,
            });
        }
    }
    if let Some(plan) = rl.get("plan_type").and_then(Value::as_str) {
        state.plan_hint = Some(plan.to_string());
    }
    if !windows.is_empty() {
        state.latest_limits_ts = Some(ts.to_string());
        state.latest_limits = windows;
    }
}

/// Human label for a rate-limit window derived from its duration, so the label
/// always matches the window (300 → "5h", 10080 → "weekly", 1440 → "1d", …).
/// The Swift UI maps "5h"/"weekly" to friendly names and shows others verbatim.
fn window_label(minutes: u32) -> String {
    match minutes {
        0 => "window".to_string(),
        10_080 => "weekly".to_string(),
        m if m % 1440 == 0 => format!("{}d", m / 1440),
        m if m % 60 == 0 => format!("{}h", m / 60),
        m => format!("{m}m"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_token_count_and_limits() {
        let meta = r#"{"timestamp":"2026-07-12T09:00:00.000Z","type":"session_meta","payload":{"cli_version":"1.2.3","model_provider":"openai"}}"#;
        let ctx = r#"{"timestamp":"2026-07-12T09:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#;
        let tok = r#"{"timestamp":"2026-07-12T09:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":50}},"rate_limits":{"primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1779942915},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1780529715},"plan_type":"plus"}}}"#;

        let dir = std::env::temp_dir().join(format!("sp-codex-test-{}", std::process::id()));
        let sessions = dir.join("sessions").join("2026").join("07").join("12");
        std::fs::create_dir_all(&sessions).unwrap();
        let file = sessions.join("rollout.jsonl");
        std::fs::write(&file, format!("{meta}\n{ctx}\n{tok}\n")).unwrap();

        let mut state = ScanState::default();
        // A clock before both fixture reset times, so the windows are still open.
        scan_file(&file, 1_779_000_000, &mut state);

        assert_eq!(state.records.len(), 1);
        let r = &state.records[0];
        assert_eq!(r.model, "gpt-5.5");
        assert_eq!(r.tokens.input_tokens, 600); // 1000 - 400 cached
        assert_eq!(r.tokens.cache_read_tokens, 400);
        assert_eq!(r.tokens.reasoning_tokens, 50);
        assert_eq!(state.detected_version.as_deref(), Some("1.2.3"));
        assert_eq!(state.plan_hint.as_deref(), Some("plus"));
        assert_eq!(state.latest_limits.len(), 2);
        // Labels derive from the window duration, not the primary/secondary slot.
        assert_eq!(state.latest_limits[0].label, "5h"); // 300 min
        assert_eq!(state.latest_limits[1].label, "weekly"); // 10080 min

        std::fs::remove_dir_all(&dir).ok();
    }

    /// A rate-limit window whose reset time has passed no longer exists — usage
    /// restarted from zero. Replaying the last-seen percentage would be false, and
    /// loudly so: `alerts.rs` turns a high percentage into a *critical* alert and
    /// the app raises a macOS notification from it. Sessions are scanned 35 days
    /// back, so without this an old file's expired 5-hour window would be reported
    /// as current for weeks.
    #[test]
    fn expired_limit_windows_are_dropped_not_replayed() {
        let ctx = r#"{"timestamp":"2026-07-12T09:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#;
        // primary resets at 1_779_942_915; secondary at 1_780_529_715.
        let tok = r#"{"timestamp":"2026-07-12T09:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}},"rate_limits":{"primary":{"used_percent":96.0,"window_minutes":300,"resets_at":1779942915},"secondary":{"used_percent":32.0,"window_minutes":10080,"resets_at":1780529715}}}}"#;

        let dir = std::env::temp_dir().join(format!("sp-codex-expiry-{}", std::process::id()));
        let sessions = dir.join("sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let file = sessions.join("rollout.jsonl");
        std::fs::write(&file, format!("{ctx}\n{tok}\n")).unwrap();

        // Clock AFTER the 5h window reset but BEFORE the weekly one.
        let mut state = ScanState::default();
        scan_file(&file, 1_780_000_000, &mut state);

        // The expired 96% window must be gone — that is the false critical alert.
        assert!(
            !state.latest_limits.iter().any(|l| l.label == "5h"),
            "an expired window must not be reported: {:?}",
            state.latest_limits
        );
        // ...while the window that is still open survives untouched.
        assert_eq!(state.latest_limits.len(), 1);
        assert_eq!(state.latest_limits[0].label, "weekly");
        assert_eq!(state.latest_limits[0].used_percent, 32.0);

        // Every window expired ⇒ report none rather than inventing 0%.
        let mut later = ScanState::default();
        scan_file(&file, 4_000_000_000, &mut later);
        assert!(later.latest_limits.is_empty());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn window_label_matches_duration() {
        assert_eq!(window_label(300), "5h");
        assert_eq!(window_label(10_080), "weekly");
        assert_eq!(window_label(1_440), "1d");
        assert_eq!(window_label(60), "1h");
        assert_eq!(window_label(45), "45m");
    }
}
