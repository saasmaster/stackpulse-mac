//! Durable usage history.
//!
//! Persists per-day, per-provider usage totals to a small JSON file under a
//! client-provided `data_dir`, so trend charts can look back beyond the ~30 days
//! available in raw provider logs (which rotate). On first record it seeds from
//! the 30-day analytics already in the snapshot, then accumulates forever.
//!
//! Deliberately a plain JSON store (not SQLite): the data is tiny (≈ one row per
//! provider per day) and this keeps the portable core dependency-light and
//! C-toolchain-free (revisits ADR-0004). Read-only-safe: a corrupt/missing file
//! degrades to empty, never a panic.
//!
//! ## On-disk shape (`<data_dir>/history.json`)
//! A single JSON object keyed by `"YYYY-MM-DD|<provider_snake>"` mapping to a
//! stored record `{ tokens, estimated_cost_usd, records }`. Using a
//! [`BTreeMap`] keeps the file's key order stable across writes (nice diffs).
//! Writes are atomic: serialize to `history.json.tmp`, then `rename` over the
//! real file so a crash mid-write can never truncate the store.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use stackpulse_protocol::{HistoryPoint, ProviderId, TokenTotals, UsageSnapshot};

use crate::datetime::{days_from_civil, parse_iso_date, utc_date};

/// The file name of the store inside `data_dir`.
const STORE_FILE: &str = "history.json";
/// The temp file used for the atomic write.
const STORE_TMP: &str = "history.json.tmp";
/// Where an unparseable store is moved aside so its bytes stay recoverable
/// instead of being silently overwritten by the next write.
const STORE_CORRUPT: &str = "history.json.corrupt";

/// One persisted day/provider cell. The date and provider live in the map *key*
/// (`"YYYY-MM-DD|<provider_snake>"`), so they are not repeated here.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredRecord {
    #[serde(default)]
    tokens: TokenTotals,
    #[serde(default)]
    estimated_cost_usd: Option<f64>,
    #[serde(default)]
    records: u64,
}

/// Fold today's usage from `snapshot` into the store at `data_dir`, seeding from
/// the snapshot's 30-day analytics on first run, then return up to `days` of the
/// accumulated history (sorted oldest → newest, provider-stable).
///
/// Each provider's ~30 `DailyUsage` points overwrite (upsert) their day cells,
/// so the last 30 days are always refreshed from the current scan while days
/// older than the log-rotation window — recorded on previous runs — are left
/// untouched. That is how history accumulates past the raw logs. Zero-record
/// days are skipped so the file stays small.
///
/// Never panics: an unwritable `data_dir` degrades to an in-memory-only result.
pub fn record(
    data_dir: &str,
    snapshot: &UsageSnapshot,
    now_unix: i64,
    days: Option<u32>,
) -> Vec<HistoryPoint> {
    let mut map = load(data_dir);

    for provider in &snapshot.providers {
        let Some(analytics) = &provider.analytics else {
            continue;
        };
        if analytics.daily.is_empty() {
            continue;
        }
        let snake = provider_snake(provider.provider);
        for day in &analytics.daily {
            // Don't store empty days — keeps the store to real activity only.
            if day.records == 0 {
                continue;
            }
            map.insert(
                history_key(&day.date, &snake),
                StoredRecord {
                    tokens: day.tokens.clone(),
                    estimated_cost_usd: day.estimated_cost_usd,
                    records: day.records,
                },
            );
        }
    }

    save(data_dir, &map);
    // Re-read through the same path the client would, so `record` and `query`
    // are guaranteed to agree.
    query(data_dir, days, now_unix)
}

