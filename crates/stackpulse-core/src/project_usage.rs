//! Per-project spend attribution.
//!
//! The provider scan answers "how much did Claude cost me?"; this answers the
//! question a user actually acts on — "*which project* is burning my budget?".
//! Both Claude and Codex record the working directory a session ran in, so the
//! `cwd` in the session log is the join key between a token record and a
//! project. No new data source is involved: this reads the same local logs the
//! provider scan already reads, offline, filesystem-only.
//!
//! ## Why the parsing lives here rather than calling the provider adapters
//! The adapters flatten their logs into a provider-wide record list and discard
//! `cwd` on the way — the grouping key we need. Rather than widen their scan
//! signature (and the snapshot they feed), this module re-reads the same lines
//! with the same conventions: Claude's `input_tokens` is already exclusive of
//! cache, Codex's is not (`fresh = input - cached`), and each provider dedupes
//! with its own natural key.
//!
//! ## Attribution rule
//! A session file belongs to **one** project: the first non-empty `cwd` it
//! records. Some long sessions log a different `cwd` later (a subagent or a
//! tool running elsewhere), but the session — and the spend it drives — belongs
//! to the project it was started in. A file with no recorded `cwd` is skipped
//! rather than guessed at.
//!
//! Costs here are the same **local list-price estimates** the rest of the app
//! shows — never billed amounts. A model with no pricing entry contributes its
//! tokens but no cost.

use crate::datetime::{days_from_civil, utc_date};
use crate::paths;
use crate::pricing;
use crate::providers::UsageRecord;
use serde::Deserialize;
use serde_json::Value;
use stackpulse_protocol::{ProjectUsage, ProviderId, SpendWindow, TokenTotals};
use std::collections::{HashMap, HashSet};
use std::io::BufRead;
use std::path::Path;

/// Only read session files touched within this many days — bounds the work on a
/// machine with a long history and matches the 30-day window we report.
const SCAN_WINDOW_DAYS: i64 = 35;
/// Claude project traversal depth (mirrors the cost scanner).
const CLAUDE_DEPTH: usize = 6;
/// Codex session traversal depth (mirrors the cost scanner).
const CODEX_DEPTH: usize = 7;

/// A usage record already tied to the project its session ran in.
struct Attributed {
    project_path: String,
    provider: ProviderId,
    record: UsageRecord,
    ts_unix: i64,
}

/// A record staged while its file is still being read, waiting on the file's
/// project. `key` is the provider's natural dedup key, claimed only at flush.
struct Pending<K> {
    key: K,
    record: UsageRecord,
    ts_unix: i64,
}

/// Local AI spend grouped by the project each session ran in, most expensive
/// (30-day estimate) first. `now_unix` is the reference clock (testable).
///
/// Never panics: an unreadable root, file, or line degrades to less data, never
/// an error — a machine with no local sessions yields an empty list.
pub fn analyze(now_unix: i64) -> Vec<ProjectUsage> {
    let mut attributed = Vec::new();
    scan_claude(now_unix, &mut attributed);
    scan_codex(now_unix, &mut attributed);
    group(&attributed, now_unix)
}

// ---------------------------------------------------------------------------
// Grouping
// ---------------------------------------------------------------------------

/// Accumulator for one project while grouping.
#[derive(Default)]
struct Bucket {
    today: SpendWindow,
    last_30: SpendWindow,
    providers: Vec<ProviderId>,
    last_activity_unix: Option<i64>,
}

