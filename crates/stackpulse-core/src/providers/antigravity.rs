//! Antigravity (Google's agentic IDE) — local activity scanner.
//!
//! Antigravity is a Windsurf/Codeium-style agent IDE that talks to Gemini. Each
//! agent conversation is stored as a SQLite "trajectory" under
//! `~/.gemini/antigravity/conversations/<uuid>.db`, live-updating as you work.
//!
//! Token and cost accounting is done **server-side** by Gemini / Cloud Code and
//! is not written locally, so — honestly — we surface *activity* (how many
//! conversations, how recently active, which model) rather than fabricating
//! tokens or dollars. The model id is recovered by scanning a bounded prefix of
//! the DB bytes for the `gemini-…` identifier, which keeps the core dependency-
//! free (no SQLite crate) and portable. The most-recent conversations also feed
//! Mission discovery (see `missions.rs`) so an in-progress Antigravity session
//! shows up like a Claude/Codex one.

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::datetime::{days_from_civil, utc_date};
use crate::providers::{caps, Provider};
use stackpulse_protocol::{
    Capability as Cap, CapabilityState, IntegrationHealth, ModelUsage, ProviderId, ProviderStatus,
    ProviderUsage, SpendWindow, TokenTotals,
};

pub struct AntigravityProvider;

/// Only read this many bytes of a conversation DB when recovering the model id,
/// so a multi-MB trajectory never has to be read in full.
///
/// This was 256 KiB, which was **too small to be correct**. A conversation DB
/// holds both truncated per-step refs (`gemini-3-flash-a`) and the full id
/// (`gemini-3-flash-agent`); `extract_model` keeps the longest run, so it only
/// reports the real name if the full form is inside the window. Measured across
/// a real 30-conversation corpus, the first *complete* id sat as deep as
/// **412 KiB** — outside the old window — so the newest conversation reported
/// `gemini-3-flash-a`, a string that is not a model. 1 MiB clears the observed
/// worst case by ~2.5×, and a short window fails toward the generic fallback
/// label rather than toward a fabricated name (see `extract_model`).
const MODEL_SCAN_BYTES: u64 = 1024 * 1024;

/// `~/.gemini/antigravity` — the shared Gemini home holds Antigravity's data.
pub fn base_dir() -> Option<PathBuf> {
    crate::paths::home_dir().map(|h| h.join(".gemini").join("antigravity"))
}

fn conversations_dir() -> Option<PathBuf> {
    base_dir().map(|d| d.join("conversations"))
}

/// One conversation's local activity.
pub struct Conversation {
    pub id: String,
    pub mtime_unix: i64,
    pub model: Option<String>,
    /// Number of trajectory steps (agent actions/turns), read from the SQLite
    /// `steps` table on macOS. `None` when unavailable (non-macOS, or the DB was
    /// momentarily locked / unreadable).
    pub steps: Option<u64>,
}

/// Hard cap on how many conversations receive the expensive per-DB enrichment
/// (one SQLite open for the step count) on a single scan. Conversations
/// accumulate forever and this runs on the refresh cadence, so without a cap the
/// per-refresh cost grows unbounded. 200 sits far above any realistic recent set
/// while bounding the pathological case.
const MAX_ENRICH: usize = 200;

/// Cheap existence check for `status()`: enumerates the conversation DBs without
/// opening any SQLite file or reading any bytes (unlike `scan_conversations`).
fn has_conversations() -> bool {
    let Some(dir) = conversations_dir() else {
        return false;
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    entries
        .flatten()
        .any(|e| e.path().extension().and_then(|x| x.to_str()) == Some("db"))
}

/// Enumerate `conversations/*.db`, each with its last-modified time and (for the
/// most recent ones) the Gemini model and trajectory step count. Newest first.
/// Empty when the directory is absent. Never panics.
///
/// Enumeration (path + mtime) is cheap and covers every conversation, so counts
/// and windows stay complete. The two *expensive* per-DB operations are bounded:
/// the SQLite step count runs only for the newest [`MAX_ENRICH`] conversations,
/// and the model byte-scan runs lazily newest-first, stopping at the first hit —
/// the caller only ever surfaces a single model, so scanning every DB (up to
/// 1 MiB each) on every refresh was pure waste.
pub fn scan_conversations() -> Vec<Conversation> {
    let Some(dir) = conversations_dir() else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    // Cheap pass first: path + mtime + id only. No SQLite, no byte reads.
    let mut files: Vec<(PathBuf, i64, String)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("db") {
            continue;
        }
        let Some(mtime) = file_mtime_unix(&path) else {
            continue;
        };
        let id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        files.push((path, mtime, id));
    }
    files.sort_by_key(|(_, mtime, _)| std::cmp::Reverse(*mtime));

    let mut model_found = false;
    files
        .into_iter()
        .enumerate()
        .map(|(i, (path, mtime, id))| {
            let steps = if i < MAX_ENRICH {
                step_count(&path)
            } else {
                None
            };
            // Lazy, newest-first: scan for the model only until one is found.
            let model = if model_found {
                None
            } else {
                let m = extract_model(&path);
                model_found = m.is_some();
                m
            };
            Conversation {
                id,
                mtime_unix: mtime,
                model,
                steps,
            }
        })
        .collect()
}