/// Read the accumulated history at `data_dir` (up to `days`) without recording.
///
/// Keeps only dates within the last `days` (default: all) up to `now_unix`'s UTC
/// date, sorts by (date asc, provider), and returns. A missing or malformed
/// store degrades to `[]` without panicking.
pub fn query(data_dir: &str, days: Option<u32>, now_unix: i64) -> Vec<HistoryPoint> {
    let map = load(data_dir);
    let today = utc_date(now_unix);
    let today_days = days_from_civil(today.year, today.month, today.day);

    let mut points: Vec<HistoryPoint> = Vec::with_capacity(map.len());
    for (key, rec) in map {
        let Some((date_str, snake)) = key.split_once('|') else {
            continue; // malformed key: skip, never panic
        };
        let Some(civil) = parse_iso_date(date_str) else {
            continue; // malformed date: skip
        };
        let rec_days = days_from_civil(civil.year, civil.month, civil.day);
        if !in_window(rec_days, today_days, days) {
            continue;
        }
        points.push(HistoryPoint {
            date: date_str.to_string(),
            provider: provider_from_snake(snake),
            tokens: rec.tokens,
            estimated_cost_usd: rec.estimated_cost_usd,
            records: rec.records,
        });
    }

    // Deterministic order: date ascending, then provider (by its debug name — a
    // stable, allocation-cheap tiebreak).
    points.sort_by(|a, b| {
        a.date
            .cmp(&b.date)
            .then_with(|| format!("{:?}", a.provider).cmp(&format!("{:?}", b.provider)))
    });
    points
}

// ---------------------------------------------------------------------------
// Internals (pure helpers + tolerant I/O)
// ---------------------------------------------------------------------------

/// Build the store key for a day + provider: `"YYYY-MM-DD|<provider_snake>"`.
fn history_key(date: &str, provider_snake: &str) -> String {
    format!("{date}|{provider_snake}")
}

/// The provider's canonical snake-case wire name (e.g. `open_code`), obtained
/// via serde so it round-trips exactly through [`provider_from_snake`].
fn provider_snake(provider: ProviderId) -> String {
    serde_json::to_value(provider)
        .ok()
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_else(|| "unknown".to_string())
}

/// Inverse of [`provider_snake`]. Unknown names decode to [`ProviderId::Unknown`]
/// (the protocol's `#[serde(other)]` catch-all), never an error.
fn provider_from_snake(snake: &str) -> ProviderId {
    serde_json::from_value(serde_json::Value::String(snake.to_string()))
        .unwrap_or(ProviderId::Unknown)
}

/// Whether a day (as a day-number since the epoch) is inside the query window:
/// never in the future relative to `today_days`, and — when `days` is set — no
/// older than the inclusive `days`-day window ending today.
fn in_window(rec_days: i64, today_days: i64, days: Option<u32>) -> bool {
    if rec_days > today_days {
        return false;
    }
    match days {
        Some(d) => rec_days >= today_days - (i64::from(d) - 1),
        None => true,
    }
}

fn store_path(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join(STORE_FILE)
}

fn quarantine_path(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join(STORE_CORRUPT)
}

/// Load the store tolerantly, without ever silently destroying data:
/// - a missing/unreadable file is genuinely empty → empty map;
/// - a present but unparseable file is *corruption*, not emptiness. Returning
///   empty and letting the next `save()` overwrite it would permanently destroy
///   the accumulated history this store exists to retain past the ~30-day log
///   window. So the corrupt bytes are first moved aside to a `.corrupt` sidecar
///   (recoverable), then we degrade to empty. Reads still never panic.
fn load(data_dir: &str) -> BTreeMap<String, StoredRecord> {
    let path = store_path(data_dir);
    let contents = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return BTreeMap::new(),
    };
    match serde_json::from_str(&contents) {
        Ok(map) => map,
        Err(_) => {
            // Only quarantine real bytes; an empty/whitespace file is just empty.
            if !contents.trim().is_empty() {
                let _ = std::fs::rename(&path, quarantine_path(data_dir));
            }
            BTreeMap::new()
        }
    }
}

