//! Agent Mission Control.
//!
//! Normalizes recently-active AI coding sessions (Claude, Codex) into a
//! `Mission` list by reading local session logs only — no network, no process
//! inspection, no control. Answers the product's first question: "what are my
//! AI agents doing right now?"
//!
//! ## How the scan stays cheap and honest
//! - Only session files touched within [`RECENT_WINDOW_SECS`] (by mtime) are
//!   considered — a mission is, by definition, *recent*.
//! - At most [`MAX_FILES`] of the most-recently-modified files are read, so a
//!   busy machine with thousands of archived sessions bounds its work.
//! - Each file is read as a **tail** (last [`TAIL_BYTES`]) for the latest state
//!   plus its **first line** for the start time — active session logs can be
//!   large, and streaming them fully every refresh would be wasteful.
//! - Read-only. We never open for write, never follow symlinks (traversal is
//!   handled by [`crate::paths::collect_files`], which skips them), and never
//!   execute anything. Unparseable files degrade to nothing; we never panic.

use crate::paths;
use serde::Deserialize;
use serde_json::Value;
use stackpulse_protocol::{Mission, MissionStatus, ProviderId};
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

/// A session must have been touched within this many seconds to be a mission.
const RECENT_WINDOW_SECS: i64 = 2 * 60 * 60; // 2 hours
/// Meaningful output within this window ⇒ [`MissionStatus::Active`].
const ACTIVE_SECS: i64 = 180;
/// Quiet-but-not-old within this window ⇒ [`MissionStatus::Idle`].
const IDLE_SECS: i64 = 1800;
/// Upper bound on session files read per discovery pass (perf guard).
const MAX_FILES: usize = 40;
/// Bytes of each file's tail to read for its latest state (~64 KB).
const TAIL_BYTES: u64 = 64 * 1024;
/// Claude project traversal depth (mirrors the cost scanner).
const CLAUDE_DEPTH: usize = 6;
/// Codex session traversal depth (mirrors the cost scanner).
const CODEX_DEPTH: usize = 7;

/// Which log format a candidate file uses.
#[derive(Clone, Copy)]
enum Kind {
    Claude,
    Codex,
}

/// A recently-modified session file queued for normalization.
struct Candidate {
    mtime_unix: i64,
    path: std::path::PathBuf,
    kind: Kind,
}

/// Discover recent/active AI coding sessions as missions, most-recently-active
/// first. `now_unix` is the reference clock (testable).
pub fn discover(now_unix: i64) -> Vec<Mission> {
    let mtime_cutoff = now_unix - RECENT_WINDOW_SECS;
    let mut candidates: Vec<Candidate> = Vec::new();

    // Claude: {root}/projects/**/*.jsonl
    for root in paths::claude_roots() {
        let projects = root.join("projects");
        if !projects.is_dir() {
            continue;
        }
        for path in paths::collect_files(&projects, CLAUDE_DEPTH, &|n| n.ends_with(".jsonl")) {
            if let Some(mtime_unix) = file_mtime_unix(&path) {
                if mtime_unix >= mtime_cutoff {
                    candidates.push(Candidate {
                        mtime_unix,
                        path,
                        kind: Kind::Claude,
                    });
                }
            }
        }
    }

    // Codex: $CODEX_HOME/{sessions,archived_sessions}/**/*.jsonl
    for root in paths::codex_roots() {
        for sub in ["sessions", "archived_sessions"] {
            let dir = root.join(sub);
            if !dir.is_dir() {
                continue;
            }
            for path in paths::collect_files(&dir, CODEX_DEPTH, &|n| n.ends_with(".jsonl")) {
                if let Some(mtime_unix) = file_mtime_unix(&path) {
                    if mtime_unix >= mtime_cutoff {
                        candidates.push(Candidate {
                            mtime_unix,
                            path,
                            kind: Kind::Codex,
                        });
                    }
                }
            }
        }
    }

    // Read only the freshest files, newest first.
    candidates.sort_by_key(|c| std::cmp::Reverse(c.mtime_unix));
    candidates.truncate(MAX_FILES);

    let mut missions: Vec<Mission> = Vec::new();
    for c in &candidates {
        let mission = match c.kind {
            Kind::Claude => claude_mission(&c.path, now_unix),
            Kind::Codex => codex_mission(&c.path, now_unix),
        };
        if let Some(m) = mission {
            missions.push(m);
        }
    }

    // Most-recently-active first.
    missions.sort_by_key(|m| std::cmp::Reverse(m.last_activity_unix));
    missions
}

