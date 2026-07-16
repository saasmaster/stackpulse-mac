//! Integration tests for the durable usage-history store.
//!
//! These drive the real Claude scanner over a sanitized fixture (mirroring
//! `tests/parsing.rs`) so the snapshot's `analytics.daily` is populated with real
//! measured usage, then exercise `history::record` / `history::query` end-to-end.
//!
//! ## Determinism notes
//! - The scan and every history call share one **fixed** `now_unix` pinned to the
//!   fixture's "today" (2026-07-12), so bucketing and the `days` filter are
//!   independent of the wall clock.
//! - The scanners skip files older than 35 days by *mtime*; freshly written temp
//!   files carry a current mtime, so the fixture is never filtered out regardless
//!   of the fixture's content dates.
//! - Discovery env vars are process-global, so a `Mutex` serializes the
//!   env-mutating tests and `HOME` is redirected to an empty temp dir so the
//!   host's real `~/.claude` can never leak into an assertion.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use stackpulse_core::datetime::{days_from_civil, utc_date};
use stackpulse_core::history;
use stackpulse_core::providers::claude::ClaudeProvider;
use stackpulse_core::providers::Provider;
use stackpulse_protocol::{ProviderId, ProviderUsage, UsageSnapshot, PROTOCOL_VERSION};

const CLAUDE_FIXTURE: &str = include_str!("fixtures/claude_sample.jsonl");

/// Serializes the env-mutating tests in this binary (env is process-global).
static ENV_LOCK: Mutex<()> = Mutex::new(());

