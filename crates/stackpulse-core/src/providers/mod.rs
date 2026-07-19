//! Provider adapters.
//!
//! Each provider is a small unit struct implementing [`Provider`]. Adding a
//! provider means adding a module + registering it in [`crate::engine`] — no
//! changes to callers. Capabilities are advertised as a matrix, never a single
//! boolean (spec: capability-based integrations).

pub mod antigravity;
pub mod claude;
pub mod codex;
pub mod detection;
pub mod opencode;

use crate::datetime::{civil_from_days, days_from_civil, utc_date, CivilDate};
use crate::pricing;
use stackpulse_protocol::{
    Capability, CapabilityState, DailyUsage, ModelUsage, ProviderAnalytics, ProviderId,
    ProviderStatus, ProviderUsage, SpendWindow, TokenTotals,
};
use std::collections::HashMap;

/// One priced-later usage record (a single assistant turn), already normalized
/// to the "exclusive input" token convention (see `pricing`).
#[derive(Debug, Clone)]
pub struct UsageRecord {
    pub model: String,
    pub date: CivilDate,
    pub tokens: TokenTotals,
}

/// The adapter contract. Kept intentionally small and object-safe so the engine
/// can hold `Vec<Box<dyn Provider>>`.
pub trait Provider: Send + Sync {
    fn id(&self) -> ProviderId;

    /// The provider's capability matrix. Static per provider for now.
    fn capabilities(&self) -> Vec<(Capability, CapabilityState)>;

    /// Cheap detection: installed / authenticated / health, no log scanning.
    fn status(&self) -> ProviderStatus;

    /// Full scan of local data → normalized usage. Must never panic; on error
    /// it returns a `ProviderUsage` with a degraded [`IntegrationHealth`] and a
    /// human-readable note (graceful degradation — one provider failing must
    /// not take down the snapshot).
    fn scan(&self, now_unix: i64) -> ProviderUsage;
}

/// Build the standard windows (today / yesterday / last 30 days) plus a 30-day
/// per-model breakdown from a flat list of records. Pure and deterministic
/// given `now_unix`.
///
/// Returns `(windows, models, unpriceable_models)` where `unpriceable_models`
/// is the set of model names we counted tokens for but could not price.
pub fn aggregate(
    records: &[UsageRecord],
    now_unix: i64,
) -> (Vec<SpendWindow>, Vec<ModelUsage>, Vec<String>) {
    let today = utc_date(now_unix);
    let today_days = days_from_civil(today.year, today.month, today.day);
    let yesterday = civil_from_days(today_days - 1);
    let cutoff_30 = today_days - 29; // inclusive 30-day window ending today

    let mut w_today = SpendWindow {
        label: "today".into(),
        ..Default::default()
    };
    let mut w_yesterday = SpendWindow {
        label: "yesterday".into(),
        ..Default::default()
    };
    let mut w_30 = SpendWindow {
        label: "last_30_days".into(),
        ..Default::default()
    };

    // Per-model accumulation for the 30-day window.
    let mut models: HashMap<String, ModelUsage> = HashMap::new();
    let mut unpriceable: HashMap<String, ()> = HashMap::new();

    for rec in records {
        let rec_days = days_from_civil(rec.date.year, rec.date.month, rec.date.day);
        let cost = pricing::estimate_cost(&rec.model, &rec.tokens, rec.date);
        if cost.is_none() && rec.tokens.grand_total() > 0 {
            unpriceable.insert(rec.model.clone(), ());
        }

        if rec.date == today {
            apply(&mut w_today, &rec.tokens, cost);
        }
        if rec.date == yesterday {
            apply(&mut w_yesterday, &rec.tokens, cost);
        }
        if rec_days >= cutoff_30 && rec_days <= today_days {
            apply(&mut w_30, &rec.tokens, cost);
            let entry = models
                .entry(rec.model.clone())
                .or_insert_with(|| ModelUsage {
                    model: rec.model.clone(),
                    ..Default::default()
                });
            entry.tokens.add(&rec.tokens);
            entry.records += 1;
            if let Some(c) = cost {
                entry.estimated_cost_usd = Some(entry.estimated_cost_usd.unwrap_or(0.0) + c);
            }
        }
    }

    // Sort models by estimated cost desc, then token total desc (most expensive
    // first — spec wants "most expensive sessions/models" surfaced).
    let mut model_vec: Vec<ModelUsage> = models.into_values().collect();
    model_vec.sort_by(|a, b| {
        b.estimated_cost_usd
            .unwrap_or(0.0)
            .partial_cmp(&a.estimated_cost_usd.unwrap_or(0.0))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.tokens.grand_total().cmp(&a.tokens.grand_total()))
    });

    let mut unpriceable_vec: Vec<String> = unpriceable.into_keys().collect();
    unpriceable_vec.sort();

    (vec![w_today, w_yesterday, w_30], model_vec, unpriceable_vec)
}