/// Fold attributed records into one [`ProjectUsage`] per project path.
///
/// The window split mirrors [`crate::providers::aggregate`] exactly — same UTC
/// "today", same inclusive 30-day cutoff — so a project's numbers reconcile
/// with the provider totals shown elsewhere in the app.
fn group(attributed: &[Attributed], now_unix: i64) -> Vec<ProjectUsage> {
    let today = utc_date(now_unix);
    let today_days = days_from_civil(today.year, today.month, today.day);
    let cutoff_30 = today_days - 29; // inclusive 30-day window ending today

    let mut buckets: HashMap<&str, Bucket> = HashMap::new();
    for a in attributed {
        let rec_days = days_from_civil(a.record.date.year, a.record.date.month, a.record.date.day);
        let in_30 = rec_days >= cutoff_30 && rec_days <= today_days;
        if !in_30 {
            continue; // outside every window we report
        }
        let cost = pricing::estimate_cost(&a.record.model, &a.record.tokens, a.record.date);
        let bucket = buckets.entry(a.project_path.as_str()).or_default();

        apply(&mut bucket.last_30, &a.record.tokens, cost);
        if a.record.date == today {
            apply(&mut bucket.today, &a.record.tokens, cost);
        }
        if !bucket.providers.contains(&a.provider) {
            bucket.providers.push(a.provider);
        }
        bucket.last_activity_unix = Some(match bucket.last_activity_unix {
            Some(prev) => prev.max(a.ts_unix),
            None => a.ts_unix,
        });
    }

    let mut out: Vec<ProjectUsage> = buckets
        .into_iter()
        .map(|(path, b)| ProjectUsage {
            project_path: path.to_string(),
            project_name: last_path_component(path),
            providers: b.providers,
            windows: vec![
                SpendWindow {
                    label: "today".into(),
                    ..b.today
                },
                SpendWindow {
                    label: "last_30_days".into(),
                    ..b.last_30
                },
            ],
            last_activity_unix: b.last_activity_unix,
        })
        .collect();

    // Most expensive first — the whole point is "where is the money going?".
    // Unpriceable projects (no cost) sort last but keep a stable, named order.
    out.sort_by(|a, b| {
        thirty_day_cost(b)
            .partial_cmp(&thirty_day_cost(a))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.project_name.cmp(&b.project_name))
    });
    out
}

/// A project's 30-day estimate, with "no priceable model" treated as zero for
/// ordering only (the reported window still carries `None`).
fn thirty_day_cost(p: &ProjectUsage) -> f64 {
    p.windows
        .iter()
        .find(|w| w.label == "last_30_days")
        .and_then(|w| w.estimated_cost_usd)
        .unwrap_or(0.0)
}

fn apply(window: &mut SpendWindow, tokens: &TokenTotals, cost: Option<f64>) {
    window.tokens.add(tokens);
    window.records += 1;
    if let Some(c) = cost {
        window.estimated_cost_usd = Some(window.estimated_cost_usd.unwrap_or(0.0) + c);
    }
}

/// Last path component of an absolute path, e.g. "/a/b" → "b". Falls back to the
/// whole string for a path with no final component.
fn last_path_component(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
        .unwrap_or_else(|| path.to_string())
}

// ---------------------------------------------------------------------------
// Claude
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ClaudeLine {
    #[serde(default, rename = "requestId")]
    request_id: Option<String>,
    #[serde(default)]
    timestamp: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    message: Option<ClaudeMessage>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    usage: Option<ClaudeUsage>,
}

/// The per-TTL split of a turn's cache writes (1-hour writes bill at 2× input
/// vs 5-minute's 1.25×). Mirrors `providers::claude`'s reader: this module
/// deliberately re-reads the same lines, so it must apply the same conventions
/// or a project's cost would disagree with the provider total it rolls into.
#[derive(Deserialize)]
struct ClaudeCacheCreation {
    #[serde(default)]
    ephemeral_1h_input_tokens: u64,
}

#[derive(Deserialize)]
struct ClaudeUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation: Option<ClaudeCacheCreation>,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
}