/// A unique temp directory for one test run.
fn unique_tmp(tag: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("sp-history-{}-{tag}-{n}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write_file(path: &Path, contents: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, contents).unwrap();
}

/// Redirect all discovery env vars into `base`, with an empty `HOME` so no real
/// user data can be discovered. `claude_dir` is the root the scanner should see.
fn isolate_env(base: &Path, claude_dir: &Path) {
    let home = base.join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::env::set_var("HOME", &home);
    std::env::remove_var("USERPROFILE");
    std::env::remove_var("XDG_CONFIG_HOME");
    std::env::set_var("CLAUDE_CONFIG_DIR", claude_dir);
    std::env::set_var("CODEX_HOME", base.join("codex")); // keep codex isolated/empty
    std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN");
    std::env::remove_var("OPENAI_API_KEY");
}

/// `now_unix` pinned to noon UTC on the fixture's "today" (2026-07-12).
fn fixture_now_unix() -> i64 {
    days_from_civil(2026, 7, 12) * 86_400 + 12 * 3_600
}

/// Wrap provider usages into a minimal, valid snapshot at `now`.
fn snapshot_with(providers: Vec<ProviderUsage>, now: i64) -> UsageSnapshot {
    UsageSnapshot {
        protocol_version: PROTOCOL_VERSION,
        core_version: "test".into(),
        generated_at_unix: now,
        bucket_date_utc: utc_date(now).iso(),
        providers,
        alerts: Vec::new(),
        missions: Vec::new(),
        insights: Vec::new(),
        canaries: Vec::new(),
        pricing_note: "test".into(),
    }
}

/// Scan the Claude fixture at the fixed `now`, returning its `ProviderUsage`
/// (with populated `analytics.daily`). Caller must hold `ENV_LOCK`.
fn scan_claude_fixture(base: &Path) -> ProviderUsage {
    let claude_root = base.join("claude");
    write_file(
        &claude_root.join("projects").join("p").join("s.jsonl"),
        CLAUDE_FIXTURE,
    );
    isolate_env(base, &claude_root);
    ClaudeProvider.scan(fixture_now_unix())
}

#[test]
fn record_writes_file_and_query_returns_seeded_days() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("seed");
    let usage = scan_claude_fixture(&base);

    // Sanity: the fixture produced measured daily analytics to seed from.
    let analytics = usage.analytics.as_ref().expect("claude analytics present");
    assert!(
        analytics.daily.iter().any(|d| d.records > 0),
        "fixture should yield at least one active day"
    );

    let snap = snapshot_with(vec![usage], fixture_now_unix());
    let data_dir = base.join("store"); // does not exist yet — record must create it
    let data_dir_str = data_dir.to_str().unwrap().to_string();

    let points = history::record(&data_dir_str, &snap, fixture_now_unix(), None);

    // The store file was created.
    assert!(
        data_dir.join("history.json").exists(),
        "history.json must be written under data_dir"
    );

    // At least one Claude point, with the fixture's dates carried through.
    assert!(!points.is_empty(), "record should return seeded points");
    assert!(points.iter().all(|p| p.provider == ProviderId::Claude));
    assert!(
        points.iter().any(|p| p.date == "2026-07-12"),
        "today's fixture date should be present, got {:?}",
        points.iter().map(|p| &p.date).collect::<Vec<_>>()
    );
    assert!(
        points.iter().any(|p| p.date == "2026-07-11"),
        "yesterday's fixture date should be present"
    );

    // Tokens and cost are carried, not zeroed. Today has sonnet input tokens.
    let today = points
        .iter()
        .find(|p| p.date == "2026-07-12")
        .expect("today point");
    assert!(today.records > 0);
    assert!(today.tokens.input_tokens > 0);
    assert!(
        today.estimated_cost_usd.map(|c| c > 0.0).unwrap_or(false),
        "priceable sonnet usage should carry a positive cost estimate"
    );

    // `query` (no record) returns exactly what `record` returned.
    let queried = history::query(&data_dir_str, None, fixture_now_unix());
    assert_eq!(queried, points, "query must mirror record's result");

    // Points are sorted by date ascending.
    let dates: Vec<&String> = points.iter().map(|p| &p.date).collect();
    let mut sorted = dates.clone();
    sorted.sort();
    assert_eq!(dates, sorted, "points must be sorted by date ascending");

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn preexisting_older_entry_is_preserved_across_record() {
    let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let base = unique_tmp("preserve");
    let data_dir = base.join("store");
    std::fs::create_dir_all(&data_dir).unwrap();
    let data_dir_str = data_dir.to_str().unwrap().to_string();

    // Hand-write a store with an entry far older than the 30-day scan window.
    // It is not in the current `daily`, so `record` must leave it untouched.
    let preexisting = r#"{
      "2025-01-01|claude": {
        "tokens": { "input_tokens": 4242, "output_tokens": 100,
                    "cache_creation_tokens": 0, "cache_read_tokens": 0,
                    "reasoning_tokens": 0 },
        "estimated_cost_usd": 1.23,
        "records": 7
      }
    }"#;
    std::fs::write(data_dir.join("history.json"), preexisting).unwrap();

    let usage = scan_claude_fixture(&base);
    let snap = snapshot_with(vec![usage], fixture_now_unix());
    history::record(&data_dir_str, &snap, fixture_now_unix(), None);

    // Query all history: the ancient entry survives alongside the new days.
    let all = history::query(&data_dir_str, None, fixture_now_unix());
    let old = all
        .iter()
        .find(|p| p.date == "2025-01-01")
        .expect("pre-existing 2025-01-01 entry must be preserved");
    assert_eq!(old.provider, ProviderId::Claude);
    assert_eq!(old.tokens.input_tokens, 4242);
    assert_eq!(old.records, 7);
    assert_eq!(old.estimated_cost_usd, Some(1.23));
    // And the freshly-seeded fixture days are there too.
    assert!(all.iter().any(|p| p.date == "2026-07-12"));

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn days_filter_trims_to_recent_window() {
    let base = unique_tmp("filter");
    let data_dir = base.join("store");
    std::fs::create_dir_all(&data_dir).unwrap();
    let data_dir_str = data_dir.to_str().unwrap().to_string();

    // Three days: today, 5 days ago (both within a 7-day window), and 40 days ago.
    let store = r#"{
      "2026-07-12|claude": { "tokens": { "input_tokens": 10, "output_tokens": 0, "cache_creation_tokens": 0, "cache_read_tokens": 0, "reasoning_tokens": 0 }, "estimated_cost_usd": null, "records": 1 },
      "2026-07-07|claude": { "tokens": { "input_tokens": 20, "output_tokens": 0, "cache_creation_tokens": 0, "cache_read_tokens": 0, "reasoning_tokens": 0 }, "estimated_cost_usd": null, "records": 1 },
      "2026-06-02|claude": { "tokens": { "input_tokens": 30, "output_tokens": 0, "cache_creation_tokens": 0, "cache_read_tokens": 0, "reasoning_tokens": 0 }, "estimated_cost_usd": null, "records": 1 }
    }"#;
    std::fs::write(data_dir.join("history.json"), store).unwrap();

    // Last 7 days keeps today + 5-days-ago, drops the 40-days-ago point.
    let recent = history::query(&data_dir_str, Some(7), fixture_now_unix());
    let dates: Vec<&str> = recent.iter().map(|p| p.date.as_str()).collect();
    assert_eq!(dates, vec!["2026-07-07", "2026-07-12"]);

    // No filter returns all three (oldest first).
    let all = history::query(&data_dir_str, None, fixture_now_unix());
    assert_eq!(all.len(), 3);
    assert_eq!(all.first().unwrap().date, "2026-06-02");

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn corrupt_store_degrades_to_empty_without_panicking() {
    let base = unique_tmp("corrupt");
    let data_dir = base.join("store");
    std::fs::create_dir_all(&data_dir).unwrap();
    let data_dir_str = data_dir.to_str().unwrap().to_string();

    std::fs::write(data_dir.join("history.json"), "{ this is not valid json ][").unwrap();

    // Query must not panic; it returns an empty history.
    let queried = history::query(&data_dir_str, None, fixture_now_unix());
    assert!(queried.is_empty());

    // Record over the corrupt file with an empty snapshot must also be safe and
    // rewrite a valid (empty) store.
    let snap = snapshot_with(Vec::new(), fixture_now_unix());
    let points = history::record(&data_dir_str, &snap, fixture_now_unix(), None);
    assert!(points.is_empty());
    // The file is now valid JSON (an empty object).
    let contents = std::fs::read_to_string(data_dir.join("history.json")).unwrap();
    let parsed: serde_json::Value =
        serde_json::from_str(&contents).expect("valid json after record");
    assert!(parsed.as_object().map(|o| o.is_empty()).unwrap_or(false));

    std::fs::remove_dir_all(&base).ok();
}

#[test]
fn missing_store_returns_empty() {
    let base = unique_tmp("missing");
    let data_dir_str = base.join("nope").to_str().unwrap().to_string();
    // Nothing written; query on a non-existent dir is empty and panic-free.
    let queried = history::query(&data_dir_str, Some(30), fixture_now_unix());
    assert!(queried.is_empty());
    std::fs::remove_dir_all(&base).ok();
}
