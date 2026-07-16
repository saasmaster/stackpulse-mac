//! Golden-fixture contract tests for the Claude and Codex local scanners.
//!
//! These exercise the real scan paths end-to-end: a sanitized JSONL fixture is
//! materialized into a temp provider root, the relevant discovery env var is
//! pointed at it, and the provider is scanned with a **fixed** `now_unix`
//! derived from the fixture's own dates so bucketing is deterministic.
//!
//! ## Determinism notes
//! - `now_unix` is computed from the fixture "today" (2026-07-12) via
//!   [`stackpulse_core::datetime::days_from_civil`], so the today/yesterday/30d
//!   windows line up with the fixture timestamps regardless of the wall clock.
//! - The scanners skip files older than 35 days by mtime. Freshly written temp
//!   files carry a current mtime, which is within 35 days of the fixture date
//!   (the fixture is dated "now"), so nothing is filtered out.
//! - Env vars (`HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME`) are
//!   process-global. Tests here run in one binary; a mutex serializes them and
//!   each test sets every var it depends on, so there is no cross-test bleed.
//!   `HOME` is redirected to an empty temp dir so the host's real `~/.claude`
//!   or `~/.codex` can never leak into an assertion.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use stackpulse_core::datetime::days_from_civil;
use stackpulse_core::providers::claude::ClaudeProvider;
use stackpulse_core::providers::codex::CodexProvider;
use stackpulse_core::providers::Provider;
use stackpulse_protocol::{ProviderUsage, SpendWindow};

const CLAUDE_FIXTURE: &str = include_str!("fixtures/claude_sample.jsonl");
const CODEX_FIXTURE: &str = include_str!("fixtures/codex_sample.jsonl");

/// Serializes the env-mutating tests in this binary (env is process-global).
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// A unique temp directory for one test run.
fn unique_tmp(tag: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("sp-parsing-{}-{tag}-{n}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write_file(path: &Path, contents: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, contents).unwrap();
}

/// Redirect all discovery env vars into `base`, with an empty `HOME` so no real
/// user data can be discovered. `claude_dir` / `codex_dir` are the roots the
/// scanners should see.
fn isolate_env(base: &Path, claude_dir: &Path, codex_dir: &Path) {
    let home = base.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::env::set_var("HOME", &home);
    std::env::remove_var("USERPROFILE");
    std::env::remove_var("XDG_CONFIG_HOME");
    std::env::set_var("CLAUDE_CONFIG_DIR", claude_dir);
    std::env::set_var("CODEX_HOME", codex_dir);
    // Keep auth detection deterministic (assertions here don't hinge on it).
    std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN");
    std::env::remove_var("OPENAI_API_KEY");
}

/// `now_unix` pinned to noon UTC on the fixtures' "today" (2026-07-12).
fn fixture_now_unix() -> i64 {
    days_from_civil(2026, 7, 12) * 86_400 + 12 * 3_600
}

fn window<'a>(usage: &'a ProviderUsage, label: &str) -> &'a SpendWindow {
    usage
        .windows
        .iter()
        .find(|w| w.label == label)
        .unwrap_or_else(|| panic!("missing window {label:?}"))
}