fn scan_claude(now_unix: i64, out: &mut Vec<Attributed>) {
    let mtime_cutoff = now_unix - SCAN_WINDOW_DAYS * 86_400;
    let mut seen: HashSet<(String, String)> = HashSet::new();
    for root in paths::claude_roots() {
        let projects = root.join("projects");
        if !projects.is_dir() {
            continue;
        }
        let mut files = paths::collect_files(&projects, CLAUDE_DEPTH, &|n| n.ends_with(".jsonl"));
        // Directory order is filesystem-defined; sort so that when a duplicated
        // turn appears in two files, the same one always wins the attribution.
        files.sort();
        for file in files {
            if !recently_modified(&file, mtime_cutoff) {
                continue;
            }
            scan_claude_file(&file, out, &mut seen);
        }
    }
}

/// Read one Claude session file, attributing every priceable turn in it to the
/// file's project. Records are staged until the whole file is read: the `cwd`
/// usually appears on the first line, but staging means a file that only names
/// its project later still attributes correctly, and — because dedup keys are
/// claimed at flush time — an unattributable file never suppresses a duplicate
/// turn that a *later*, attributable file could still account for.
fn scan_claude_file(file: &Path, out: &mut Vec<Attributed>, seen: &mut HashSet<(String, String)>) {
    let f = match std::fs::File::open(file) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = std::io::BufReader::new(f);
    let mut cwd: Option<String> = None;
    let mut pending: Vec<Pending<Option<(String, String)>>> = Vec::new();

    for line in reader.lines().map_while(Result::ok) {
        if line.is_empty() {
            continue;
        }
        let parsed: ClaudeLine = match serde_json::from_str(&line) {
            Ok(p) => p,
            Err(_) => continue, // tolerate malformed / partial lines
        };
        if cwd.is_none() {
            cwd = parsed.cwd.filter(|c| !c.is_empty());
        }
        let Some(msg) = parsed.message else { continue };
        let Some(usage) = msg.usage else { continue };
        // Only assistant turns carry usage; require a model to price it.
        let model = msg.model.unwrap_or_default();
        if model.is_empty() {
            continue;
        }
        if usage.input_tokens
            + usage.output_tokens
            + usage.cache_creation_input_tokens
            + usage.cache_read_input_tokens
            == 0
        {
            continue;
        }
        let Some(ts_unix) = parsed
            .timestamp
            .as_deref()
            .and_then(crate::datetime::parse_iso_unix)
        else {
            continue; // undated turns can't be bucketed
        };
        // Dedup by (message.id, requestId) — replays across resumed sessions
        // repeat the same turn. Always include a turn with no id.
        pending.push(Pending {
            key: msg.id.map(|id| (id, parsed.request_id.unwrap_or_default())),
            record: UsageRecord {
                model,
                // Derive the date from the resolved instant rather than parsing
                // the string twice — keeps the day bucket and `last_activity`
                // from ever disagreeing on a timestamp carrying an offset.
                date: utc_date(ts_unix),
                tokens: TokenTotals {
                    input_tokens: usage.input_tokens,
                    output_tokens: usage.output_tokens,
                    cache_creation_tokens: usage.cache_creation_input_tokens,
                    cache_read_tokens: usage.cache_read_input_tokens,
                    reasoning_tokens: 0,
                    // Subset, clamped — see providers::claude.
                    cache_creation_1h_tokens: usage
                        .cache_creation
                        .map(|c| c.ephemeral_1h_input_tokens)
                        .unwrap_or(0)
                        .min(usage.cache_creation_input_tokens),
                },
            },
            ts_unix,
        });
    }

    // A session that never recorded a cwd can't be attributed to a project;
    // dropping it is honest, inventing a project for it would not be.
    let Some(project_path) = cwd else { return };
    for p in pending {
        if let Some(k) = p.key {
            if !seen.insert(k) {
                continue;
            }
        }
        out.push(Attributed {
            project_path: project_path.clone(),
            provider: ProviderId::Claude,
            record: p.record,
            ts_unix: p.ts_unix,
        });
    }
}

// ---------------------------------------------------------------------------
// Codex
// ---------------------------------------------------------------------------

