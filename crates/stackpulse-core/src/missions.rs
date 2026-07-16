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

    // Antigravity: recent conversation trajectories under ~/.gemini/antigravity.
    // These come from the activity scanner (not the tail-read candidate path)
    // because Antigravity stores sessions as SQLite, not JSONL.
    missions.extend(antigravity_missions(now_unix, mtime_cutoff));

    // Most-recently-active first.
    missions.sort_by_key(|m| std::cmp::Reverse(m.last_activity_unix));
    missions
}

// ---------------------------------------------------------------------------
// Antigravity normalization (activity-only)
// ---------------------------------------------------------------------------

/// Recent Antigravity conversations as missions. Antigravity stores each session
/// as a SQLite trajectory we don't parse per-turn (no SQLite dependency in the
/// core), so these carry a status derived from recency, the model, and the last-
/// activity time — enough to show an in-progress Antigravity session alongside
/// Claude/Codex — but no message count or project association.
fn antigravity_missions(now_unix: i64, mtime_cutoff: i64) -> Vec<Mission> {
    let mut out = Vec::new();
    for c in crate::providers::antigravity::scan_conversations() {
        if c.mtime_unix < mtime_cutoff {
            continue;
        }
        let age = now_unix - c.mtime_unix;
        let status = if age <= ACTIVE_SECS {
            MissionStatus::Active
        } else if age <= IDLE_SECS {
            MissionStatus::Idle
        } else {
            MissionStatus::Recent
        };
        out.push(Mission {
            provider: ProviderId::Antigravity,
            session_id: c.id,
            status,
            project_path: None,
            project_name: None,
            branch: None,
            model: c.model,
            started_at_unix: None,
            last_activity_unix: c.mtime_unix,
            message_count: c.steps.unwrap_or(0),
            last_activity: Some("Antigravity agent session".to_string()),
            tokens_last_hour: 0,
            // No project association for Antigravity ⇒ no git diff; and no cheap
            // message text without deeper SQLite parsing ⇒ no preview.
            changed_files: git_changed_files(None),
            last_message_preview: None,
            scope_flags: Vec::new(),
        });
    }
    out
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
    content: Option<ClaudeContent>,
}

/// Claude message content is either a bare string (typical for a user turn) or
/// an array of typed blocks (assistant turns, tool results). Accept both so a
/// user line's text is preservable for the preview.
#[derive(Deserialize)]
#[serde(untagged)]
enum ClaudeContent {
    Text(String),
    Blocks(Vec<ClaudeContentBlock>),
}

