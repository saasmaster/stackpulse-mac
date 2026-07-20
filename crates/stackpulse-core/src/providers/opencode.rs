//! OpenCode local usage scanner (sst/opencode terminal agent).
//!
//! Reads OpenCode's own on-disk session store to compute REAL per-model token
//! usage, exactly like the Claude/Codex scanners — offline, filesystem-only,
//! never panics, degrades to empty when OpenCode isn't installed.
//!
//! ## Two on-disk formats (both handled)
//! Current OpenCode (v1.18+) stores messages in a **SQLite** database at
//! `~/.local/share/opencode/opencode.db` (`message` table, one JSON `data` blob
//! per message). Older installs used **per-message JSON files** under
//! `~/.local/share/opencode/storage/…/message/…/*.json`. The blob shape is the
//! same in both, so one parser serves both; a message id dedups the overlap a
//! migration leaves behind.
//!
//! Only `role == "assistant"` messages carry `tokens`/`modelID`; user messages
//! are skipped. Costs are the app's own local estimates (`pricing`), never
//! OpenCode's — same provenance as every other provider. A model OpenCode used
//! that the price table doesn't know is reported as unpriceable, never guessed.
//!
//! SQLite reading is macOS-only (mirrors `antigravity`); on other targets the
//! portable legacy-JSON path still works and the DB path is a no-op.

use super::{aggregate, caps, compute_analytics, Provider, UsageRecord};
use crate::datetime::utc_date;
use crate::paths;
use serde::Deserialize;
use stackpulse_protocol::{
    Capability as Cap, CapabilityState, IntegrationHealth, ProviderId, ProviderStatus,
    ProviderUsage, TokenTotals,
};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Only count activity within this many days — matches the window we report and
/// bounds the work on a long-lived store.
const SCAN_WINDOW_DAYS: i64 = 35;
/// Legacy-JSON traversal depth under `storage/`.
const STORAGE_DEPTH: usize = 6;

pub struct OpenCodeProvider;

/// `~/.local/share/opencode` (respects `XDG_DATA_HOME`).
fn data_dir() -> Option<PathBuf> {
    if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
        let p = PathBuf::from(xdg);
        if !p.as_os_str().is_empty() {
            return Some(p.join("opencode"));
        }
    }
    paths::home_dir().map(|h| h.join(".local").join("share").join("opencode"))
}

fn installed() -> bool {
    let home_marker = paths::home_dir()
        .map(|h| h.join(".config").join("opencode").is_dir() || h.join(".opencode").is_dir())
        .unwrap_or(false);
    home_marker || data_dir().map(|d| d.is_dir()).unwrap_or(false)
}

fn auth_present() -> bool {
    data_dir()
        .map(|d| d.join("auth.json").is_file())
        .unwrap_or(false)
}

// --- The message blob shape (identical in SQLite `data` and legacy JSON) --------

#[derive(Deserialize, Default)]
struct OcTime {
    /// Epoch **milliseconds**. Optional; a message without it is skipped.
    #[serde(default)]
    created: Option<f64>,
}

#[derive(Deserialize, Default)]
struct OcCache {
    #[serde(default)]
    read: f64,
    #[serde(default)]
    write: f64,
}

#[derive(Deserialize, Default)]
struct OcTokens {
    #[serde(default)]
    input: f64,
    #[serde(default)]
    output: f64,
    #[serde(default)]
    reasoning: f64,
    #[serde(default)]
    cache: OcCache,
}

#[derive(Deserialize)]
struct OcMessage {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    role: String,
    #[serde(default, rename = "modelID")]
    model_id: Option<String>,
    #[serde(default)]
    time: OcTime,
    #[serde(default)]
    tokens: Option<OcTokens>,
}

/// Non-negative f64 → u64 (clamps NaN/negatives to 0).
fn as_u64(v: f64) -> u64 {
    if v.is_finite() && v > 0.0 {
        v as u64
    } else {
        0
    }
}