#[test]
fn claude_fixture_scans_exactly() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("claude");
    let claude_root = base.join("claude");
    let codex_root = base.join("codex"); // unused here, kept isolated
    write_file(
        &claude_root.join("projects").join("p").join("s.jsonl"),
        CLAUDE_FIXTURE,
    );
    isolate_env(&base, &claude_root, &codex_root);

    let usage = ClaudeProvider.scan(fixture_now_unix());

    assert!(
        usage.installed,
        "temp claude root should be detected as installed"
    );

    // Dedup: the two identical (message.id, requestId) lines collapse to one, so
    // "today" holds exactly the sonnet turn + the unpriceable turn (not three).
    let today = window(&usage, "today");
    assert_eq!(today.records, 2, "duplicate assistant line must be deduped");
    assert_eq!(today.tokens.input_tokens, 1300); // 1000 (sonnet) + 300 (unpriceable)
    assert_eq!(today.tokens.output_tokens, 250); // 200 + 50
    assert_eq!(today.tokens.cache_creation_tokens, 100);
    assert_eq!(today.tokens.cache_read_tokens, 500);

    // A priceable model in the window ⇒ a positive local cost estimate.
    let cost = today
        .estimated_cost_usd
        .expect("sonnet turn should be priceable");
    assert!(cost > 0.0, "expected a positive cost estimate, got {cost}");

    // Yesterday's single sonnet turn buckets on its own.
    let yesterday = window(&usage, "yesterday");
    assert_eq!(yesterday.records, 1);
    assert_eq!(yesterday.tokens.input_tokens, 800);

    // The unpriceable model is surfaced in a note, not silently dropped.
    //
    // The fixture names a FICTIONAL model on purpose. This slot used to hold
    // `claude-fable-5`, picked because it happened to have no rate card — so the
    // day Fable was priced correctly, this test failed and the note it guards
    // stopped being exercised. A real id makes the fixture expire; an imaginary
    // one can never be priced.
    assert!(
        usage
            .notes
            .iter()
            .any(|n| n.contains("acme-imaginary-model-1")),
        "expected an unpriceable-model note mentioning the fixture's unknown model, notes: {:?}",
        usage.notes
    );

    // Version is inferred from the (majority) `version` field.
    assert_eq!(usage.detected_version.as_deref(), Some("2.1.7"));

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn codex_fixture_scans_exactly() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("codex");
    let claude_root = base.join("claude"); // unused here, kept isolated
    let codex_root = base.join("codex");
    write_file(
        &codex_root
            .join("sessions")
            .join("2026")
            .join("07")
            .join("12")
            .join("rollout.jsonl"),
        CODEX_FIXTURE,
    );
    isolate_env(&base, &claude_root, &codex_root);

    let usage = CodexProvider.scan(fixture_now_unix());

    assert!(
        usage.installed,
        "temp codex root should be detected as installed"
    );

    // Dedup across the two identical token_count lines ⇒ exactly two turns.
    let today = window(&usage, "today");
    assert_eq!(
        today.records, 2,
        "duplicate token_count line must be deduped"
    );

    // fresh_input = input - cached_input, summed over both turns:
    //   (2000 - 800) + (3000 - 1000) = 1200 + 2000 = 3200.
    assert_eq!(
        today.tokens.input_tokens, 3200,
        "fresh input must exclude cached"
    );
    assert_eq!(today.tokens.cache_read_tokens, 1800); // 800 + 1000 cached
    assert_eq!(today.tokens.output_tokens, 700); // 300 + 400
                                                 // Reasoning tokens are captured separately.
    assert_eq!(today.tokens.reasoning_tokens, 250); // 100 + 150

    let cost = today
        .estimated_cost_usd
        .expect("gpt-5.5 should be priceable");
    assert!(cost > 0.0, "expected a positive cost estimate, got {cost}");

    // cli_version from session_meta, plan_type from the rate-limit block.
    assert_eq!(usage.detected_version.as_deref(), Some("1.4.2"));
    assert_eq!(usage.plan_hint.as_deref(), Some("plus"));

    // The latest (09:05) rate-limits win over the earlier (09:00) block.
    assert_eq!(usage.limits.len(), 2, "expected 5h + weekly limit windows");
    let five_h = usage
        .limits
        .iter()
        .find(|l| l.label == "5h")
        .expect("missing 5h limit window");
    assert_eq!(
        five_h.used_percent, 12.5,
        "5h% must come from the newest block"
    );
    assert_eq!(five_h.window_minutes, 300);
    let weekly = usage
        .limits
        .iter()
        .find(|l| l.label == "weekly")
        .expect("missing weekly limit window");
    assert_eq!(
        weekly.used_percent, 4.0,
        "weekly% must come from the newest block"
    );
    assert_eq!(weekly.window_minutes, 10_080);

    std::fs::remove_dir_all(&base).ok();
}
