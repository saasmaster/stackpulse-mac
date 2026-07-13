//! Integration tests for Agent Mission Control (`missions::discover`).
//!
//! Each test materializes a session file into a temp provider root, points the
//! discovery env vars at it (`$CLAUDE_CONFIG_DIR` / `$CODEX_HOME`), redirects
//! `$HOME` to an empty temp dir so the host's real `~/.claude` / `~/.codex`
//! sessions can never leak into an assertion, and passes a **fixed** `now_unix`
//! derived from the fixtures' own timestamps so recency is deterministic
//! regardless of the wall clock. Env is process-global, so a mutex serializes
//! these tests (mirroring `tests/parsing.rs`).

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use stackpulse_core::datetime::days_from_civil;
use stackpulse_core::missions::discover;
use stackpulse_protocol::{MissionStatus, ProviderId};

/// Serializes the env-mutating tests in this binary (env is process-global).
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Noon UTC on the fixtures' "today" (2026-07-12) — the reference clock.
fn now_unix() -> i64 {
    days_from_civil(2026, 7, 12) * 86_400 + 12 * 3_600
}

/// Unix seconds for a fixed UTC instant, matching the ISO strings in fixtures.
fn utc(h: i64, m: i64, s: i64) -> i64 {
    days_from_civil(2026, 7, 12) * 86_400 + h * 3_600 + m * 60 + s
}