// ---------------------------------------------------------------------------
// Claude normalization
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ClaudeLine {
    #[serde(default)]
    timestamp: Option<String>,
    #[serde(default, rename = "sessionId")]
    session_id: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default, rename = "gitBranch")]
    git_branch: Option<String>,
    #[serde(default)]
    message: Option<ClaudeMessage>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    usage: Option<ClaudeUsage>,
    #[serde(default)]
    content: Option<Vec<ClaudeContentBlock>>,
}

#[derive(Deserialize)]
struct ClaudeContentBlock {
    #[serde(default, rename = "type")]
    block_type: Option<String>,
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct ClaudeUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
}

fn claude_mission(path: &Path, now_unix: i64) -> Option<Mission> {
    let tail = tail_lines(path, TAIL_BYTES);
    if tail.is_empty() {
        return None;
    }
    let hour_cutoff = now_unix - 3600;

    let mut last_activity_unix: Option<i64> = None;
    let mut session_id: Option<String> = None;
    let mut project_path: Option<String> = None;
    let mut branch: Option<String> = None;
    let mut model: Option<String> = None;
    let mut last_activity: Option<String> = None;
    let mut message_count: u64 = 0;
    let mut tokens_last_hour: u64 = 0;

    for line in &tail {
        let parsed: ClaudeLine = match serde_json::from_str(line) {
            Ok(p) => p,
            Err(_) => continue, // tolerate partial / malformed lines
        };
        let ts_unix = parsed.timestamp.as_deref().and_then(parse_iso_unix);
        if let Some(t) = ts_unix {
            last_activity_unix = Some(t);
        }
        if let Some(s) = non_empty(parsed.session_id) {
            session_id = Some(s);
        }
        if let Some(c) = non_empty(parsed.cwd) {
            project_path = Some(c);
        }
        if let Some(b) = non_empty(parsed.git_branch) {
            branch = Some(b);
        }
        if let Some(msg) = parsed.message {
            if let Some(m) = non_empty(msg.model) {
                model = Some(m);
            }
            if let Some(usage) = &msg.usage {
                message_count += 1; // recent count of assistant turns in the tail
                if ts_unix.is_some_and(|t| t >= hour_cutoff) {
                    tokens_last_hour += usage.input_tokens
                        + usage.output_tokens
                        + usage.cache_read_input_tokens
                        + usage.cache_creation_input_tokens;
                }
            }
            if msg.role.as_deref() == Some("assistant") {
                if let Some(summary) = summarize_claude_content(msg.content.as_deref()) {
                    last_activity = Some(summary);
                }
            }
        }
    }

    let last_activity_unix = last_activity_unix?;
    if now_unix - last_activity_unix > RECENT_WINDOW_SECS {
        return None; // last logged activity is too old to be a live mission
    }

    let session_id = session_id.or_else(|| file_stem(path))?;
    if session_id.is_empty() {
        return None;
    }

    let project_name = project_path.as_deref().map(last_path_component);
    let started_at_unix = first_line(path)
        .and_then(|l| serde_json::from_str::<ClaudeLine>(&l).ok())
        .and_then(|l| l.timestamp)
        .as_deref()
        .and_then(parse_iso_unix);

    Some(Mission {
        provider: ProviderId::Claude,
        session_id,
        status: status_for(now_unix, last_activity_unix),
        project_path,
        project_name,
        branch,
        model,
        started_at_unix,
        last_activity_unix,
        message_count,
        last_activity,
        tokens_last_hour,
    })
}