fn scan_codex(now_unix: i64, out: &mut Vec<Attributed>) {
    let mtime_cutoff = now_unix - SCAN_WINDOW_DAYS * 86_400;
    // Keyed as in the Codex adapter, and shared across `sessions/` and
    // `archived_sessions/` because a session archived mid-window appears in both.
    let mut seen: HashSet<(String, u64, u64)> = HashSet::new();
    for root in paths::codex_roots() {
        for sub in ["sessions", "archived_sessions"] {
            let dir = root.join(sub);
            if !dir.is_dir() {
                continue;
            }
            let mut files = paths::collect_files(&dir, CODEX_DEPTH, &|n| n.ends_with(".jsonl"));
            files.sort();
            for file in files {
                if !recently_modified(&file, mtime_cutoff) {
                    continue;
                }
                scan_codex_file(&file, out, &mut seen);
            }
        }
    }
}

/// Read one Codex session file. Shape is `{timestamp, type, payload}` lines:
/// `session_meta`/`turn_context` carry the `cwd` and the active `model`, and
/// `event_msg` of type `token_count` carries the per-turn delta. Staged and
/// flushed for the same reasons as the Claude scanner.
fn scan_codex_file(file: &Path, out: &mut Vec<Attributed>, seen: &mut HashSet<(String, u64, u64)>) {
    let f = match std::fs::File::open(file) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = std::io::BufReader::new(f);
    let mut cwd: Option<String> = None;
    // The active model comes from the most recent `turn_context` in this file.
    let mut current_model = String::new();
    let mut pending: Vec<Pending<(String, u64, u64)>> = Vec::new();

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
        let Some(payload) = v.get("payload") else {
            continue;
        };
        // Both record kinds name the working directory; take the first non-empty.
        if cwd.is_none() && matches!(kind, "session_meta" | "turn_context") {
            cwd = payload
                .get("cwd")
                .and_then(Value::as_str)
                .filter(|c| !c.is_empty())
                .map(str::to_string);
        }
        match kind {
            "turn_context" => {
                if let Some(m) = payload.get("model").and_then(Value::as_str) {
                    current_model = m.to_string();
                }
            }
            "event_msg" => {
                if payload.get("type").and_then(Value::as_str) != Some("token_count") {
                    continue;
                }
                let Some(last) = payload.get("info").and_then(|i| i.get("last_token_usage")) else {
                    continue;
                };
                let field = |name: &str| last.get(name).and_then(Value::as_u64).unwrap_or(0);
                let input = field("input_tokens");
                let cached = field("cached_input_tokens");
                let output = field("output_tokens");
                let reasoning = field("reasoning_output_tokens");
                if input + output + reasoning == 0 {
                    continue;
                }
                let Some(ts_unix) = crate::datetime::parse_iso_unix(ts) else {
                    continue;
                };
                pending.push(Pending {
                    key: (ts.get(0..19).unwrap_or(ts).to_string(), input, output),
                    record: UsageRecord {
                        model: if current_model.is_empty() {
                            "unknown".to_string()
                        } else {
                            current_model.clone()
                        },
                        date: utc_date(ts_unix),
                        tokens: TokenTotals {
                            // Codex's `input_tokens` includes the cached portion;
                            // normalize to the exclusive-input convention.
                            input_tokens: input.saturating_sub(cached),
                            output_tokens: output,
                            cache_creation_tokens: 0,
                            cache_read_tokens: cached,
                            reasoning_tokens: reasoning,
                            // Codex has no cache-write TTL concept: 0 prices
                            // identically to before this field existed.
                            cache_creation_1h_tokens: 0,
                        },
                    },
                    ts_unix,
                });
            }
            _ => {}
        }
    }

    let Some(project_path) = cwd else { return };
    for p in pending {
        if !seen.insert(p.key) {
            continue;
        }
        out.push(Attributed {
            project_path: project_path.clone(),
            provider: ProviderId::Codex,
            record: p.record,
            ts_unix: p.ts_unix,
        });
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn recently_modified(path: &Path, cutoff_unix: i64) -> bool {
    match std::fs::metadata(path).and_then(|m| m.modified()) {
        Ok(mtime) => mtime
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64 >= cutoff_unix)
            .unwrap_or(true),
        Err(_) => true, // if we can't tell, don't silently skip it
    }
}

