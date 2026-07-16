//! Schema canaries — is what we're reading still what we think it is?
//!
//! Every number this app shows is parsed out of local logs whose format it does
//! not control, and priced from a table that has never heard of a model until
//! someone adds it. Both failures are **silent**: [`crate::pricing::rates_for`]
//! returns `None` for a model it doesn't know, so `estimate_cost` returns `None`,
//! so the record's tokens are counted while its cost is quietly dropped from
//! every total. Nothing in the UI says so. This module exists so the app can say
//! "I might be under-reporting" instead of showing a confidently wrong total.
//!
//! ## It derives; it does not re-read
//!
//! By the time [`check`] is called, the engine already holds the finished scan.
//! `ProviderUsage.models` carries, per model, the tokens counted and the cost
//! [`crate::providers::aggregate`] managed to estimate — so
//! **`estimated_cost_usd == None` alongside `tokens > 0` IS the unpriced-model
//! signal**, already computed, for free. Re-reading the same gigabytes to
//! rediscover it cost ~1s per refresh and partly undid a double-scan removal
//! this app already paid for once (protocol 1.16.0).
//!
//! Reading the engine's own verdict is also *more* correct than recomputing it:
//! the canary cannot drift from the numbers it annotates, because they are the
//! same numbers.
//!
//! The only filesystem work on the healthy path is a **stat-only** count of the
//! log files the scan considered (~33ms for ~1.2k files, against ~1040ms to
//! re-read them) so `files_seen` is a fact rather than a guess. No file contents
//! are opened unless the free signals already say something is wrong.
//!
//! ## Only providers whose logs we can actually locate get a canary
//!
//! A canary is emitted for a provider advertising [`Capability::LocalCostScan`]
//! as [`CapabilityState::Supported`] — today exactly Claude and Codex. The
//! detection-only providers advertise it `Unsupported`, and a `NoData` row for
//! each of them would be the noisy feed this is meant to replace.
//!
//! Read-only, offline, filesystem-only. Never panics: an unreadable root or file
//! degrades to less data, never an error.

use crate::paths;
use stackpulse_protocol::{
    CanaryStatus, Capability, CapabilityState, ProviderId, ProviderUsage, SchemaCanary,
    UnpricedModel,
};
use std::io::BufRead;
use std::path::{Path, PathBuf};

/// Only count session files touched within this many days — mirrors both
/// adapters, so `files_seen` counts exactly the files the scan read.
const SCAN_WINDOW_DAYS: i64 = 35;
/// Cap on reported unpriced models. A corrupted log can name a different garbage
/// model on every line; the biggest few are the finding, thousands of rows are
/// not. `detail` still states the true count.
const MAX_UNPRICED_REPORTED: usize = 12;
/// Cap on a model id interpolated into `detail`. The field is contracted as safe
/// to render verbatim, and a model id comes from a file we don't control.
const MAX_MODEL_CHARS: usize = 60;
/// Files the drift probe will open. It only answers "is there usage-shaped
/// content we failed to read?" — if a format changed, the first files show it,
/// and opening a thousand more cannot make the answer more true.
const PROBE_FILE_CAP: usize = 25;
/// Lines the drift probe reads per file. A session log can be enormous; a sample
/// is enough to spot usage-shaped content.
const PROBE_LINE_CAP: usize = 2_000;

/// Per-provider checks that what we read still matches what we understand, worst
/// status first. Derived from the scan `providers` already performed; `now_unix`
/// is the reference clock (testable).
///
/// A provider with no local cost scan yields no canary at all; one that scanned
/// and found nothing yields [`CanaryStatus::NoData`], which is explicitly not
/// reassurance — there was nothing to verify.
pub fn check(providers: &[ProviderUsage], now_unix: i64) -> Vec<SchemaCanary> {
    let mut out = Vec::new();
    for p in providers {
        if !claims_local_cost_scan(p) {
            continue;
        }
        // No known log layout means `files_seen` could only be invented, so the
        // honest move is no canary rather than a row with a fabricated count. A
        // new provider that gains LocalCostScan must add its layout below to be
        // covered — if that ever proves impossible, `files_seen` needs to become
        // `Option<u64>` in the protocol instead of being fudged here.
        let Some(layout) = layout_for(p.provider) else {
            continue;
        };
        out.push(report(p, &layout, now_unix));
    }
    // Worst first: a Drifted canary is the reason this list exists, and must not
    // sort below a provider that happens to be fine.
    out.sort_by(|a, b| {
        rank(a.status)
            .cmp(&rank(b.status))
            .then_with(|| a.provider.display_name().cmp(b.provider.display_name()))
    });
    out
}