/// Persist the store atomically: write to a temp file, then rename over the real
/// file. Creates `data_dir` if missing. All failures are swallowed (best-effort
/// durability — a read-only `data_dir` must not crash a scan).
fn save(data_dir: &str, map: &BTreeMap<String, StoredRecord>) {
    let dir = Path::new(data_dir);
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let Ok(json) = serde_json::to_string_pretty(map) else {
        return;
    };
    let tmp = dir.join(STORE_TMP);
    if std::fs::write(&tmp, json).is_err() {
        return;
    }
    let _ = std::fs::rename(&tmp, dir.join(STORE_FILE));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_format_is_date_pipe_provider_snake() {
        assert_eq!(
            history_key("2026-07-12", &provider_snake(ProviderId::Claude)),
            "2026-07-12|claude"
        );
        // Multi-word providers use true snake_case, not just a lowercase debug.
        assert_eq!(provider_snake(ProviderId::OpenCode), "open_code");
        assert_eq!(provider_snake(ProviderId::OpenRouter), "open_router");
    }

    #[test]
    fn provider_snake_round_trips() {
        for p in [
            ProviderId::Claude,
            ProviderId::Codex,
            ProviderId::MiniMax,
            ProviderId::OpenCode,
            ProviderId::OpenRouter,
            ProviderId::Zai,
        ] {
            assert_eq!(provider_from_snake(&provider_snake(p)), p);
        }
        // These names are the durable history keys on disk, so a change to one
        // silently orphans that provider's recorded days. MiniMax in particular
        // carries a hand-written `#[serde(rename)]` that nothing else would
        // catch if it were dropped.
        assert_eq!(provider_snake(ProviderId::MiniMax), "minimax");
        assert_eq!(provider_snake(ProviderId::OpenCode), "open_code");
        // An unrecognized snake name decodes to Unknown, never an error.
        assert_eq!(provider_from_snake("totally-made-up"), ProviderId::Unknown);
    }

    /// Regression: a corrupt (non-empty, unparseable) store must be preserved,
    /// never silently emptied-then-overwritten. This is the one dataset the app
    /// promises to retain past the raw log-rotation window.
    #[test]
    fn corrupt_store_is_quarantined_not_destroyed() {
        let dir = std::env::temp_dir().join("stackpulse_history_corrupt_test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let data_dir = dir.to_str().unwrap();
        let corrupt = b"{ this is not valid json history at all";
        std::fs::write(store_path(data_dir), corrupt).unwrap();

        // Loading must degrade to empty (never panic)...
        let map = load(data_dir);
        assert!(map.is_empty());
        // ...must NOT leave the original in place for the next save() to clobber...
        assert!(
            !store_path(data_dir).exists(),
            "the corrupt store must be moved aside, not left to be overwritten"
        );
        // ...and must keep the original bytes recoverable in the sidecar.
        let saved =
            std::fs::read(quarantine_path(data_dir)).expect("quarantine sidecar must exist");
        assert_eq!(saved, corrupt);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn empty_store_is_not_quarantined() {
        let dir = std::env::temp_dir().join("stackpulse_history_empty_test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let data_dir = dir.to_str().unwrap();
        std::fs::write(store_path(data_dir), b"   \n").unwrap();

        assert!(load(data_dir).is_empty());
        // A whitespace-only file is genuine emptiness, not corruption — no sidecar.
        assert!(!quarantine_path(data_dir).exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn in_window_filters_future_and_old_days() {
        let today = days_from_civil(2026, 7, 12);
        // Future days are always excluded.
        assert!(!in_window(today + 1, today, None));
        // With no limit, any past day is kept.
        assert!(in_window(today - 400, today, None));
        assert!(in_window(today, today, None));
        // `days = 7` keeps today .. today-6 inclusive, drops today-7 and older.
        assert!(in_window(today, today, Some(7)));
        assert!(in_window(today - 6, today, Some(7)));
        assert!(!in_window(today - 7, today, Some(7)));
    }
}