fn file_mtime_unix(path: &Path) -> Option<i64> {
    let mtime = std::fs::metadata(path).ok()?.modified().ok()?;
    let secs = mtime.duration_since(UNIX_EPOCH).ok()?.as_secs();
    i64::try_from(secs).ok()
}

/// Count trajectory steps (agent actions/turns) by reading the conversation's
/// SQLite `steps` table. Opened **read-only** with a short busy timeout so it
/// coexists safely with Antigravity writing the same file — never locks, never
/// writes, and any error (locked, schema drift) degrades to `None`.
#[cfg(target_os = "macos")]
fn step_count(path: &Path) -> Option<u64> {
    use rusqlite::{Connection, OpenFlags};
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_millis(250));
    conn.query_row("SELECT count(*) FROM steps", [], |row| row.get::<_, i64>(0))
        .ok()
        .and_then(|n| u64::try_from(n).ok())
}

/// Non-macOS builds (the portability CI gates) have no Antigravity to read and no
/// SQLite dependency, so step counts are simply unavailable there.
#[cfg(not(target_os = "macos"))]
fn step_count(_path: &Path) -> Option<u64> {
    None
}

/// Recover the `gemini-…` model id from a bounded prefix of the DB bytes. The id
/// is stored as a plain (length-prefixed) string in the trajectory, so it shows
/// up as a contiguous ASCII run. The same DB holds both truncated per-step refs
/// (`gemini-3-flash-a`) and the full id (`gemini-3-flash-agent`), so we scan all
/// runs and keep the **longest** — the most complete name. Returns `None` if not
/// found (then we fall back to a generic label).
fn extract_model(path: &Path) -> Option<String> {
    use std::io::Read;
    let file = std::fs::File::open(path).ok()?;
    // `Read::read` fills the buffer with however much *one* syscall returns,
    // which is not required to be the whole request. Reading through a bounded
    // `take` loops until the cap or EOF, so the window is the size we said.
    let mut hay: Vec<u8> = Vec::new();
    file.take(MODEL_SCAN_BYTES).read_to_end(&mut hay).ok()?;

    let needle = b"gemini-";
    let mut best: Option<&[u8]> = None;
    let mut i = 0usize;
    while let Some(rel) = hay[i..].windows(needle.len()).position(|w| w == needle) {
        let start = i + rel;
        let mut end = start + needle.len();
        while end < hay.len() {
            let c = hay[end];
            let ok = c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-' || c == b'.';
            if !ok || end - start > 48 {
                break;
            }
            end += 1;
        }
        // A run touching the end of the window may have been cut by the window
        // rather than by the data. We cannot tell a real id from a severed one
        // — both are plausible ASCII — so this candidate is discarded rather
        // than risk reporting a name the user never used.
        let clipped = end == hay.len();
        if !clipped {
            let run = &hay[start..end];
            if best.map(|b| run.len() > b.len()).unwrap_or(true) {
                best = Some(run);
            }
        }
        i = end.max(start + 1);
    }
    let run = best?;
    // Guard against a bare "gemini-" with nothing after it.
    (run.len() > needle.len())
        .then(|| std::str::from_utf8(run).ok().map(|s| s.to_string()))
        .flatten()
}

impl AntigravityProvider {
    fn installed(&self) -> bool {
        base_dir().map(|d| d.is_dir()).unwrap_or(false)
    }
}

impl Provider for AntigravityProvider {
    fn id(&self) -> ProviderId {
        ProviderId::Antigravity
    }