/// A one-line summary of the latest assistant turn from its content blocks.
/// Priority: an active tool call, then reasoning, then a text reply.
fn summarize_claude_content(content: Option<&[ClaudeContentBlock]>) -> Option<String> {
    let blocks = content?;
    let mut tool: Option<&str> = None;
    let mut has_thinking = false;
    let mut has_text = false;
    for b in blocks {
        match b.block_type.as_deref() {
            Some("tool_use") => {
                if let Some(name) = b.name.as_deref() {
                    tool = Some(name);
                }
            }
            Some("thinking") | Some("redacted_thinking") => has_thinking = true,
            Some("text") => has_text = true,
            _ => {}
        }
    }
    Some(if let Some(name) = tool {
        format!("Using {name}")
    } else if has_thinking {
        "Reasoning".to_string()
    } else if has_text {
        "Responding".to_string()
    } else {
        "Working".to_string()
    })
}

// ---------------------------------------------------------------------------
// Codex normalization
// ---------------------------------------------------------------------------

fn codex_mission(path: &Path, now_unix: i64) -> Option<Mission> {
    let tail = tail_lines(path, TAIL_BYTES);
    if tail.is_empty() {
        return None;
    }
    let hour_cutoff = now_unix - 3600;

    let mut last_activity_unix: Option<i64> = None;
    let mut model: Option<String> = None;
    let mut project_path: Option<String> = None;
    let mut session_id: Option<String> = None;
    let mut last_event: Option<String> = None;
    let mut message_count: u64 = 0;
    let mut tokens_last_hour: u64 = 0;

    for line in &tail {
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = v.get("type").and_then(Value::as_str).unwrap_or("");
        let ts = v.get("timestamp").and_then(Value::as_str).unwrap_or("");
        let ts_unix = parse_iso_unix(ts);
        if let Some(t) = ts_unix {
            last_activity_unix = Some(t);
        }
        let Some(payload) = v.get("payload") else {
            continue;
        };
        match kind {
            "turn_context" => {
                if let Some(m) = payload.get("model").and_then(Value::as_str) {
                    if !m.is_empty() {
                        model = Some(m.to_string());
                    }
                }
                if let Some(c) = payload.get("cwd").and_then(Value::as_str) {
                    if !c.is_empty() {
                        project_path = Some(c.to_string());
                    }
                }
            }
            "session_meta" => {
                if session_id.is_none() {
                    if let Some(id) = payload.get("id").and_then(Value::as_str) {
                        if !id.is_empty() {
                            session_id = Some(id.to_string());
                        }
                    }
                }
                if project_path.is_none() {
                    if let Some(c) = payload.get("cwd").and_then(Value::as_str) {
                        if !c.is_empty() {
                            project_path = Some(c.to_string());
                        }
                    }
                }
            }
            "event_msg" => {
                let et = payload.get("type").and_then(Value::as_str).unwrap_or("");
                if !et.is_empty() {
                    last_event = Some(et.to_string());
                }
                if et == "token_count" {
                    message_count += 1;
                    if ts_unix.is_some_and(|t| t >= hour_cutoff) {
                        if let Some(last) =
                            payload.get("info").and_then(|i| i.get("last_token_usage"))
                        {
                            // Codex `input_tokens` already includes the cached
                            // portion, so we do not add `cached_input_tokens`
                            // again — that would double-count.
                            let input = last
                                .get("input_tokens")
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
                            tokens_last_hour += input + output + reasoning;
                        }
                    }
                }
            }
            _ => {}
        }
    }

    let last_activity_unix = last_activity_unix?;
    if now_unix - last_activity_unix > RECENT_WINDOW_SECS {
        return None;
    }

    // The head (first line) is the `session_meta` record. Use it for the start
    // time and to backfill `id` / `cwd` when a long session pushed them out of
    // the tail window (both are valid sources per the Codex log schema).
    let mut started_at_unix = None;
    if let Some(head) = first_line(path).and_then(|l| serde_json::from_str::<Value>(&l).ok()) {
        started_at_unix = head
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_iso_unix);
        if head.get("type").and_then(Value::as_str) == Some("session_meta") {
            if let Some(meta) = head.get("payload") {
                if session_id.is_none() {
                    if let Some(id) = meta.get("id").and_then(Value::as_str) {
                        if !id.is_empty() {
                            session_id = Some(id.to_string());
                        }
                    }
                }
                if project_path.is_none() {
                    if let Some(c) = meta.get("cwd").and_then(Value::as_str) {
                        if !c.is_empty() {
                            project_path = Some(c.to_string());
                        }
                    }
                }
            }
        }
    }

    let session_id = session_id.or_else(|| file_stem(path))?;
    if session_id.is_empty() {
        return None;
    }

    let project_name = project_path.as_deref().map(last_path_component);

    Some(Mission {
        provider: ProviderId::Codex,
        session_id,
        status: status_for(now_unix, last_activity_unix),
        project_path,
        project_name,
        branch: None, // Codex logs don't carry a git branch
        model,
        started_at_unix,
        last_activity_unix,
        message_count,
        last_activity: last_event.as_deref().map(summarize_codex_event),
        tokens_last_hour,
    })
}