#[cfg(test)]
mod tests {
    /// A multi-byte char can straddle byte 8 of the time field (only bytes 2 and
    /// 5 are proven ASCII by the ':' checks). Slicing there panicked, and the FFI
    /// turns a panic into an error for the ENTIRE snapshot — one malformed
    /// timestamp blanked every provider. Degrade, never panic.
    #[test]
    fn parse_iso_unix_survives_multibyte_in_the_time_field() {
        // Must not panic; the date still resolves.
        let midnight = crate::datetime::parse_iso_unix("2026-01-01T00:00:00Z").unwrap();
        let got = crate::datetime::parse_iso_unix("2026-01-01T12:34:\u{20ac}X").unwrap();
        assert_eq!(got, midnight + 12 * 3600 + 34 * 60);
        assert!(crate::datetime::parse_iso_unix("2026-01-01T\u{20ac}\u{20ac}:00:00Z").is_some());
    }

    use super::*;
    use crate::datetime::civil_from_days;

    /// A unique scratch dir per test (tests share a process and run in parallel).
    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sp-projusage-{}-{tag}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// An ISO timestamp `days_ago` days before `now`, at midday UTC.
    fn iso_days_ago(now_unix: i64, days_ago: i64) -> String {
        let today = utc_date(now_unix);
        let d = civil_from_days(days_from_civil(today.year, today.month, today.day) - days_ago);
        format!("{}T12:00:00.000Z", d.iso())
    }

    fn claude_line(ts: &str, cwd: &str, id: &str, input: u64, output: u64) -> String {
        format!(
            r#"{{"requestId":"req_{id}","timestamp":"{ts}","cwd":"{cwd}","message":{{"id":"msg_{id}","model":"claude-sonnet-4","usage":{{"input_tokens":{input},"output_tokens":{output},"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}"#
        )
    }