fn apply(window: &mut SpendWindow, tokens: &TokenTotals, cost: Option<f64>) {
    window.tokens.add(tokens);
    window.records += 1;
    if let Some(c) = cost {
        window.estimated_cost_usd = Some(window.estimated_cost_usd.unwrap_or(0.0) + c);
    }
}

/// Number of days in the analytics history / anomaly baseline window.
const ANALYTICS_DAYS: i64 = 30;

/// Compute derived efficiency analytics over the 30-day window from the same
/// flat record list. Pure and deterministic given `now_unix`.
///
/// - **cache savings**: for each priceable record, the USD difference between
///   paying the input rate and the (much cheaper) cache-read rate for the tokens
///   actually served from cache — i.e. money the prompt cache saved.
/// - **burn rate**: total estimated 30-day spend / number of active days.
/// - **daily history**: every day in the window (zeros filled), oldest → newest.
/// - **today vs. average**: today's spend as a multiple of the daily average
///   (an anomaly signal).
pub fn compute_analytics(records: &[UsageRecord], now_unix: i64) -> ProviderAnalytics {
    let today = utc_date(now_unix);
    let today_days = days_from_civil(today.year, today.month, today.day);
    let cutoff = today_days - (ANALYTICS_DAYS - 1);

    // day-number → (tokens, cost, records, saw_priceable_cost)
    let mut per_day: HashMap<i64, (TokenTotals, f64, u64, bool)> = HashMap::new();
    let mut total_30d = TokenTotals::default();
    let mut total_cost = 0.0f64;
    let mut any_cost = false;
    let mut cache_savings = 0.0f64;
    let mut any_savings = false;

    for rec in records {
        let d = days_from_civil(rec.date.year, rec.date.month, rec.date.day);
        if d < cutoff || d > today_days {
            continue;
        }
        let cost = pricing::estimate_cost(&rec.model, &rec.tokens, rec.date);

        // Measured cache savings: cache-read tokens × (input − cache_read) rate.
        if rec.tokens.cache_read_tokens > 0 {
            if let Some(rates) = pricing::rates_for(&rec.model, rec.date) {
                let saved =
                    rec.tokens.cache_read_tokens as f64 * (rates.input - rates.cache_read) / 1e6;
                if saved > 0.0 {
                    cache_savings += saved;
                    any_savings = true;
                }
            }
        }

        total_30d.add(&rec.tokens);
        if let Some(c) = cost {
            total_cost += c;
            any_cost = true;
        }
        let entry = per_day
            .entry(d)
            .or_insert((TokenTotals::default(), 0.0, 0, false));
        entry.0.add(&rec.tokens);
        entry.2 += 1;
        if let Some(c) = cost {
            entry.1 += c;
            entry.3 = true;
        }
    }

    // Every day in the window, oldest → newest, zeros filled for chart continuity.
    let mut daily = Vec::with_capacity(ANALYTICS_DAYS as usize);
    for offset in (0..ANALYTICS_DAYS).rev() {
        let d = today_days - offset;
        let date = civil_from_days(d).iso();
        match per_day.get(&d) {
            Some((tokens, cost, recs, has_cost)) => daily.push(DailyUsage {
                date,
                tokens: tokens.clone(),
                estimated_cost_usd: has_cost.then_some(*cost),
                records: *recs,
            }),
            None => daily.push(DailyUsage {
                date,
                ..Default::default()
            }),
        }
    }

    let active_days = per_day.values().filter(|(.., r, _)| *r > 0).count() as f64;
    let burn_rate_usd_per_day = (any_cost && active_days > 0.0).then_some(total_cost / active_days);

    let today_cost = per_day
        .get(&today_days)
        .map(|(_, c, _, has)| if *has { *c } else { 0.0 })
        .unwrap_or(0.0);
    // Compare today against the average of the days the user was ACTIVE, not
    // against total / 30. Dividing by 30 dilutes the baseline for anyone who
    // codes intermittently — a normal $30 day for someone active 2 days out of
    // 30 reads as a 15x "spend spike" and fires a false anomaly alert. The
    // active-day average asks the honest question: "is today unusually high for
    // a day I actually use this tool?" (matches `burn_rate_usd_per_day`).
    let avg = (active_days > 0.0).then_some(total_cost / active_days);
    let today_vs_avg_ratio = avg.filter(|a| *a > 0.0).map(|a| today_cost / a);

    ProviderAnalytics {
        cache_savings_usd: any_savings.then_some(cache_savings),
        burn_rate_usd_per_day,
        cache_hit_rate: total_30d.cache_hit_rate(),
        today_vs_avg_ratio,
        daily,
    }
}