/// Human summary for a Codex `event_msg` payload type.
fn summarize_codex_event(event_type: &str) -> String {
    match event_type {
        "token_count" => "Working".to_string(),
        "agent_message" | "agent_message_delta" => "Responding".to_string(),
        "agent_reasoning" | "agent_reasoning_delta" | "agent_reasoning_raw_content" => {
            "Reasoning".to_string()
        }
        "task_started" => "Starting task".to_string(),
        "task_complete" => "Completed turn".to_string(),
        "turn_aborted" => "Turn aborted".to_string(),
        "user_message" => "Awaiting model".to_string(),
        "context_compacted" => "Compacting context".to_string(),
        "exec_command_begin" | "exec_command_end" | "exec_command_output_delta" => {
            "Running command".to_string()
        }
        "patch_apply_begin" | "patch_apply_end" => "Editing files".to_string(),
        "mcp_tool_call_begin" | "mcp_tool_call_end" => "Using a tool".to_string(),
        other => humanize(other),
    }
}

/// Turn a snake_case event name into a capitalized phrase ("some_thing" →
/// "Some thing"). Never panics on empty input.
fn humanize(s: &str) -> String {
    let spaced = s.replace('_', " ");
    let mut chars = spaced.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => "Working".to_string(),
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Map recency (seconds since last activity) to a [`MissionStatus`]. Only the
/// three live states are produced here; `Stalled` is a future heuristic and
/// `Unknown` is reserved for forward-compatibility.
fn status_for(now_unix: i64, last_activity_unix: i64) -> MissionStatus {
    let age = now_unix - last_activity_unix;
    if age < ACTIVE_SECS {
        MissionStatus::Active
    } else if age < IDLE_SECS {
        MissionStatus::Idle
    } else {
        MissionStatus::Recent
    }
}

/// `Some(s)` only when `s` is present and non-empty, else `None`.
fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|s| !s.is_empty())
}

/// Last path component of an absolute path string, e.g. "/a/b" → "b".
fn last_path_component(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
        .unwrap_or_else(|| path.to_string())
}

/// The file name without its extension, used as a session-id fallback.
fn file_stem(path: &Path) -> Option<String> {
    path.file_stem()
        .and_then(|s| s.to_str())
        .map(str::to_string)
}

/// File modification time in Unix seconds. Uses `symlink_metadata` so a symlink
/// is never resolved (traversal already excludes them; this is belt-and-braces).
fn file_mtime_unix(path: &Path) -> Option<i64> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    let mtime = meta.modified().ok()?;
    mtime
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

/// The first physical line of a file (trimmed), or `None` if empty/unreadable.
fn first_line(path: &Path) -> Option<String> {
    let file = File::open(path).ok()?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => None,
        Ok(_) => Some(line.trim_end().to_string()),
    }
}

/// Read the last `max_bytes` of a file and return its complete lines. If the
/// read started mid-file, the first (partial) line is dropped. Lossy UTF-8
/// decoding tolerates a tail boundary that splits a multi-byte character.
fn tail_lines(path: &Path, max_bytes: u64) -> Vec<String> {
    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    let start = len.saturating_sub(max_bytes);
    if file.seek(SeekFrom::Start(start)).is_err() {
        return Vec::new();
    }
    let mut bytes = Vec::new();
    if file.read_to_end(&mut bytes).is_err() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    if start > 0 && !lines.is_empty() {
        lines.remove(0); // drop the partial line we seeked into
    }
    lines
}