fn unique_tmp(tag: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("sp-missions-{}-{tag}-{n}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write_file(path: &Path, contents: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, contents).unwrap();
}

/// Redirect discovery env vars into `base` with an empty `HOME`, and point the
/// Claude/Codex roots at `claude_dir` / `codex_dir` (either may be empty).
fn isolate_env(base: &Path, claude_dir: &Path, codex_dir: &Path) {
    let home = base.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::env::set_var("HOME", &home);
    std::env::remove_var("USERPROFILE");
    std::env::remove_var("XDG_CONFIG_HOME");
    std::env::set_var("CLAUDE_CONFIG_DIR", claude_dir);
    std::env::set_var("CODEX_HOME", codex_dir);
}

/// A Claude assistant JSONL line with usage + content, at timestamp `ts`.
fn claude_line(ts: &str, content: &str) -> String {
    format!(
        r#"{{"type":"assistant","timestamp":"{ts}","sessionId":"sess-abc","cwd":"/Users/demo/Documents/myproject","gitBranch":"feature/x","message":{{"role":"assistant","model":"claude-opus-4-8","content":{content},"usage":{{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":50}}}}}}"#
    )
}

/// Force a file's mtime to `unix_secs` (used to test the mtime recency guard).
fn set_mtime(path: &Path, unix_secs: i64) {
    let file = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    let when = UNIX_EPOCH + Duration::from_secs(unix_secs as u64);
    let times = std::fs::FileTimes::new().set_modified(when);
    file.set_times(times).unwrap();
}

#[test]
fn discovers_active_claude_session() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("claude");
    let claude_root = base.join("claude");
    let codex_root = base.join("codex"); // empty, kept isolated

    let first = r#"{"type":"user","timestamp":"2026-07-12T11:58:00.000Z","sessionId":"sess-abc","cwd":"/Users/demo/Documents/myproject","gitBranch":"feature/x","message":{"role":"user","content":[{"type":"text","text":"go"}]}}"#;
    // Earlier turn uses a tool; the final turn is a text reply → "Responding".
    let tool_turn = claude_line(
        "2026-07-12T11:59:30.000Z",
        r#"[{"type":"tool_use","name":"Edit"}]"#,
    );
    let text_turn = claude_line(
        "2026-07-12T12:00:00.000Z",
        r#"[{"type":"text","text":"done"}]"#,
    );
    write_file(
        &claude_root.join("projects").join("p").join("s.jsonl"),
        &format!("{first}\n{tool_turn}\n{text_turn}\n"),
    );
    isolate_env(&base, &claude_root, &codex_root);

    let missions = discover(now_unix());

    let m = missions
        .iter()
        .find(|m| m.provider == ProviderId::Claude)
        .expect("expected a Claude mission");
    assert_eq!(m.session_id, "sess-abc");
    assert_eq!(m.status, MissionStatus::Active, "last activity == now");
    assert_eq!(m.project_name.as_deref(), Some("myproject"));
    assert_eq!(
        m.project_path.as_deref(),
        Some("/Users/demo/Documents/myproject")
    );
    assert_eq!(m.branch.as_deref(), Some("feature/x"));
    assert_eq!(m.model.as_deref(), Some("claude-opus-4-8"));
    assert!(m.message_count >= 1, "should count assistant turns");
    assert_eq!(m.last_activity.as_deref(), Some("Responding"));
    assert_eq!(m.last_activity_unix, utc(12, 0, 0));
    assert_eq!(m.started_at_unix, Some(utc(11, 58, 0)));
    assert!(m.tokens_last_hour > 0, "recent tokens should be summed");

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn discovers_active_codex_session() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("codex");
    let claude_root = base.join("claude"); // empty, kept isolated
    let codex_root = base.join("codex");

    let meta = r#"{"timestamp":"2026-07-12T11:58:00.000Z","type":"session_meta","payload":{"id":"codex-123","cli_version":"1.4.2","cwd":"/Users/demo/Documents/backend"}}"#;
    let ctx = r#"{"timestamp":"2026-07-12T11:59:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6","cwd":"/Users/demo/Documents/backend"}}"#;
    let tok = r#"{"timestamp":"2026-07-12T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":50}}}}"#;
    write_file(
        &codex_root
            .join("sessions")
            .join("2026")
            .join("07")
            .join("12")
            .join("rollout.jsonl"),
        &format!("{meta}\n{ctx}\n{tok}\n"),
    );
    isolate_env(&base, &claude_root, &codex_root);

    let missions = discover(now_unix());

    let m = missions
        .iter()
        .find(|m| m.provider == ProviderId::Codex)
        .expect("expected a Codex mission");
    assert_eq!(m.session_id, "codex-123");
    assert_eq!(m.status, MissionStatus::Active);
    assert_eq!(m.model.as_deref(), Some("gpt-5.6"));
    assert_eq!(m.project_name.as_deref(), Some("backend"));
    assert_eq!(m.branch, None, "Codex logs carry no git branch");
    assert_eq!(m.last_activity.as_deref(), Some("Working"), "token_count");
    assert_eq!(m.last_activity_unix, utc(12, 0, 0));
    assert_eq!(m.started_at_unix, Some(utc(11, 58, 0)));
    assert!(m.tokens_last_hour > 0);

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn ignores_session_with_stale_last_timestamp() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("stale-ts");
    let claude_root = base.join("claude");
    let codex_root = base.join("codex");

    // Fresh mtime (written just now), but the last logged activity is 3h before
    // `now` — outside the 2h window, so it must NOT be discovered.
    let stale = claude_line(
        "2026-07-12T09:00:00.000Z",
        r#"[{"type":"text","text":"old"}]"#,
    );
    write_file(
        &claude_root.join("projects").join("p").join("s.jsonl"),
        &format!("{stale}\n"),
    );
    isolate_env(&base, &claude_root, &codex_root);

    let missions = discover(now_unix());
    assert!(
        missions.is_empty(),
        "a session last active >2h ago is not a mission: {missions:?}"
    );

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn ignores_session_with_old_mtime() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("old-mtime");
    let claude_root = base.join("claude");
    let codex_root = base.join("codex");

    // The content is recent, but the file's mtime is pushed 3h into the past so
    // the mtime prefilter drops it before it is ever read.
    let recent = claude_line(
        "2026-07-12T12:00:00.000Z",
        r#"[{"type":"text","text":"hi"}]"#,
    );
    let file = claude_root.join("projects").join("p").join("s.jsonl");
    write_file(&file, &format!("{recent}\n"));
    let now = now_unix();
    set_mtime(&file, now - 3 * 3600);
    isolate_env(&base, &claude_root, &codex_root);

    let missions = discover(now);
    assert!(
        missions.is_empty(),
        "a file with an old mtime is filtered out: {missions:?}"
    );

    // Sanity: with a fresh mtime the same file *is* discovered, proving mtime is
    // the sole reason it was excluded above.
    let recent_time = SystemTime::now();
    let f = std::fs::OpenOptions::new().write(true).open(&file).unwrap();
    f.set_times(std::fs::FileTimes::new().set_modified(recent_time))
        .unwrap();
    let missions = discover(now);
    assert_eq!(missions.len(), 1, "fresh mtime ⇒ discovered");

    std::fs::remove_dir_all(&base).ok();
}