/// Convenience: build a `(Capability, CapabilityState)` list from slices.
pub fn caps(
    supported: &[Capability],
    unsupported: &[Capability],
) -> Vec<(Capability, CapabilityState)> {
    let mut v: Vec<_> = supported
        .iter()
        .map(|c| (*c, CapabilityState::Supported))
        .collect();
    v.extend(
        unsupported
            .iter()
            .map(|c| (*c, CapabilityState::Unsupported)),
    );
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::datetime::civil_from_days;

    fn rec(days_ago: i64, model: &str, input: u64, output: u64) -> UsageRecord {
        let now = crate::datetime::now_unix();
        let today = days_from_civil(utc_date(now).year, utc_date(now).month, utc_date(now).day);
        UsageRecord {
            model: model.into(),
            date: civil_from_days(today - days_ago),
            tokens: TokenTotals {
                input_tokens: input,
                output_tokens: output,
                ..Default::default()
            },
        }
    }

    #[test]
    fn buckets_windows_correctly() {
        let now = crate::datetime::now_unix();
        let records = vec![
            rec(0, "claude-sonnet-4", 100, 10),  // today
            rec(1, "claude-sonnet-4", 200, 20),  // yesterday
            rec(10, "claude-opus-4", 300, 30),   // within 30d
            rec(60, "claude-sonnet-4", 999, 99), // outside 30d
        ];
        let (windows, models, _) = aggregate(&records, now);
        let today = &windows[0];
        let yesterday = &windows[1];
        let d30 = &windows[2];
        assert_eq!(today.records, 1);
        assert_eq!(today.tokens.input_tokens, 100);
        assert_eq!(yesterday.records, 1);
        assert_eq!(d30.records, 3); // excludes the 60-day-old record
                                    // two distinct models within 30d
        assert_eq!(models.len(), 2);
        // opus should sort before sonnet (more expensive)
        assert_eq!(models[0].model, "claude-opus-4");
    }

    #[test]
    fn unpriceable_models_are_reported() {
        let now = crate::datetime::now_unix();
        let records = vec![rec(0, "mystery-model-x", 1000, 100)];
        let (_w, _m, unpriceable) = aggregate(&records, now);
        assert_eq!(unpriceable, vec!["mystery-model-x".to_string()]);
    }

    fn rec_cached(days_ago: i64, model: &str, input: u64, cache_read: u64) -> UsageRecord {
        let now = crate::datetime::now_unix();
        let today = days_from_civil(utc_date(now).year, utc_date(now).month, utc_date(now).day);
        UsageRecord {
            model: model.into(),
            date: civil_from_days(today - days_ago),
            tokens: TokenTotals {
                input_tokens: input,
                cache_read_tokens: cache_read,
                ..Default::default()
            },
        }
    }

    #[test]
    fn analytics_computes_savings_daily_and_anomaly() {
        let now = crate::datetime::now_unix();
        let records = vec![
            rec_cached(0, "claude-sonnet-4", 1_000, 1_000_000), // today, heavy cache use
            rec_cached(5, "claude-sonnet-4", 1_000, 0),         // 5 days ago
        ];
        let a = compute_analytics(&records, now);

        // Daily history covers all 30 days.
        assert_eq!(a.daily.len(), 30);
        // Newest entry is "today" and has activity.
        assert!(a.daily.last().unwrap().records > 0);
        // 1M cache-read tokens on Sonnet save (3.0 - 0.30)/1e6 * 1e6 = $2.70.
        let savings = a.cache_savings_usd.expect("savings present");
        assert!((savings - 2.70).abs() < 1e-6, "savings was {savings}");
        // Burn rate is spend over active days (2 active days here).
        assert!(a.burn_rate_usd_per_day.is_some());
        // Today spent more than the 30-day daily average, so ratio > 1.
        assert!(a.today_vs_avg_ratio.unwrap() > 1.0);
        // Cache hit rate is high (almost all input was cache reads).
        assert!(a.cache_hit_rate.unwrap() > 0.99);
    }

    #[test]
    fn analytics_empty_is_graceful() {
        let a = compute_analytics(&[], crate::datetime::now_unix());
        assert_eq!(a.daily.len(), 30);
        assert!(a.cache_savings_usd.is_none());
        assert!(a.burn_rate_usd_per_day.is_none());
        assert!(a.today_vs_avg_ratio.is_none());
        assert!(a.cache_hit_rate.is_none());
    }

    /// Regression: the spend-anomaly ratio must divide by *active* days, not by a
    /// fixed 30. An intermittent user with a single active day is spending at
    /// exactly their own baseline — ratio 1.0, not a fabricated 30x "spike".
    #[test]
    fn analytics_ratio_uses_active_day_baseline_not_thirty() {
        let now = crate::datetime::now_unix();
        // One active day (today), $3.00 of Sonnet input. No other activity in the
        // window. burn_rate = today's cost over 1 active day; ratio = today / that
        // same active-day average = 1.0. The old `total_cost / 30` denominator
        // would have reported 30x here and tripped a false anomaly alert.
        let records = vec![rec(0, "claude-sonnet-4", 1_000_000, 0)]; // $3.00 today
        let a = compute_analytics(&records, now);

        let burn = a.burn_rate_usd_per_day.expect("burn rate present");
        assert!((burn - 3.0).abs() < 1e-6, "burn was {burn}");
        let ratio = a.today_vs_avg_ratio.expect("ratio present");
        assert!(
            (ratio - 1.0).abs() < 1e-6,
            "one active day at baseline must be ratio 1.0, was {ratio}"
        );
    }

    /// A genuine spike still reads as a spike: today's active-day cost well above
    /// the average of the other active days must yield ratio > 1.
    #[test]
    fn analytics_ratio_flags_a_real_spike() {
        let now = crate::datetime::now_unix();
        let records = vec![
            rec(0, "claude-sonnet-4", 4_000_000, 0),  // today: $12.00
            rec(5, "claude-sonnet-4", 1_000_000, 0),  // 5 days ago: $3.00
            rec(10, "claude-sonnet-4", 1_000_000, 0), // 10 days ago: $3.00
        ];
        let a = compute_analytics(&records, now);
        // total $18 over 3 active days → avg $6; today $12 → ratio 2.0.
        let ratio = a.today_vs_avg_ratio.expect("ratio present");
        assert!((ratio - 2.0).abs() < 1e-6, "ratio was {ratio}");
    }
}