/// Parse an ISO-8601 timestamp into Unix seconds. Reuses
/// [`crate::datetime`] for the date math (no `chrono`). The `Z`/UTC forms used
/// by both providers are the common case; a numeric offset is honored if
/// present, and sub-second precision is ignored.
fn parse_iso_unix(ts: &str) -> Option<i64> {
    let date = crate::datetime::parse_iso_date(ts)?;
    let days = crate::datetime::days_from_civil(date.year, date.month, date.day);
    let mut secs = days * 86_400;

    // Optional "THH:MM:SS[.fff][±HH:MM|Z]" tail (byte index 10 is the 'T').
    if let Some(time_part) = ts.get(11..) {
        let b = time_part.as_bytes();
        if b.len() >= 8 && b[2] == b':' && b[5] == b':' {
            let hh: i64 = time_part
                .get(0..2)
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let mm: i64 = time_part
                .get(3..5)
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let ss: i64 = time_part
                .get(6..8)
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            if hh <= 23 && mm <= 59 && ss <= 60 {
                secs += hh * 3600 + mm * 60 + ss;
                // A trailing numeric offset shifts local → UTC.
                let rest =
                    time_part[8..].trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
                if let Some(pos) = rest.find(['+', '-']) {
                    let off = &rest[pos..];
                    let sign = if off.starts_with('-') { -1 } else { 1 };
                    let digits: String = off.chars().filter(char::is_ascii_digit).collect();
                    if digits.len() >= 2 {
                        let oh: i64 = digits[0..2].parse().unwrap_or(0);
                        let om: i64 = if digits.len() >= 4 {
                            digits[2..4].parse().unwrap_or(0)
                        } else {
                            0
                        };
                        secs -= sign * (oh * 3600 + om * 60);
                    }
                }
            }
        }
    }
    Some(secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_iso_unix_matches_midnight_and_time() {
        let midnight = crate::datetime::days_from_civil(2026, 7, 12) * 86_400;
        assert_eq!(parse_iso_unix("2026-07-12"), Some(midnight));
        assert_eq!(
            parse_iso_unix("2026-07-12T00:00:00Z"),
            Some(midnight),
            "Z is treated as UTC"
        );
        assert_eq!(
            parse_iso_unix("2026-07-12T01:02:03.500Z"),
            Some(midnight + 3600 + 120 + 3)
        );
        // +02:00 offset means the UTC instant is two hours earlier.
        assert_eq!(parse_iso_unix("2026-07-12T02:00:00+02:00"), Some(midnight));
        assert_eq!(parse_iso_unix("not-a-date"), None);
    }

    #[test]
    fn status_thresholds() {
        assert_eq!(status_for(1000, 1000), MissionStatus::Active);
        assert_eq!(status_for(1000, 1000 - 179), MissionStatus::Active);
        assert_eq!(status_for(1000, 1000 - 200), MissionStatus::Idle);
        assert_eq!(status_for(10_000, 10_000 - 2000), MissionStatus::Recent);
    }

    #[test]
    fn summarizes_claude_content_by_priority() {
        let tool = vec![
            ClaudeContentBlock {
                block_type: Some("text".into()),
                name: None,
            },
            ClaudeContentBlock {
                block_type: Some("tool_use".into()),
                name: Some("Edit".into()),
            },
        ];
        assert_eq!(
            summarize_claude_content(Some(&tool)).as_deref(),
            Some("Using Edit")
        );
        let text = vec![ClaudeContentBlock {
            block_type: Some("text".into()),
            name: None,
        }];
        assert_eq!(
            summarize_claude_content(Some(&text)).as_deref(),
            Some("Responding")
        );
        assert_eq!(summarize_claude_content(None), None);
    }

    #[test]
    fn humanizes_unknown_codex_events() {
        assert_eq!(summarize_codex_event("token_count"), "Working");
        assert_eq!(summarize_codex_event("agent_reasoning"), "Reasoning");
        assert_eq!(summarize_codex_event("some_new_event"), "Some new event");
    }

    #[test]
    fn last_path_component_handles_trailing_slash() {
        assert_eq!(last_path_component("/a/b/c"), "c");
        assert_eq!(last_path_component("/a/b/"), "b");
    }
}