fn rank(status: CanaryStatus) -> u8 {
    match status {
        CanaryStatus::Drifted => 0,
        // Never produced here (it's the deserialization catch-all), but ranked
        // above Ok so a status this core doesn't recognize can't hide as fine.
        CanaryStatus::Unknown => 1,
        CanaryStatus::Ok => 2,
        CanaryStatus::NoData => 3,
    }
}

fn claims_local_cost_scan(p: &ProviderUsage) -> bool {
    p.capabilities.iter().any(|(cap, state)| {
        *cap == Capability::LocalCostScan && *state == CapabilityState::Supported
    })
}

fn report(p: &ProviderUsage, layout: &Layout, now_unix: i64) -> SchemaCanary {
    let files_seen = count_files(layout, now_unix);
    let records_parsed = records_parsed(p);
    let unpriced = unpriced_models(p);
    let (status, detail, unpriced_models) = verdict(
        p.provider.display_name(),
        p.installed,
        files_seen,
        records_parsed,
        unpriced,
        // Lazy: the probe is the only content read in this module, and it runs
        // only down the branch where the free signals already say something's off.
        || probe_usage_shaped(layout, now_unix),
    );
    SchemaCanary {
        provider: p.provider,
        status,
        checked_at_unix: now_unix,
        detail,
        files_seen,
        records_parsed,
        unpriced_models,
    }
}

// ---------------------------------------------------------------------------
// Derived signals — no I/O
// ---------------------------------------------------------------------------

/// Records the scan turned into usage, as reported by the scan itself.
///
/// This is the 30-day window: `aggregate` builds `models` for that window only,
/// which is also the window the app prices and displays. The canary's counts and
/// the app's cost totals therefore describe exactly the same records — the point
/// of deriving rather than re-scanning.
fn records_parsed(p: &ProviderUsage) -> u64 {
    p.models.iter().map(|m| m.records).sum()
}

/// Models the scan counted tokens for but could not price, most tokens first.
///
/// `estimated_cost_usd` is `None` exactly when every record for that model was
/// unpriceable (`rates_for` is a pure function of the model id, so a model is
/// priceable or it isn't — never half). This reads the engine's own verdict
/// rather than re-deriving one that could disagree with it.
///
/// The zero-token filter is not a nicety. Claude logs a `<synthetic>` model on
/// locally-generated turns and Antigravity emits a cost-less breakdown row with
/// `TokenTotals::default()`; both are unpriced with zero tokens, so reporting
/// them would be a permanent, meaningless alarm on every machine. A model
/// contributes nothing to a cost total it was never in.
fn unpriced_models(p: &ProviderUsage) -> Vec<UnpricedModel> {
    let mut out: Vec<UnpricedModel> = p
        .models
        .iter()
        .filter(|m| m.estimated_cost_usd.is_none() && m.tokens.grand_total() > 0)
        .map(|m| UnpricedModel {
            model: m.model.clone(),
            records: m.records,
            tokens: m.tokens.clone(),
        })
        .collect();
    // Most tokens first — the biggest silent hole leads. Name breaks ties so the
    // order is stable across scans.
    out.sort_by(|a, b| {
        b.tokens
            .grand_total()
            .cmp(&a.tokens.grand_total())
            .then_with(|| a.model.cmp(&b.model))
    });
    out
}