    #[test]
    fn attributes_records_to_the_files_cwd() {
        let now = crate::datetime::now_unix();
        let dir = temp_dir("attr");
        let ts = iso_days_ago(now, 0);
        let file = dir.join("a.jsonl");
        std::fs::write(
            &file,
            format!("{}\n", claude_line(&ts, "/work/alpha", "1", 100, 10)),
        )
        .unwrap();

        let mut out = Vec::new();
        scan_claude_file(&file, &mut out, &mut HashSet::new());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].project_path, "/work/alpha");
        assert_eq!(out[0].provider, ProviderId::Claude);
        assert_eq!(out[0].record.tokens.input_tokens, 100);

        // The whole file follows the FIRST cwd, even if a later line moves.
        let file2 = dir.join("b.jsonl");
        std::fs::write(
            &file2,
            format!(
                "{}\n{}\n",
                claude_line(&ts, "/work/alpha", "2", 1, 1),
                claude_line(&ts, "/work/beta", "3", 1, 1)
            ),
        )
        .unwrap();
        let mut out2 = Vec::new();
        scan_claude_file(&file2, &mut out2, &mut HashSet::new());
        assert_eq!(out2.len(), 2);
        assert!(out2.iter().all(|a| a.project_path == "/work/alpha"));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_session_without_a_cwd_is_dropped_not_guessed() {
        let now = crate::datetime::now_unix();
        let dir = temp_dir("nocwd");
        let ts = iso_days_ago(now, 0);
        let line = format!(
            r#"{{"requestId":"r","timestamp":"{ts}","message":{{"id":"m","model":"claude-sonnet-4","usage":{{"input_tokens":50,"output_tokens":5}}}}}}"#
        );
        let file = dir.join("nocwd.jsonl");
        std::fs::write(&file, format!("{line}\n")).unwrap();

        let mut seen = HashSet::new();
        let mut out = Vec::new();
        scan_claude_file(&file, &mut out, &mut seen);
        assert!(out.is_empty(), "unattributable session must be dropped");
        // Its dedup key must NOT be claimed — an attributable file may still
        // legitimately account for the same turn.
        assert!(seen.is_empty());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn dedups_replayed_turns_within_and_across_files() {
        let now = crate::datetime::now_unix();
        let dir = temp_dir("dedup");
        let ts = iso_days_ago(now, 0);
        let line = claude_line(&ts, "/work/alpha", "1", 100, 10);

        let a = dir.join("a.jsonl");
        std::fs::write(&a, format!("{line}\n{line}\n")).unwrap(); // same turn twice
        let b = dir.join("b.jsonl");
        std::fs::write(&b, format!("{line}\n")).unwrap(); // resumed session replay

        let mut seen = HashSet::new();
        let mut out = Vec::new();
        scan_claude_file(&a, &mut out, &mut seen);
        assert_eq!(out.len(), 1, "duplicate within a file collapses");
        scan_claude_file(&b, &mut out, &mut seen);
        assert_eq!(out.len(), 1, "replay in another file collapses");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn codex_attributes_and_normalizes_cached_input() {
        let now = crate::datetime::now_unix();
        let dir = temp_dir("codex");
        let ts = iso_days_ago(now, 0);
        let meta = format!(
            r#"{{"timestamp":"{ts}","type":"session_meta","payload":{{"id":"s1","cwd":"/work/gamma","cli_version":"1.2.3"}}}}"#
        );
        let ctx = format!(
            r#"{{"timestamp":"{ts}","type":"turn_context","payload":{{"model":"gpt-5.5","cwd":"/work/gamma"}}}}"#
        );
        let tok = format!(
            r#"{{"timestamp":"{ts}","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":50}}}}}}}}"#
        );
        let file = dir.join("rollout.jsonl");
        std::fs::write(&file, format!("{meta}\n{ctx}\n{tok}\n")).unwrap();

        let mut seen = HashSet::new();
        let mut out = Vec::new();
        scan_codex_file(&file, &mut out, &mut seen);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].project_path, "/work/gamma");
        assert_eq!(out[0].provider, ProviderId::Codex);
        assert_eq!(out[0].record.model, "gpt-5.5");
        assert_eq!(out[0].record.tokens.input_tokens, 600); // 1000 - 400 cached
        assert_eq!(out[0].record.tokens.cache_read_tokens, 400);
        assert_eq!(out[0].record.tokens.reasoning_tokens, 50);

        // The same session archived elsewhere must not double-count.
        scan_codex_file(&file, &mut out, &mut seen);
        assert_eq!(out.len(), 1);

        std::fs::remove_dir_all(&dir).ok();
    }

    fn attributed(now: i64, path: &str, days_ago: i64, input: u64) -> Attributed {
        let ts_unix = now - days_ago * 86_400;
        Attributed {
            project_path: path.to_string(),
            provider: ProviderId::Claude,
            record: UsageRecord {
                model: "claude-sonnet-4".into(),
                date: utc_date(ts_unix),
                tokens: TokenTotals {
                    input_tokens: input,
                    output_tokens: 10,
                    ..Default::default()
                },
            },
            ts_unix,
        }
    }

    #[test]
    fn splits_today_and_thirty_day_windows() {
        // Midday UTC keeps ±1 day arithmetic inside the intended calendar days.
        let now = days_from_civil(2026, 7, 16) * 86_400 + 12 * 3600;
        let records = vec![
            attributed(now, "/work/alpha", 0, 100),  // today
            attributed(now, "/work/alpha", 5, 200),  // within 30d only
            attributed(now, "/work/alpha", 60, 999), // outside every window
        ];
        let projects = group(&records, now);
        assert_eq!(projects.len(), 1);

        let today = &projects[0].windows[0];
        let d30 = &projects[0].windows[1];
        assert_eq!(today.label, "today");
        assert_eq!(d30.label, "last_30_days");
        assert_eq!(today.records, 1);
        assert_eq!(today.tokens.input_tokens, 100);
        assert_eq!(
            d30.records, 2,
            "30d includes today, excludes the 60-day-old"
        );
        assert_eq!(d30.tokens.input_tokens, 300);
        assert_eq!(projects[0].project_name, "alpha");
        assert_eq!(projects[0].last_activity_unix, Some(now));
    }

    #[test]
    fn sorts_by_thirty_day_cost_then_name() {
        let now = days_from_civil(2026, 7, 16) * 86_400 + 12 * 3600;
        let records = vec![
            attributed(now, "/work/cheap", 0, 10),
            attributed(now, "/work/spendy", 0, 5_000_000),
            // Two projects with identical (zero-token-cost) spend → name order.
            attributed(now, "/work/zeta", 0, 10),
        ];
        let projects = group(&records, now);
        assert_eq!(projects[0].project_name, "spendy", "most expensive leads");
        // "cheap" and "zeta" have equal spend, so they tie-break alphabetically.
        assert_eq!(projects[1].project_name, "cheap");
        assert_eq!(projects[2].project_name, "zeta");
    }

    #[test]
    fn records_which_providers_contributed() {
        let now = days_from_civil(2026, 7, 16) * 86_400 + 12 * 3600;
        let mut codex = attributed(now, "/work/alpha", 0, 100);
        codex.provider = ProviderId::Codex;
        codex.record.model = "gpt-5.5".into();
        let projects = group(&[attributed(now, "/work/alpha", 0, 100), codex], now);
        assert_eq!(projects.len(), 1);
        assert_eq!(
            projects[0].providers,
            vec![ProviderId::Claude, ProviderId::Codex]
        );
    }

    #[test]
    fn no_data_yields_an_empty_list_and_never_panics() {
        let now = crate::datetime::now_unix();
        assert!(group(&[], now).is_empty());

        let dir = temp_dir("nodata");
        // A missing file, an empty file, and garbage all degrade to nothing.
        let missing = dir.join("does-not-exist.jsonl");
        let empty = dir.join("empty.jsonl");
        std::fs::write(&empty, "").unwrap();
        let garbage = dir.join("garbage.jsonl");
        std::fs::write(&garbage, "not json\n{\"partial\":\n\0\0\n").unwrap();

        let mut out = Vec::new();
        for f in [&missing, &empty, &garbage] {
            scan_claude_file(f, &mut out, &mut HashSet::new());
            scan_codex_file(f, &mut out, &mut HashSet::new());
        }
        assert!(out.is_empty());
        assert!(group(&out, now).is_empty());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn parse_iso_unix_handles_utc_offsets_and_junk() {
        let midnight = days_from_civil(2026, 7, 12) * 86_400;
        assert_eq!(
            crate::datetime::parse_iso_unix("2026-07-12"),
            Some(midnight)
        );
        assert_eq!(
            crate::datetime::parse_iso_unix("2026-07-12T00:00:00Z"),
            Some(midnight)
        );
        assert_eq!(
            crate::datetime::parse_iso_unix("2026-07-12T01:02:03.500Z"),
            Some(midnight + 3723)
        );
        // +02:00 local means the UTC instant is two hours earlier.
        assert_eq!(
            crate::datetime::parse_iso_unix("2026-07-12T02:00:00+02:00"),
            Some(midnight)
        );
        assert_eq!(crate::datetime::parse_iso_unix("not-a-date"), None);
    }
}