#[derive(Deserialize)]
struct ClaudeContentBlock {
    #[serde(default, rename = "type")]
    block_type: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    text: Option<String>,
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
    let mut last_message_text: Option<String> = None;
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
        if let Some(b) = real_branch(parsed.git_branch) {
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
            // Raw text of the latest message/turn, for the preview (distinct
            // from the `last_activity` *summary*). Covers user and assistant.
            if let Some(text) = claude_message_text(msg.content.as_ref()) {
                last_message_text = Some(text);
            }
            if msg.role.as_deref() == Some("assistant") {
                if let Some(ClaudeContent::Blocks(blocks)) = msg.content.as_ref() {
                    if let Some(summary) = summarize_claude_content(Some(blocks)) {
                        last_activity = Some(summary);
                    }
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
    let changed_files = git_changed_files(project_path.as_deref());
    let scope_flags = crate::scope_guard::flags_for(&changed_files);
    // The log's own value is usually the useless "HEAD"; ask git instead. Live
    // like `changed_files`, so both describe the same working tree right now.
    let branch = branch.or_else(|| git_current_branch(project_path.as_deref()));
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
        changed_files,
        last_message_preview: last_message_text
            .as_deref()
            .map(preview_snippet)
            .filter(|s| !s.is_empty()),
        scope_flags,
    })
}

/// The raw text of a Claude message, for the preview: a bare string user turn,
/// or the first `text` block of a block array (assistant reply / text user
/// turn). Tool calls, tool results, and thinking blocks yield nothing.
fn claude_message_text(content: Option<&ClaudeContent>) -> Option<String> {
    match content? {
        ClaudeContent::Text(s) => {
            let t = s.trim();
            (!t.is_empty()).then(|| t.to_string())
        }
        ClaudeContent::Blocks(blocks) => blocks.iter().find_map(|b| {
            if b.block_type.as_deref() != Some("text") {
                return None;
            }
            let t = b.text.as_deref()?.trim();
            (!t.is_empty()).then(|| t.to_string())
        }),
    }
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
    let mut last_message_text: Option<String> = None;
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
                // Raw text of the latest human/model turn, for the preview.
                if et == "agent_message" || et == "user_message" {
                    if let Some(m) = payload.get("message").and_then(Value::as_str) {
                        if !m.trim().is_empty() {
                            last_message_text = Some(m.to_string());
                        }
                    }
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
    let changed_files = git_changed_files(project_path.as_deref());
    let scope_flags = crate::scope_guard::flags_for(&changed_files);
    // Codex logs don't carry a branch, so read the project's current one — same
    // live source as `changed_files` above. Computed before the struct literal
    // takes ownership of `project_path`.
    let branch = git_current_branch(project_path.as_deref());

    Some(Mission {
        provider: ProviderId::Codex,
        session_id,
        status: status_for(now_unix, last_activity_unix),
        project_path,
        project_name,
        branch,
        model,
        started_at_unix,
        last_activity_unix,
        message_count,
        last_activity: last_event.as_deref().map(summarize_codex_event),
        tokens_last_hour,
        changed_files,
        last_message_preview: last_message_text
            .as_deref()
            .map(preview_snippet)
            .filter(|s| !s.is_empty()),
        scope_flags,
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

/// A *real* branch name, or `None`.
///
/// Claude's logs record `gitBranch` as the literal string `"HEAD"` in practice —
/// that's what `git rev-parse --abbrev-ref HEAD` prints for a detached HEAD, and
/// it is not a branch anyone is on. Rendering it verbatim put a meaningless
/// "HEAD" chip on every mission card, so treat it (and git's other placeholder)
/// as "unknown" rather than passing the noise through.
fn real_branch(value: Option<String>) -> Option<String> {
    non_empty(value).filter(|b| b != "HEAD" && b != "(no branch)")
}

/// The project's current branch, straight from git.
///
/// Used when the session log doesn't name a usable one. This reports *now*, not
/// what the session was on historically — which is exactly consistent with
/// [`git_changed_files`], the other field on a mission read live from the same
/// working tree. Returns `None` for a detached HEAD, a non-repo, or any failure.
fn git_current_branch(project_path: Option<&str>) -> Option<String> {
    let path = match project_path {
        Some(p) if !p.is_empty() => p,
        _ => return None,
    };
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "--abbrev-ref", "HEAD"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    real_branch(Some(
        String::from_utf8_lossy(&output.stdout).trim().to_string(),
    ))
}

/// Files changed in a mission's project working tree, from `git status
/// --porcelain`, relative paths, capped at [`GIT_CHANGED_FILES_CAP`]. Returns
/// empty for a `None`/empty path, a non-git dir, a missing `git`, or any error —
/// never panics, never touches the network.
fn git_changed_files(project_path: Option<&str>) -> Vec<String> {
    let path = match project_path {
        Some(p) if !p.is_empty() => p,
        _ => return Vec::new(),
    };
    let output = match std::process::Command::new("git")
        .arg("-C")
        .arg(path)
        .arg("status")
        .arg("--porcelain")
        .output()
    {
        Ok(o) => o,
        Err(_) => return Vec::new(),
    };
    if !output.status.success() {
        return Vec::new();
    }
    parse_porcelain(&String::from_utf8_lossy(&output.stdout))
}

/// Upper bound on files reported per mission (keeps the payload small).
const GIT_CHANGED_FILES_CAP: usize = 20;

/// Parse `git status --porcelain` (v1) stdout into relative paths, capped at
/// [`GIT_CHANGED_FILES_CAP`]. Each line is `XY <path>`: the two-char status code,
/// a space, then the path from byte index 3 (both status chars and the space are
/// ASCII, so index 3 is always a char boundary). Rename/copy entries read
/// `old -> new`; we keep the destination.
fn parse_porcelain(stdout: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        if line.len() < 4 {
            continue; // too short to hold "XY <path>"
        }
        let cleaned = crate::gitpath::decode_porcelain_field(&line[3..]);
        if !cleaned.is_empty() {
            out.push(cleaned);
            if out.len() >= GIT_CHANGED_FILES_CAP {
                break;
            }
        }
    }
    out
}

/// A short, single-line, sanitized preview of a message: whitespace/newlines
/// collapse to single spaces, trimmed, truncated to [`PREVIEW_MAX_CHARS`] chars
/// with a trailing `…` when cut. Empty input ⇒ empty string.
fn preview_snippet(raw: &str) -> String {
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() > PREVIEW_MAX_CHARS {
        let head: String = collapsed.chars().take(PREVIEW_MAX_CHARS).collect();
        format!("{head}…")
    } else {
        collapsed
    }
}

/// Max characters in a [`preview_snippet`] before it is truncated with `…`.
const PREVIEW_MAX_CHARS: usize = 140;

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
                //
                // `.get`, not `[8..]`: the ':' checks above only prove bytes 2
                // and 5 are ASCII, so a multi-byte char can straddle byte 8 and
                // slicing there panics. The FFI catches it, which turned one odd
                // character in one log line into an error for the WHOLE snapshot
                // — every provider blank. This file promises never to panic.
                let rest = time_part
                    .get(8..)
                    .unwrap_or("")
                    .trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
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
    /// A multi-byte char can straddle byte 8 of the time field (only bytes 2 and
    /// 5 are proven ASCII by the ':' checks). Slicing there panicked, and the FFI
    /// turns a panic into an error for the ENTIRE snapshot — one malformed
    /// timestamp blanked every provider. Degrade, never panic.
    #[test]
    fn parse_iso_unix_survives_multibyte_in_the_time_field() {
        // Must not panic; the date still resolves.
        let midnight = parse_iso_unix("2026-01-01T00:00:00Z").unwrap();
        let got = parse_iso_unix("2026-01-01T12:34:\u{20ac}X").unwrap();
        assert_eq!(got, midnight + 12 * 3600 + 34 * 60);
        assert!(parse_iso_unix("2026-01-01T\u{20ac}\u{20ac}:00:00Z").is_some());
    }

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
                text: None,
            },
            ClaudeContentBlock {
                block_type: Some("tool_use".into()),
                name: Some("Edit".into()),
                text: None,
            },
        ];
        assert_eq!(
            summarize_claude_content(Some(&tool)).as_deref(),
            Some("Using Edit")
        );
        let text = vec![ClaudeContentBlock {
            block_type: Some("text".into()),
            name: None,
            text: None,
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

    #[test]
    fn preview_snippet_collapses_and_trims() {
        assert_eq!(
            preview_snippet("  hello\n\tworld   again  "),
            "hello world again"
        );
        assert_eq!(preview_snippet("line1\r\nline2"), "line1 line2");
        assert_eq!(preview_snippet(""), "");
        assert_eq!(preview_snippet("   \n\t  "), "");
    }

    #[test]
    fn preview_snippet_truncates_at_140_with_ellipsis() {
        let long = "a ".repeat(200); // 200 single-char words → collapses to 199 chars + trailing space
        let snip = preview_snippet(&long);
        // 140 kept chars plus the single-char ellipsis.
        assert_eq!(snip.chars().count(), 141);
        assert!(snip.ends_with('…'));
        assert!(snip.starts_with("a a"));

        // Exactly 140 chars is not truncated.
        let exact = "x".repeat(140);
        let snip = preview_snippet(&exact);
        assert_eq!(snip, exact);
        assert!(!snip.ends_with('…'));

        // 141 chars is truncated to 140 + ellipsis.
        let over = "y".repeat(141);
        let snip = preview_snippet(&over);
        assert_eq!(snip.chars().count(), 141);
        assert_eq!(snip, format!("{}…", "y".repeat(140)));
    }

    #[test]
    fn parse_porcelain_extracts_paths() {
        let stdout = concat!(
            " M src/a.ts\n",
            "?? new.ts\n",
            "R  old.ts -> new.ts\n",
            "A  added.rs\n",
            " D removed.rs\n",
        );
        assert_eq!(
            parse_porcelain(stdout),
            vec![
                "src/a.ts".to_string(),
                "new.ts".to_string(),
                "new.ts".to_string(), // rename keeps the destination path
                "added.rs".to_string(),
                "removed.rs".to_string(),
            ]
        );
    }

    #[test]
    fn parse_porcelain_strips_quotes_and_handles_renames() {
        // git quotes paths with spaces/special chars; renames read "old -> new".
        let stdout = concat!(
            " M \"path with space.ts\"\n",
            "R  \"old name.ts\" -> \"new name.ts\"\n",
        );
        assert_eq!(
            parse_porcelain(stdout),
            vec!["path with space.ts".to_string(), "new name.ts".to_string(),]
        );
    }

    /// Verbatim `git status --porcelain` output for a repo containing a file
    /// literally named `a -> b.txt`, captured from git itself (macOS git 2.x).
    /// Splitting on ` -> ` before reading the quotes reported `b.txt"` — a path
    /// that does not exist, trailing quote and all.
    #[test]
    fn parse_porcelain_keeps_filenames_containing_the_rename_arrow() {
        let stdout = concat!(
            " M \"a -> b.txt\"\n",
            "RM plain.txt -> \"new spaced.txt\"\n",
            "RM \"spaced name.txt\" -> renamed.txt\n",
        );
        assert_eq!(
            parse_porcelain(stdout),
            vec![
                "a -> b.txt".to_string(),     // NOT `b.txt"`
                "new spaced.txt".to_string(), // quoted destination
                "renamed.txt".to_string(),    // quoted source, bare destination
            ]
        );
    }

    /// With the default `core.quotepath`, git escapes non-ASCII as literal octal
    /// bytes: `é` arrives as the six characters `\303\251`. Merely stripping the
    /// quotes surfaced that raw escape to the user as the filename.
    #[test]
    fn parse_porcelain_decodes_octal_escaped_unicode() {
        let stdout = concat!(
            " M \"uni-caf\\303\\251.txt\"\n",
            "?? \"quo\\\"te.txt\"\n",
            "?? \"tab\\there.txt\"\n",
        );
        assert_eq!(
            parse_porcelain(stdout),
            vec![
                "uni-café.txt".to_string(),
                "quo\"te.txt".to_string(),
                "tab\there.txt".to_string(),
            ]
        );
    }

    /// `core.quotepath=false` (common for unicode users) emits raw UTF-8 with no
    /// quoting — it must pass through untouched.
    #[test]
    fn parse_porcelain_passes_through_raw_utf8_when_quotepath_disabled() {
        assert_eq!(
            parse_porcelain("RM uni-café.txt -> uni-renamed-é.txt\n"),
            vec!["uni-renamed-é.txt".to_string()]
        );
    }

    #[test]
    fn parse_porcelain_caps_at_20() {
        let mut stdout = String::new();
        for i in 0..50 {
            stdout.push_str(&format!(" M file{i}.ts\n"));
        }
        let parsed = parse_porcelain(&stdout);
        assert_eq!(parsed.len(), 20);
        assert_eq!(parsed[0], "file0.ts");
        assert_eq!(parsed[19], "file19.ts");
    }

    #[test]
    fn parse_porcelain_skips_blank_and_short_lines() {
        // Empty stdout and stray short lines yield nothing / are skipped.
        assert!(parse_porcelain("").is_empty());
        assert_eq!(
            parse_porcelain("\n M ok.ts\nxy\n"),
            vec!["ok.ts".to_string()]
        );
    }

    /// `HEAD` is what git prints for a detached HEAD, and it's what Claude's logs
    /// record in practice — it is not a branch, so it must never reach the UI.
    #[test]
    fn real_branch_rejects_git_placeholders() {
        assert_eq!(real_branch(Some("main".into())), Some("main".into()));
        assert_eq!(real_branch(Some("feat/x".into())), Some("feat/x".into()));
        assert_eq!(real_branch(Some("HEAD".into())), None);
        assert_eq!(real_branch(Some("(no branch)".into())), None);
        assert_eq!(real_branch(Some(String::new())), None);
        assert_eq!(real_branch(None), None);
    }

    #[test]
    fn git_current_branch_is_none_without_a_repo() {
        assert_eq!(git_current_branch(None), None);
        assert_eq!(git_current_branch(Some("")), None);
        assert_eq!(
            git_current_branch(Some("/nonexistent/definitely/not/here")),
            None
        );
    }

    #[test]
    fn git_changed_files_none_is_empty() {
        assert!(git_changed_files(None).is_empty());
        assert!(git_changed_files(Some("")).is_empty());
        // A non-existent directory must degrade to empty, never panic.
        assert!(git_changed_files(Some("/nonexistent/path/definitely/not/here")).is_empty());
    }

    #[test]
    fn claude_message_text_prefers_first_text_block() {
        // Bare string content (typical user turn).
        let text = ClaudeContent::Text("  hi there  ".into());
        assert_eq!(
            claude_message_text(Some(&text)).as_deref(),
            Some("hi there")
        );

        // Block array: first non-empty text block wins; tool_use is ignored.
        let blocks = ClaudeContent::Blocks(vec![
            ClaudeContentBlock {
                block_type: Some("tool_use".into()),
                name: Some("Edit".into()),
                text: None,
            },
            ClaudeContentBlock {
                block_type: Some("text".into()),
                name: None,
                text: Some("actual reply".into()),
            },
        ]);
        assert_eq!(
            claude_message_text(Some(&blocks)).as_deref(),
            Some("actual reply")
        );

        // No text block ⇒ None.
        let only_tool = ClaudeContent::Blocks(vec![ClaudeContentBlock {
            block_type: Some("tool_use".into()),
            name: Some("Bash".into()),
            text: None,
        }]);
        assert_eq!(claude_message_text(Some(&only_tool)), None);
        assert_eq!(claude_message_text(None), None);
    }
}