/// Parse one message blob into a dated [`UsageRecord`], or `None` if it isn't a
/// token-bearing assistant turn inside the window. Pushes its id into `seen` so a
/// SQLite/legacy-JSON overlap (post-migration) isn't double-counted.
fn record_from(json: &str, cutoff_ms: f64, seen: &mut HashSet<String>) -> Option<UsageRecord> {
    let msg: OcMessage = serde_json::from_str(json).ok()?;
    if msg.role != "assistant" {
        return None;
    }
    let tokens = msg.tokens?;
    let created_ms = msg.time.created?;
    if !created_ms.is_finite() || created_ms < cutoff_ms {
        return None;
    }
    // Dedup by message id when present (the DB primary key / legacy filename).
    if let Some(id) = &msg.id {
        if !seen.insert(id.clone()) {
            return None;
        }
    }

    let input = as_u64(tokens.input);
    let output = as_u64(tokens.output);
    let reasoning = as_u64(tokens.reasoning);
    let cache_read = as_u64(tokens.cache.read);
    let cache_write = as_u64(tokens.cache.write);
    if input + output + reasoning + cache_read + cache_write == 0 {
        return None; // an empty turn carries no usage
    }

    let secs = (created_ms / 1000.0) as i64;
    Some(UsageRecord {
        model: msg
            .model_id
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| "unknown".to_string()),
        date: utc_date(secs),
        tokens: TokenTotals {
            input_tokens: input,
            output_tokens: output,
            cache_creation_tokens: cache_write,
            cache_read_tokens: cache_read,
            reasoning_tokens: reasoning,
            cache_creation_1h_tokens: 0,
        },
    })
}

/// Stream every message blob from the SQLite store (macOS only) into `emit`.
/// Opened read-only with a short busy timeout so it coexists with OpenCode
/// writing the same file; any error (locked, schema drift, missing table)
/// degrades to nothing.
///
/// One blob at a time, deliberately. Collecting first into a `Vec<String>` meant
/// a heavy long-lived install materialized its ENTIRE message history in RAM —
/// multi-gigabyte on this path, which runs on every rescan — only for the caller
/// to discard everything outside the 35-day window. The peak is now one row.
#[cfg(target_os = "macos")]
fn read_db_blobs(path: &Path, emit: &mut dyn FnMut(&str)) {
    use rusqlite::{Connection, OpenFlags};
    let Ok(conn) = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
        return;
    };
    let _ = conn.busy_timeout(std::time::Duration::from_millis(250));
    let Ok(mut stmt) = conn.prepare("SELECT data FROM message") else {
        return;
    };
    let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) else {
        return;
    };
    for blob in rows.flatten() {
        emit(&blob);
    }
}

/// Non-macOS builds have no SQLite dependency; only the portable legacy-JSON path
/// runs there. (OpenCode ships on macOS/Linux; the app itself is macOS.)
#[cfg(not(target_os = "macos"))]
fn read_db_blobs(_path: &Path, _emit: &mut dyn FnMut(&str)) {}

/// Stream legacy per-message JSON files under `storage/` (older installs and the
/// pre-migration copy) into `emit`. Directory names vary by version, so we take
/// any `*.json` under `storage/` and let the assistant/tokens filter drop
/// non-message files. One file at a time, for the reason in `read_db_blobs`.
fn read_legacy_blobs(data_dir: &Path, emit: &mut dyn FnMut(&str)) {
    let storage = data_dir.join("storage");
    if !storage.is_dir() {
        return;
    }
    for file in paths::collect_files(&storage, STORAGE_DEPTH, &|n| n.ends_with(".json")) {
        if let Ok(s) = std::fs::read_to_string(&file) {
            emit(&s);
        }
    }
}

impl Provider for OpenCodeProvider {
    fn id(&self) -> ProviderId {
        ProviderId::OpenCode
    }