/// Turn the signals into a verdict. The only claims made here are ones the scan
/// can support; there is deliberately no rule that fires on a hunch.
///
/// `probe` is passed unevaluated so the one expensive check stays lazy.
fn verdict(
    name: &str,
    installed: bool,
    files_seen: u64,
    records_parsed: u64,
    unpriced: Vec<UnpricedModel>,
    probe: impl FnOnce() -> u64,
) -> (CanaryStatus, String, Vec<UnpricedModel>) {
    if !unpriced.is_empty() {
        let detail = unpriced_detail(&unpriced);
        let mut reported = unpriced;
        reported.truncate(MAX_UNPRICED_REPORTED);
        return (CanaryStatus::Drifted, detail, reported);
    }
    if records_parsed > 0 {
        return (
            CanaryStatus::Ok,
            format!(
                "Read {records_parsed} usage {} from {files_seen} recent {name} {}. Every model in them has a pricing entry.",
                plural(records_parsed, "record", "records"),
                plural(files_seen, "log file", "log files"),
            ),
            Vec::new(),
        );
    }
    if installed && files_seen > 0 {
        let shaped = probe();
        if shaped > 0 {
            // Entries that look like token usage, none of which the scan turned
            // into a record: the signature of a format change. The numbers for
            // this provider are missing rather than zero.
            return (
                CanaryStatus::Drifted,
                format!(
                    "Found {} that look like token usage in {files_seen} recent {name} {}, but could not read any of them. {name}'s usage may be missing from these totals.",
                    plural_count(shaped, "entry", "entries"),
                    plural(files_seen, "log file", "log files"),
                ),
                Vec::new(),
            );
        }
        // Files, but nothing in them recorded usage: an idle install is not
        // drift, and saying so would be the false alarm this design rejects.
        return (
            CanaryStatus::NoData,
            format!(
                "Found {files_seen} recent {name} {}, but none of them recorded token usage — nothing to verify.",
                plural(files_seen, "log file", "log files"),
            ),
            Vec::new(),
        );
    }
    (
        CanaryStatus::NoData,
        format!("No {name} activity in the last {SCAN_WINDOW_DAYS} days — nothing to verify."),
        Vec::new(),
    )
}

/// The sentence a person reads. Names the model, states what it costs them in
/// trust, and never leaks a path, a line, or anything but a model id.
fn unpriced_detail(unpriced: &[UnpricedModel]) -> String {
    let total: u64 = unpriced.iter().map(|u| u.tokens.grand_total()).sum();
    let Some(first) = unpriced.first() else {
        return String::new();
    };
    let lead = clamp_model(&first.model);
    match unpriced.len() {
        1 => format!(
            "{lead} has no pricing entry — its {} tokens are counted but excluded from cost estimates.",
            human_tokens(total)
        ),
        n => format!(
            "{lead} and {} have no pricing entry — their {} tokens are counted but excluded from cost estimates.",
            plural_count((n - 1) as u64, "other model", "other models"),
            human_tokens(total)
        ),
    }
}

/// Compact token count for a sentence: 2.1B, 971.5M, 12.3K.
fn human_tokens(n: u64) -> String {
    let f = n as f64;
    if f >= 1e9 {
        format!("{:.1}B", f / 1e9)
    } else if f >= 1e6 {
        format!("{:.1}M", f / 1e6)
    } else if f >= 1e3 {
        format!("{:.1}K", f / 1e3)
    } else {
        n.to_string()
    }
}

/// Bound a log-supplied model id before it reaches a rendered sentence. Char
/// boundaries, not bytes — a model id is not guaranteed to be ASCII.
fn clamp_model(model: &str) -> String {
    if model.chars().count() <= MAX_MODEL_CHARS {
        return model.to_string();
    }
    let head: String = model.chars().take(MAX_MODEL_CHARS).collect();
    format!("{head}…")
}

fn plural(n: u64, one: &'static str, many: &'static str) -> &'static str {
    if n == 1 {
        one
    } else {
        many
    }
}

fn plural_count(n: u64, one: &'static str, many: &'static str) -> String {
    format!("{n} {}", plural(n, one, many))
}

// ---------------------------------------------------------------------------
// Filesystem: a stat-only file count, and one bounded probe
// ---------------------------------------------------------------------------

/// Where a provider keeps its session logs. Mirrors each adapter's own traversal
/// so `files_seen` counts exactly the files the scan being annotated read.
struct Layout {
    roots: fn() -> Vec<PathBuf>,
    /// Subdirectories of each root that hold session files.
    subdirs: &'static [&'static str],
    depth: usize,
    /// Raw substring marking a line that carries token usage. Matched on the raw
    /// text, deliberately independent of any typed parse: it still fires when the
    /// fields the adapter binds are renamed, which is precisely the drift a typed
    /// parse goes silent on.
    usage_marker: &'static str,
}

