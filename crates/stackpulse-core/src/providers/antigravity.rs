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

/// Only read this many bytes of a conversation DB when recovering the model id —
/// the identifier appears within the first records, so we never read the whole
/// (multi-MB) file.
const MODEL_SCAN_BYTES: usize = 256 * 1024;

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
}

/// Enumerate `conversations/*.db`, each with its last-modified time and (from a
/// bounded byte scan) the Gemini model it used. Newest first. Empty when the
/// directory is absent. Never panics.
pub fn scan_conversations() -> Vec<Conversation> {
    let Some(dir) = conversations_dir() else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<Conversation> = Vec::new();
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
        out.push(Conversation {
            id,
            mtime_unix: mtime,
            model: extract_model(&path),
        });
    }
    out.sort_by_key(|c| std::cmp::Reverse(c.mtime_unix));
    out
}

fn file_mtime_unix(path: &Path) -> Option<i64> {
    let mtime = std::fs::metadata(path).ok()?.modified().ok()?;
    let secs = mtime.duration_since(UNIX_EPOCH).ok()?.as_secs();
    i64::try_from(secs).ok()
}

/// Recover the `gemini-…` model id from a bounded prefix of the DB bytes. The id
/// is stored as a plain (length-prefixed) string in the trajectory, so it shows
/// up as a contiguous ASCII run. The same DB holds both truncated per-step refs
/// (`gemini-3-flash-a`) and the full id (`gemini-3-flash-agent`), so we scan all
/// runs and keep the **longest** — the most complete name. Returns `None` if not
/// found (then we fall back to a generic label).
fn extract_model(path: &Path) -> Option<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let mut buf = vec![0u8; MODEL_SCAN_BYTES];
    let n = file.read(&mut buf).ok()?;
    let hay = &buf[..n];
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
        let run = &hay[start..end];
        if best.map(|b| run.len() > b.len()).unwrap_or(true) {
            best = Some(run);
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
        let authenticated = !scan_conversations().is_empty();
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

        let mut notes: Vec<String> = Vec::new();
        if authenticated {
            notes.push(format!(
                "{} Antigravity conversation{} on this Mac ({} touched today, {} in the last 30 days), model {}.",
                convos.len(),
                if convos.len() == 1 { "" } else { "s" },
                today_count,
                d30_count,
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