    fn capabilities(&self) -> Vec<(Cap, CapabilityState)> {
        let mut c = caps(
            &[
                Cap::InstalledAppDetection,
                Cap::AuthDetection,
                Cap::LocalCostScan,
                Cap::ModelBreakdown,
                Cap::CacheMetrics,
                Cap::LocalSessionHistory,
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
        // OpenCode logs carry no provider rate-limit windows or account balance.
        c.push((Cap::VersionDetection, CapabilityState::Unsupported));
        c.push((Cap::ProjectAssociation, CapabilityState::Unavailable));
        c.push((Cap::SessionLimits, CapabilityState::Unavailable));
        c.push((Cap::WeeklyLimits, CapabilityState::Unavailable));
        c.push((Cap::CreditsAndSpend, CapabilityState::Unavailable));
        c
    }

    fn status(&self) -> ProviderStatus {
        let inst = installed();
        ProviderStatus {
            provider: ProviderId::OpenCode,
            display_name: ProviderId::OpenCode.display_name().to_string(),
            installed: inst,
            authenticated: auth_present(),
            health: if inst {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            detected_version: None,
        }
    }

    fn scan(&self, now_unix: i64) -> ProviderUsage {
        let inst = installed();
        let authenticated = auth_present();
        let cutoff_ms = (now_unix - SCAN_WINDOW_DAYS * 86_400) as f64 * 1000.0;

        // Parse and dedup as each blob arrives, so only the in-window records are
        // ever held. The DB is read before the legacy files so that when both
        // stores hold one message, the DB copy is the one `seen` keeps.
        let mut seen: HashSet<String> = HashSet::new();
        let mut records: Vec<UsageRecord> = Vec::new();
        if let Some(dir) = data_dir() {
            let mut emit = |blob: &str| {
                if let Some(rec) = record_from(blob, cutoff_ms, &mut seen) {
                    records.push(rec);
                }
            };
            let db = dir.join("opencode.db");
            if db.is_file() {
                read_db_blobs(&db, &mut emit);
            }
            read_legacy_blobs(&dir, &mut emit);
        }

        let (windows, models, unpriceable) = aggregate(&records, now_unix);
        let analytics = compute_analytics(&records, now_unix);

        let mut notes = Vec::new();
        if !unpriceable.is_empty() {
            notes.push(format!(
                "{} model(s) had no pricing and are excluded from cost estimates: {}",
                unpriceable.len(),
                unpriceable.join(", ")
            ));
        }
        if inst && records.is_empty() {
            notes.push("No OpenCode session activity in the last 35 days.".into());
        }

        ProviderUsage {
            provider: ProviderId::OpenCode,
            display_name: ProviderId::OpenCode.display_name().to_string(),
            health: if inst {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            installed: inst,
            authenticated,
            detected_version: None,
            plan_hint: None,
            windows,
            models,
            limits: Vec::new(),
            capabilities: self.capabilities(),
            notes,
            analytics: Some(analytics),
            balance: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assistant_blob(created_ms: f64, model: &str, input: u64, output: u64) -> String {
        format!(
            r#"{{"id":"msg_{created_ms}","role":"assistant","modelID":"{model}",
                "providerID":"anthropic","time":{{"created":{created_ms}}},
                "cost":0.12,
                "tokens":{{"input":{input},"output":{output},"reasoning":0,
                           "cache":{{"read":5,"write":7}}}}}}"#
        )
    }

    #[test]
    fn parses_an_assistant_message_into_a_dated_record() {
        let now = crate::datetime::now_unix();
        let created = now as f64 * 1000.0; // today, in ms
        let cutoff = (now - SCAN_WINDOW_DAYS * 86_400) as f64 * 1000.0;
        let mut seen = HashSet::new();
        let rec = record_from(
            &assistant_blob(created, "claude-sonnet-4-5", 100, 20),
            cutoff,
            &mut seen,
        )
        .expect("assistant record");
        assert_eq!(rec.model, "claude-sonnet-4-5");
        assert_eq!(rec.tokens.input_tokens, 100);
        assert_eq!(rec.tokens.output_tokens, 20);
        assert_eq!(rec.tokens.cache_read_tokens, 5);
        assert_eq!(rec.tokens.cache_creation_tokens, 7);
    }

    #[test]
    fn skips_user_messages_and_empty_turns() {
        let now = crate::datetime::now_unix();
        let created = now as f64 * 1000.0;
        let cutoff = (now - SCAN_WINDOW_DAYS * 86_400) as f64 * 1000.0;
        let mut seen = HashSet::new();
        // A user message carries no tokens/model → skipped.
        let user = format!(r#"{{"id":"m1","role":"user","time":{{"created":{created}}}}}"#);
        assert!(record_from(&user, cutoff, &mut seen).is_none());
        // An assistant turn with all-zero tokens is not usage.
        let zero = format!(
            r#"{{"id":"m2","role":"assistant","modelID":"x","time":{{"created":{created}}},
                "tokens":{{"input":0,"output":0,"reasoning":0,"cache":{{"read":0,"write":0}}}}}}"#
        );
        assert!(record_from(&zero, cutoff, &mut seen).is_none());
    }

    #[test]
    fn drops_activity_older_than_the_window() {
        let now = crate::datetime::now_unix();
        let old = (now - 60 * 86_400) as f64 * 1000.0; // 60 days ago
        let cutoff = (now - SCAN_WINDOW_DAYS * 86_400) as f64 * 1000.0;
        let mut seen = HashSet::new();
        assert!(record_from(&assistant_blob(old, "gpt-5", 100, 20), cutoff, &mut seen).is_none());
    }

    #[test]
    fn dedups_the_same_message_id_across_stores() {
        let now = crate::datetime::now_unix();
        let created = now as f64 * 1000.0;
        let cutoff = (now - SCAN_WINDOW_DAYS * 86_400) as f64 * 1000.0;
        let mut seen = HashSet::new();
        let blob = assistant_blob(created, "claude-sonnet-4-5", 100, 20);
        assert!(record_from(&blob, cutoff, &mut seen).is_some()); // DB copy
        assert!(record_from(&blob, cutoff, &mut seen).is_none()); // legacy copy, same id
    }
}