fn layout_for(id: ProviderId) -> Option<Layout> {
    match id {
        ProviderId::Claude => Some(Layout {
            roots: paths::claude_roots,
            subdirs: &["projects"],
            depth: 6,
            usage_marker: "\"usage\"",
        }),
        ProviderId::Codex => Some(Layout {
            roots: paths::codex_roots,
            subdirs: &["sessions", "archived_sessions"],
            depth: 7,
            usage_marker: "\"token_count\"",
        }),
        _ => None,
    }
}

/// Every log file the scan would have considered. Directory traversal and one
/// `stat` per file — no contents are opened.
fn log_files(layout: &Layout, now_unix: i64) -> Vec<PathBuf> {
    let mtime_cutoff = now_unix - SCAN_WINDOW_DAYS * 86_400;
    let mut out = Vec::new();
    for root in (layout.roots)() {
        for sub in layout.subdirs {
            let dir = root.join(sub);
            if !dir.is_dir() {
                continue;
            }
            for file in paths::collect_files(&dir, layout.depth, &|n| n.ends_with(".jsonl")) {
                if recently_modified(&file, mtime_cutoff) {
                    out.push(file);
                }
            }
        }
    }
    out
}

fn count_files(layout: &Layout, now_unix: i64) -> u64 {
    log_files(layout, now_unix).len() as u64
}

/// Count lines that look like they carry token usage, over a bounded sample.
///
/// Only ever called when the provider is installed and the scan produced zero
/// records — the case where something is already known to be wrong, so the cost
/// is paid exactly when it buys an answer. A sample can prove usage-shaped
/// content exists; it cannot prove it doesn't, and a probe that finds nothing
/// correctly falls back to `NoData` rather than claiming all-clear.
fn probe_usage_shaped(layout: &Layout, now_unix: i64) -> u64 {
    let mut files = log_files(layout, now_unix);
    // Newest last by name, so take from the end: if the format just moved, the
    // newest files are where it shows.
    files.sort();
    files.reverse();
    files.truncate(PROBE_FILE_CAP);
    files
        .iter()
        .map(|f| probe_file(f, layout.usage_marker))
        .sum()
}