    fn capabilities(&self) -> Vec<(Cap, CapabilityState)> {
        // Honest matrix: we read local conversation activity (history + live
        // task via recency) but no local tokens/cost — Antigravity accounts for
        // those server-side, so credits/limits are Unavailable (implementable via
        // a future authenticated Gemini/Cloud-Code API), not Unsupported.
        let mut c = caps(
            &[
                Cap::InstalledAppDetection,
                Cap::AuthDetection,
                Cap::LocalSessionHistory,
                Cap::LiveTaskDetection,
            ],
            &[
                Cap::VersionDetection,
                Cap::LocalCostScan,
                Cap::ModelBreakdown,
                Cap::CacheMetrics,
                Cap::ProjectAssociation,
                Cap::CompletionDetection,
                Cap::WaitingForInputDetection,
                Cap::ConversationPreview,
                Cap::ToolCallVisibility,
                Cap::Reply,
                Cap::ApproveReject,
                Cap::Stop,
                Cap::Resume,
                Cap::DeepLink,
                Cap::RemoteTaskState,
            ],
        );
        for cap in [Cap::SessionLimits, Cap::WeeklyLimits, Cap::CreditsAndSpend] {
            c.push((cap, CapabilityState::Unavailable));
        }
        c
    }

    fn status(&self) -> ProviderStatus {
        let installed = self.installed();
        // Cheap existence check — no SQLite opens or byte reads just to answer
        // "is there any conversation at all?".
        let authenticated = has_conversations();
        ProviderStatus {
            provider: ProviderId::Antigravity,
            display_name: ProviderId::Antigravity.display_name().to_string(),
            installed,
            authenticated,
            health: if installed {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            detected_version: None,
        }
    }

    fn scan(&self, now_unix: i64) -> ProviderUsage {
        let installed = self.installed();
        let convos = scan_conversations();
        let authenticated = !convos.is_empty();

        // Bucket conversation activity into the same windows the UI reads. These
        // `records` count *conversations touched*, not tokens — tokens/cost are
        // server-side. Token totals stay zero and cost stays `None` so nothing is
        // fabricated; the notes make the meaning explicit.
        let today = utc_date(now_unix);
        let today_days = days_from_civil(today.year, today.month, today.day);
        let cutoff_30 = today_days - 29;
        let mut today_count: u64 = 0;
        let mut d30_count: u64 = 0;
        for c in &convos {
            let d = utc_date(c.mtime_unix);
            let days = days_from_civil(d.year, d.month, d.day);
            if days == today_days {
                today_count += 1;
            }
            if days >= cutoff_30 && days <= today_days {
                d30_count += 1;
            }
        }

        let windows = if authenticated {
            vec![
                SpendWindow {
                    label: "today".into(),
                    tokens: TokenTotals::default(),
                    estimated_cost_usd: None,
                    records: today_count,
                },
                SpendWindow {
                    label: "last_30_days".into(),
                    tokens: TokenTotals::default(),
                    estimated_cost_usd: None,
                    records: d30_count,
                },
            ]
        } else {
            Vec::new()
        };

        // Surface the model as a single (cost-less) breakdown row so the card can
        // show "gemini-3-flash-agent" — records = conversations on that model.
        let model = convos
            .iter()
            .find_map(|c| c.model.clone())
            .unwrap_or_else(|| "gemini (Antigravity)".to_string());
        let models = if authenticated {
            vec![ModelUsage {
                model: model.clone(),
                tokens: TokenTotals::default(),
                estimated_cost_usd: None,
                records: convos.len() as u64,
            }]
        } else {
            Vec::new()
        };

        let total_steps: u64 = convos.iter().filter_map(|c| c.steps).sum();
        let mut notes: Vec<String> = Vec::new();
        if authenticated {
            let steps_phrase = if total_steps > 0 {
                format!(", {total_steps} agent steps")
            } else {
                String::new()
            };
            notes.push(format!(
                "{} Antigravity conversation{} on this Mac ({} touched today, {} in the last 30 days){}, model {}.",
                convos.len(),
                if convos.len() == 1 { "" } else { "s" },
                today_count,
                d30_count,
                steps_phrase,
                model,
            ));
        } else if installed {
            notes
                .push("Antigravity is installed but no local conversations were found yet.".into());
        } else {
            notes.push(
                "Antigravity not detected on this machine (looked for ~/.gemini/antigravity)."
                    .into(),
            );
        }
        if installed {
            notes.push(
                "Antigravity's token and cost usage is managed server-side by Gemini and isn't \
                 available locally — StackPulse shows local activity (conversations and recency)."
                    .into(),
            );
        }

        ProviderUsage {
            provider: ProviderId::Antigravity,
            display_name: ProviderId::Antigravity.display_name().to_string(),
            health: if installed {
                IntegrationHealth::FullySupported
            } else {
                IntegrationHealth::NotDetected
            },
            installed,
            authenticated,
            detected_version: None,
            plan_hint: None,
            windows,
            models,
            limits: Vec::new(),
            capabilities: self.capabilities(),
            notes,
            // No local token history → no efficiency analytics to compute.
            analytics: None,
            balance: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_model_prefers_the_longest_run() {
        // Mirrors the real DB: a truncated per-step ref appears first (and more
        // often), the full id appears later. The longest run must win.
        let mut data = b"\x00\x14prefix ".to_vec();
        data.extend_from_slice(b"gemini-3-flash-a"); // truncated ref
        data.extend_from_slice(b"\x10 middle binary \x00");
        data.extend_from_slice(b"gemini-3-flash-agent"); // full id
        data.extend_from_slice(b"\x10trailing\x00");
        let tmp = std::env::temp_dir().join("sp_ag_model_test.db");
        std::fs::write(&tmp, &data).unwrap();
        assert_eq!(
            extract_model(&tmp),
            Some("gemini-3-flash-agent".to_string())
        );
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn extract_model_none_without_marker() {
        let tmp = std::env::temp_dir().join("sp_ag_nomodel_test.db");
        std::fs::write(&tmp, b"no model marker here, just bytes").unwrap();
        assert_eq!(extract_model(&tmp), None);
        let _ = std::fs::remove_file(&tmp);
    }

    /// The field failure, pinned. On a real 30-conversation corpus the *newest*
    /// DB carried the truncated per-step ref at byte 27_422 and its first
    /// complete id at byte 412_816 — outside the old 256 KiB window. So the scan
    /// saw only `gemini-3-flash-a` and StackPulse displayed it as the model. It
    /// is not a model; it is a severed string.
    #[test]
    fn extract_model_finds_a_full_id_deeper_than_the_old_window() {
        let mut data = Vec::with_capacity(500 * 1024);
        data.extend_from_slice(b"\x00\x14header ");
        data.extend_from_slice(b"gemini-3-flash-a\x00"); // truncated ref, early
        data.resize(412_816, 0x11); // binary filler past the old 256 KiB bound
        data.extend_from_slice(b"gemini-3-flash-agent\x00");
        data.extend_from_slice(b"\x10trailing\x00");
        let tmp = std::env::temp_dir().join("sp_ag_deep_model_test.db");
        std::fs::write(&tmp, &data).unwrap();
        assert_eq!(
            extract_model(&tmp),
            Some("gemini-3-flash-agent".to_string()),
            "the complete id sits past 256 KiB in real data and must still be found"
        );
        let _ = std::fs::remove_file(&tmp);
    }

    /// A run touching the window's edge may have been severed by the window
    /// rather than by the data, and the two are indistinguishable. Reporting it
    /// would mean printing a model the user never ran, so it must be discarded —
    /// the caller then falls back to a generic label, which is honest.
    #[test]
    fn extract_model_discards_a_run_clipped_by_the_window() {
        let mut data = Vec::new();
        data.extend_from_slice(b"\x00pad\x00");
        // Fill so that a `gemini-…` run runs off the end of the scan window.
        data.resize(MODEL_SCAN_BYTES as usize - 10, 0x11);
        data.extend_from_slice(b"gemini-3-flash-agent-and-more-beyond-the-edge");
        let tmp = std::env::temp_dir().join("sp_ag_clipped_model_test.db");
        std::fs::write(&tmp, &data).unwrap();
        assert_eq!(
            extract_model(&tmp),
            None,
            "a run cut by the buffer edge must never be reported as a model"
        );
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn scan_and_status_never_panic_without_dir() {
        // Whatever the host state, these must be safe to call.
        let p = AntigravityProvider;
        let _ = p.status();
        let usage = p.scan(1_000_000);
        assert_eq!(usage.provider, ProviderId::Antigravity);
        // When not authenticated, no fabricated windows/models.
        if !usage.authenticated {
            assert!(usage.windows.is_empty());
            assert!(usage.models.is_empty());
        }
        // Always at least one explanatory note.
        assert!(!usage.notes.is_empty());
    }
}