fn probe_file(file: &Path, marker: &str) -> u64 {
    let f = match std::fs::File::open(file) {
        Ok(f) => f,
        Err(_) => return 0,
    };
    std::io::BufReader::new(f)
        .lines()
        .map_while(Result::ok)
        .take(PROBE_LINE_CAP)
        .filter(|line| line.contains(marker))
        .count() as u64
}

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
    use super::*;
    use crate::providers::{aggregate, Provider, UsageRecord};
    use stackpulse_protocol::{IntegrationHealth, ModelUsage, TokenTotals};

    /// A model id no pricing table will ever legitimately learn.
    ///
    /// Fixtures here must NOT name a real model. These tests were first written
    /// against `claude-fable-5` — the real unpriced model that motivated this
    /// module — and broke the moment the pricing table was taught its published
    /// rate, which is the fix working, not a regression. What is under test is
    /// the reporting of a gap, not any particular model's absence from the table.
    const NEVER_PRICED: &str = "mystery-model-9000";

    fn tokens(total: u64) -> TokenTotals {
        TokenTotals {
            input_tokens: total,
            ..Default::default()
        }
    }

    fn model(name: &str, cost: Option<f64>, records: u64, total_tokens: u64) -> ModelUsage {
        ModelUsage {
            model: name.to_string(),
            tokens: tokens(total_tokens),
            estimated_cost_usd: cost,
            records,
        }
    }

    fn provider_with(models: Vec<ModelUsage>) -> ProviderUsage {
        ProviderUsage {
            provider: ProviderId::Claude,
            display_name: "Claude".into(),
            health: IntegrationHealth::FullySupported,
            installed: true,
            authenticated: true,
            detected_version: None,
            plan_hint: None,
            windows: Vec::new(),
            models,
            limits: Vec::new(),
            capabilities: vec![(Capability::LocalCostScan, CapabilityState::Supported)],
            notes: Vec::new(),
            analytics: None,
            balance: None,
        }
    }

    /// `probe` must never run unless the free signals already say something's off.
    fn no_probe() -> u64 {
        panic!("probe must not run on this branch — it is the only content read");
    }

    fn verdict_for(
        p: &ProviderUsage,
        files_seen: u64,
    ) -> (CanaryStatus, String, Vec<UnpricedModel>) {
        verdict(
            p.provider.display_name(),
            p.installed,
            files_seen,
            records_parsed(p),
            unpriced_models(p),
            no_probe,
        )
    }

    /// The finding this module was built for, in the shape it took in Jorge's
    /// real logs: a model with real volume contributing $0 to every cost figure.
    #[test]
    fn an_unpriced_model_with_tokens_is_reported() {
        let p = provider_with(vec![
            model("claude-sonnet-5", Some(1.23), 10, 1_000),
            model(NEVER_PRICED, None, 2, 1_100_000),
        ]);
        let (status, detail, unpriced) = verdict_for(&p, 7);

        assert_eq!(status, CanaryStatus::Drifted);
        assert_eq!(records_parsed(&p), 12);
        assert_eq!(unpriced.len(), 1, "only the unpriceable model is reported");
        assert_eq!(unpriced[0].model, NEVER_PRICED);
        assert_eq!(unpriced[0].records, 2);
        assert_eq!(unpriced[0].tokens.grand_total(), 1_100_000);

        // Reads as a plain sentence, names the model, leaks no path.
        assert!(detail.contains(NEVER_PRICED), "detail: {detail}");
        assert!(detail.contains("1.1M"), "detail: {detail}");
        assert!(
            !detail.contains('/'),
            "detail must not carry a path: {detail}"
        );
    }

    /// Claude logs `<synthetic>` and Antigravity emits a cost-less row, both with
    /// zero tokens. Unpriced but costing nothing — reporting them would be a
    /// permanent false alarm, the failure mode this design rejects.
    #[test]
    fn an_unpriced_model_with_zero_tokens_is_not_reported() {
        let p = provider_with(vec![
            model("claude-sonnet-5", Some(1.23), 10, 1_000),
            model("<synthetic>", None, 154, 0),
            model("gemini-3-flash-agent", None, 9, 0),
        ]);
        let (status, _detail, unpriced) = verdict_for(&p, 3);
        assert!(
            unpriced.is_empty(),
            "zero-token models must not be reported"
        );
        assert_eq!(status, CanaryStatus::Ok);
    }

    #[test]
    fn a_fully_priced_log_is_ok() {
        let p = provider_with(vec![
            model("claude-opus-4-8", Some(10.0), 5, 1_000),
            model("claude-haiku-4-5", Some(0.1), 3, 500),
        ]);
        let (status, detail, unpriced) = verdict_for(&p, 2);
        assert_eq!(status, CanaryStatus::Ok);
        assert!(unpriced.is_empty());
        assert!(detail.contains('8'), "8 records: {detail}");
        assert!(
            detail.contains("2 recent Claude log files"),
            "detail: {detail}"
        );
    }

    /// This is the wiring that matters: real records → `providers::aggregate`
    /// (which does the real pricing) → canary. It is the canary's contract with
    /// `pricing`'s deliberate strictness — an unrecognized version of a KNOWN
    /// family returns `None` rather than borrowing a sibling's rate, and this is
    /// what stops that gap from being silent.
    #[test]
    fn an_unpriceable_record_survives_aggregate_and_reaches_the_canary() {
        let now = crate::datetime::now_unix();
        let date = crate::datetime::utc_date(now);
        let records = vec![
            UsageRecord {
                model: "claude-sonnet-5".into(),
                date,
                tokens: tokens(1_000),
            },
            UsageRecord {
                model: NEVER_PRICED.into(),
                date,
                tokens: tokens(500_000),
            },
        ];
        let (_windows, models, unpriceable) = aggregate(&records, now);
        assert!(
            unpriceable.contains(&NEVER_PRICED.to_string()),
            "aggregate must consider the fixture unpriceable, else this proves nothing"
        );

        let p = provider_with(models);
        let (status, detail, unpriced) = verdict_for(&p, 1);
        assert_eq!(status, CanaryStatus::Drifted);
        assert_eq!(unpriced.len(), 1);
        assert_eq!(unpriced[0].model, NEVER_PRICED);
        assert_eq!(unpriced[0].tokens.grand_total(), 500_000);
        assert!(detail.contains(NEVER_PRICED), "detail: {detail}");
    }

    /// NoData is not reassurance: nothing was verified. Asserting it is never Ok
    /// is the whole point of the distinction.
    #[test]
    fn no_data_yields_no_data_never_ok() {
        // Nothing on disk at all — no files, so nothing to probe.
        let (status, detail, unpriced) = verdict("Claude", true, 0, 0, Vec::new(), no_probe);
        assert_eq!(status, CanaryStatus::NoData);
        assert_ne!(status, CanaryStatus::Ok);
        assert!(unpriced.is_empty());
        assert!(detail.contains("nothing to verify"), "detail: {detail}");

        // Files present, but nothing in them recorded usage: still nothing to
        // verify — an idle install is not drift.
        let (status, detail, _) = verdict("Claude", true, 3, 0, Vec::new(), || 0);
        assert_eq!(status, CanaryStatus::NoData);
        assert!(detail.contains("none of them recorded"), "detail: {detail}");

        // A provider that isn't installed never probes.
        assert_eq!(
            verdict("Claude", false, 0, 0, Vec::new(), no_probe).0,
            CanaryStatus::NoData
        );
        assert_eq!(records_parsed(&provider_with(Vec::new())), 0);
    }

    /// The other true signal: entries that look like usage, none understood.
    #[test]
    fn usage_we_cannot_read_is_drift_not_silence() {
        let (status, detail, _) = verdict("Claude", true, 4, 0, Vec::new(), || 90);
        assert_eq!(status, CanaryStatus::Drifted);
        assert!(detail.contains("may be missing"), "detail: {detail}");
        assert!(detail.contains("90 entries"), "detail: {detail}");
    }

    /// The probe is the only content read in this module. It must stay off the
    /// healthy path entirely — `no_probe` panics if it is ever evaluated.
    #[test]
    fn the_probe_never_runs_when_the_free_signals_suffice() {
        // Records parsed ⇒ Ok without opening a file.
        let priced = provider_with(vec![model("claude-opus-4-8", Some(1.0), 5, 1_000)]);
        assert_eq!(verdict_for(&priced, 500).0, CanaryStatus::Ok);

        // An unpriced model ⇒ Drifted without opening a file.
        let unpriced = provider_with(vec![model(NEVER_PRICED, None, 5, 1_000)]);
        assert_eq!(verdict_for(&unpriced, 500).0, CanaryStatus::Drifted);
    }

    /// A raw substring probe still fires when the fields the adapter binds are
    /// renamed — the drift a typed parse goes silent on.
    #[test]
    fn the_probe_sees_usage_a_typed_parse_would_miss() {
        let dir = std::env::temp_dir().join(format!("sp-canary-{}-probe", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("renamed.jsonl");
        std::fs::write(
            &file,
            "{\"message\":{\"modelId\":\"x\",\"usage\":{\"prompt_tokens\":900}}}\n{\"type\":\"user\"}\n",
        )
        .unwrap();
        assert_eq!(probe_file(&file, "\"usage\""), 1);
        assert_eq!(probe_file(&file, "\"token_count\""), 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn probing_degrades_without_panicking() {
        let dir = std::env::temp_dir().join(format!("sp-canary-{}-malformed", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let missing = dir.join("does-not-exist.jsonl");
        let empty = dir.join("empty.jsonl");
        std::fs::write(&empty, "").unwrap();
        let garbage = dir.join("garbage.jsonl");
        // Junk, a truncated line, NULs, and invalid UTF-8.
        std::fs::write(&garbage, b"not json\n{\"partial\":\n\0\0\n\xff\xfe\n").unwrap();

        for f in [&missing, &empty, &garbage] {
            assert_eq!(probe_file(f, "\"usage\""), 0);
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn worst_status_sorts_first() {
        let mut ranks: Vec<u8> = [
            CanaryStatus::NoData,
            CanaryStatus::Ok,
            CanaryStatus::Drifted,
        ]
        .iter()
        .map(|s| rank(*s))
        .collect();
        ranks.sort();
        assert_eq!(
            ranks,
            vec![
                rank(CanaryStatus::Drifted),
                rank(CanaryStatus::Ok),
                rank(CanaryStatus::NoData)
            ]
        );
        assert!(rank(CanaryStatus::Unknown) < rank(CanaryStatus::Ok));
    }

    /// Detection-only providers advertise LocalCostScan as Unsupported; a row
    /// each would be the noisy feed this replaces.
    #[test]
    fn only_providers_with_a_local_cost_scan_get_a_canary() {
        let now = crate::datetime::now_unix();
        let mut detection_only = provider_with(vec![model("gemini", None, 1, 0)]);
        detection_only.provider = ProviderId::Gemini;
        detection_only.capabilities =
            vec![(Capability::LocalCostScan, CapabilityState::Unsupported)];
        assert!(!claims_local_cost_scan(&detection_only));
        assert!(check(&[detection_only], now).is_empty());

        // A provider that claims a cost scan but has no known log layout is
        // skipped rather than given an invented file count.
        let mut unknown_layout = provider_with(Vec::new());
        unknown_layout.provider = ProviderId::Cursor;
        assert!(claims_local_cost_scan(&unknown_layout));
        assert!(layout_for(ProviderId::Cursor).is_none());
        assert!(check(&[unknown_layout], now).is_empty());
    }

    #[test]
    fn many_unpriced_models_are_capped_but_counted_honestly() {
        let models = (0..30)
            .map(|i| model(&format!("mystery-model-{i:02}"), None, 1, 1_000 + i))
            .collect();
        let (status, detail, unpriced) = verdict_for(&provider_with(models), 1);
        assert_eq!(status, CanaryStatus::Drifted);
        assert_eq!(unpriced.len(), MAX_UNPRICED_REPORTED);
        // Biggest first, and the sentence still states the true total.
        assert_eq!(unpriced[0].model, "mystery-model-29");
        assert!(detail.contains("29 other models"), "detail: {detail}");
    }

    #[test]
    fn a_hostile_model_id_cannot_run_away_with_the_sentence() {
        let long = "x".repeat(500);
        let (_, detail, _) = verdict_for(&provider_with(vec![model(&long, None, 1, 10)]), 1);
        assert!(detail.chars().count() < 200, "detail: {detail}");
        assert!(detail.contains('…'));

        // Truncation must not split a multi-byte char.
        assert_eq!(
            clamp_model(&"é".repeat(100)).chars().count(),
            MAX_MODEL_CHARS + 1
        );
    }

    #[test]
    fn human_tokens_reads_like_a_person_wrote_it() {
        assert_eq!(human_tokens(0), "0");
        assert_eq!(human_tokens(999), "999");
        assert_eq!(human_tokens(12_345), "12.3K");
        assert_eq!(human_tokens(971_504_402), "971.5M");
        assert_eq!(human_tokens(2_113_928_705), "2.1B");
    }

    /// Never panics on a live machine, whatever it finds there, and the counts it
    /// reports are the scan's own.
    #[test]
    fn check_is_total_on_the_real_filesystem() {
        let now = crate::datetime::now_unix();
        let providers = vec![
            crate::providers::claude::ClaudeProvider.scan(now),
            crate::providers::codex::CodexProvider.scan(now),
        ];
        let out = check(&providers, now);
        for c in &out {
            assert!(!c.detail.is_empty());
            assert!(
                !c.detail.contains(".jsonl") && !c.detail.contains('/'),
                "detail leaked a path: {}",
                c.detail
            );
            // records_parsed is the scan's own count, not a re-derived one.
            let scanned = providers
                .iter()
                .find(|p| p.provider == c.provider)
                .map(records_parsed)
                .unwrap();
            assert_eq!(c.records_parsed, scanned);
            if !c.unpriced_models.is_empty() {
                assert_eq!(c.status, CanaryStatus::Drifted);
                assert!(c.unpriced_models[0].tokens.grand_total() > 0);
            }
        }
        // Worst-first ordering holds on whatever this machine has.
        assert!(out
            .windows(2)
            .all(|w| rank(w[0].status) <= rank(w[1].status)));
    }
}
