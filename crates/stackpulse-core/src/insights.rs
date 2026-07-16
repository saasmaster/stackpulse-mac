//! Derived intelligence — turns a scan into ranked, actionable insights.
//!
//! An [`Insight`] is an observation or recommendation (efficiency, cost, idle
//! resources, a stalled session), distinct from an [`Alert`] (a needs-attention
//! condition). Everything here is computed locally from the same scan — no
//! network — and every monetary figure is a local list-price estimate.
//!
//! The rules are deterministic given their inputs and `now_unix`; thresholds are
//! conservative named constants (a config surface can come later). Where an
//! insight would duplicate an [`Alert`] (see `alerts.rs`) we deliberately sit a
//! notch below the alert threshold so the two surfaces don't fire on the same
//! condition. Insights are ranked most-useful-first (impact High → Low, stable
//! within a tier).

use std::cmp::{Ordering, Reverse};

use stackpulse_protocol::{
    Insight, InsightImpact, InsightKind, Mission, MissionStatus, ProviderId, ProviderUsage,
    SpendWindow,
};

/// Cache-hit rate (0–1) below which we surface low cache efficiency.
const LOW_CACHE_HIT_RATE: f64 = 0.5;
/// Minimum cache-eligible token volume (read + creation, 30d) before the
/// low-cache rule fires — avoids nagging providers with near-zero usage.
const MIN_CACHE_TOKENS: u64 = 20_000;
/// Today-vs-30-day-average spend multiple at/above which we flag an anomaly.
/// Lower than the alert engine's 2.5 so insights also catch the milder spikes.
const SPEND_ANOMALY_RATIO: f64 = 2.0;
/// Anomaly multiple at/above which the insight is High rather than Medium impact.
const SPEND_ANOMALY_HIGH_RATIO: f64 = 3.0;
/// Lower edge (inclusive) of the "heads-up" usage-limit band.
const LIMIT_HEADSUP_MIN: f64 = 60.0;
/// Upper edge (exclusive) of the heads-up band. Kept a point under the alert
/// engine's 75% warning so an insight and an alert never fire for one window.
const LIMIT_HEADSUP_MAX: f64 = 74.0;
/// Within the heads-up band, at/above this the insight is Medium (else Low).
const LIMIT_HEADSUP_MEDIUM: f64 = 68.0;
/// Fraction of a provider's 30-day spend in one model that counts as concentrated.
const COST_CONCENTRATION_FRACTION: f64 = 0.70;
/// Ignore cost-concentration below this 30-day total (estimate) so it isn't noise.
const MIN_CONCENTRATION_COST_USD: f64 = 1.0;
/// A session needs at least this many turns to look "mid-task" rather than trivial.
const STALLED_MIN_MESSAGES: u64 = 8;
/// A session idle at least this many minutes may be stalled…
const STALLED_MIN_MINUTES: i64 = 8;
/// …but past this many minutes it has more likely just finished.
const STALLED_MAX_MINUTES: i64 = 40;
/// Emit at most this many individual idle-provider insights (else one summary).
const MAX_IDLE_INSIGHTS: usize = 3;
/// Emit at most this many stalled-session insights (most-recent first).
const MAX_STALLED_INSIGHTS: usize = 3;

/// Derive ranked insights (most useful first) from the scanned providers and the
/// observed missions. Pure and deterministic given its inputs and `now_unix`.
pub fn derive(providers: &[ProviderUsage], missions: &[Mission], now_unix: i64) -> Vec<Insight> {
    let mut out: Vec<Insight> = Vec::new();
    let mut idle: Vec<&ProviderUsage> = Vec::new();

    for p in providers {
        if let Some(a) = &p.analytics {
            // 1) Low cache efficiency (only when there was meaningful cache volume).
            if let Some(rate) = a.cache_hit_rate {
                let cache_vol = window(p, "last_30_days")
                    .map(|w| w.tokens.cache_read_tokens + w.tokens.cache_creation_tokens)
                    .unwrap_or(0);
                if rate < LOW_CACHE_HIT_RATE && cache_vol >= MIN_CACHE_TOKENS {
                    let pct = rate * 100.0;
                    let name = &p.display_name;
                    let savings = a
                        .cache_savings_usd
                        .map(|s| format!(" Cache reads have already saved an estimated ${s:.2} over 30 days;"))
                        .unwrap_or_else(|| " There is still room to cut input costs;".to_string());
                    out.push(Insight {
                        id: format!("insight:low_cache:{}", slug(p.provider)),
                        impact: InsightImpact::Medium,
                        kind: InsightKind::LowCacheEfficiency,
                        provider: Some(p.provider),
                        title: format!("Low cache efficiency on {name}"),
                        detail: format!(
                            "Only {pct:.0}% of {name}'s cache-eligible reads hit the cache over 30 days.{savings} keeping prompts and context stable across calls raises the hit rate."
                        ),
                        metric: Some(format!("{pct:.0}% cache")),
                        created_at_unix: now_unix,
                    });
                }
            }

            // 2) Spend anomaly (today notably above the 30-day daily average).
            if let Some(ratio) = a.today_vs_avg_ratio {
                if ratio >= SPEND_ANOMALY_RATIO {
                    let impact = if ratio >= SPEND_ANOMALY_HIGH_RATIO {
                        InsightImpact::High
                    } else {
                        InsightImpact::Medium
                    };
                    let name = &p.display_name;
                    let cost_phrase = window(p, "today")
                        .and_then(|w| w.estimated_cost_usd)
                        .map(|c| format!(", roughly ${c:.2} so far today"))
                        .unwrap_or_default();
                    out.push(Insight {
                        id: format!("insight:spend_anomaly:{}", slug(p.provider)),
                        impact,
                        kind: InsightKind::SpendAnomaly,
                        provider: Some(p.provider),
                        title: format!("{name} spend is up sharply today"),
                        detail: format!(
                            "Today's estimated {name} spend is {ratio:.1}× your 30-day daily average{cost_phrase}. Worth a look if that was not expected."
                        ),
                        metric: Some(format!("{ratio:.1}× avg")),
                        created_at_unix: now_unix,
                    });
                }
            }
        }

        // 5) Cost concentration in a single model (when the total isn't noise).
        let total_cost: f64 = p.models.iter().filter_map(|m| m.estimated_cost_usd).sum();
        if total_cost >= MIN_CONCENTRATION_COST_USD {
            if let Some(top) = p.models.iter().max_by(|a, b| {
                a.estimated_cost_usd
                    .unwrap_or(0.0)
                    .partial_cmp(&b.estimated_cost_usd.unwrap_or(0.0))
                    .unwrap_or(Ordering::Equal)
            }) {
                let top_cost = top.estimated_cost_usd.unwrap_or(0.0);
                let frac = top_cost / total_cost;
                if frac >= COST_CONCENTRATION_FRACTION {
                    let pct = frac * 100.0;
                    let name = &p.display_name;
                    let model = &top.model;
                    out.push(Insight {
                        id: format!("insight:cost_concentration:{}", slug(p.provider)),
                        impact: InsightImpact::Low,
                        kind: InsightKind::CostConcentration,
                        provider: Some(p.provider),
                        title: format!("Spend is concentrated in one model on {name}"),
                        detail: format!(
                            "{model} accounts for {pct:.0}% of your {name} spend (${top_cost:.2} of ${total_cost:.2}) over 30 days."
                        ),
                        metric: Some(format!("{pct:.0}%")),
                        created_at_unix: now_unix,
                    });
                }
            }
        }

        // 4) Collect idle providers (emitted after the loop so we can cap/summarize).
        if is_idle(p) {
            idle.push(p);
        }
    }

    // 3) Approaching a live limit — the single highest window in the heads-up band.
    if let Some((p, lim)) = highest_headsup_limit(providers) {
        let impact = if lim.used_percent >= LIMIT_HEADSUP_MEDIUM {
            InsightImpact::Medium
        } else {
            InsightImpact::Low
        };
        let name = &p.display_name;
        let phrase = reset_phrase(lim.resets_at_unix, now_unix);
        out.push(Insight {
            id: format!("insight:approaching_limit:{}:{}", slug(p.provider), lim.label),
            impact,
            kind: InsightKind::ApproachingLimit,
            provider: Some(p.provider),
            title: format!("{name} {} limit approaching", lim.label),
            detail: format!(
                "The {} window is {:.0}% consumed{}. Still under the 75% warning line — a good moment to pace usage.",
                lim.label, lim.used_percent, phrase
            ),
            metric: Some(format!("{:.0}%", lim.used_percent)),
            created_at_unix: now_unix,
        });
    }

    // 4) Idle providers — individual insights, or one summary when there are many.
    if idle.len() <= MAX_IDLE_INSIGHTS {
        for p in &idle {
            let name = &p.display_name;
            out.push(Insight {
                id: format!("insight:idle:{}", slug(p.provider)),
                impact: InsightImpact::Low,
                kind: InsightKind::IdleProvider,
                provider: Some(p.provider),
                title: format!("{name} is detected but unused"),
                detail: format!(
                    "{name} is installed and signed in but shows no usage in the last 30 days — you can ignore it or disconnect it."
                ),
                metric: None,
                created_at_unix: now_unix,
            });
        }
    } else {
        let n = idle.len();
        let names = idle
            .iter()
            .map(|p| p.display_name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        out.push(Insight {
            id: "insight:idle:summary".to_string(),
            impact: InsightImpact::Low,
            kind: InsightKind::IdleProvider,
            provider: None,
            title: format!("{n} detected providers are unused"),
            detail: format!(
                "{n} providers are installed and signed in but show no usage in the last 30 days ({names}). You can ignore them or disconnect the ones you do not use."
            ),
            metric: None,
            created_at_unix: now_unix,
        });
    }

    // 6) Stalled sessions — hedged, user-judged, capped to the most recent few.
    let mut stalled: Vec<&Mission> = missions
        .iter()
        .filter(|m| looks_stalled(m, now_unix))
        .collect();
    stalled.sort_by(|a, b| {
        b.last_activity_unix
            .cmp(&a.last_activity_unix)
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    for m in stalled.into_iter().take(MAX_STALLED_INSIGHTS) {
        let mins = ((now_unix - m.last_activity_unix) / 60).max(0);
        let pname = m.provider.display_name();
        let project = m
            .project_name
            .clone()
            .unwrap_or_else(|| "an unnamed project".to_string());
        let turns = m.message_count;
        out.push(Insight {
            id: format!("insight:stalled:{}", m.session_id),
            impact: InsightImpact::Medium,
            kind: InsightKind::StalledSession,
            provider: Some(m.provider),
            title: format!("{pname} session may be stalled"),
            detail: format!(
                "The {pname} session in {project} has been idle ~{mins}m after {turns} turns — it may be waiting on you, or it may simply be finished. This is a heuristic worth a glance, not a certainty."
            ),
            metric: Some(format!("idle ~{mins}m")),
            created_at_unix: now_unix,
        });
    }

    // Rank most-useful-first: High → Medium → Low, stable within a tier.
    out.sort_by_key(|i| Reverse(impact_rank(i.impact)));
    out
}

/// Ordering weight for an impact tier (higher = more useful, sorts first).
fn impact_rank(impact: InsightImpact) -> u8 {
    match impact {
        InsightImpact::High => 2,
        InsightImpact::Medium => 1,
        InsightImpact::Low => 0,
    }
}

/// The spend window with the given label, if present.
fn window<'a>(p: &'a ProviderUsage, label: &str) -> Option<&'a SpendWindow> {
    p.windows.iter().find(|w| w.label == label)
}

/// A stable lowercase key for a provider, e.g. `claude`, used in insight ids.
fn slug(id: ProviderId) -> String {
    format!("{id:?}").to_lowercase()
}

/// A detected-but-unused provider: installed + authenticated, yet no 30-day usage
/// (missing window, zero records, or all-zero tokens).
fn is_idle(p: &ProviderUsage) -> bool {
    if !(p.installed && p.authenticated) {
        return false;
    }
    match window(p, "last_30_days") {
        None => true,
        Some(w) => w.records == 0 || w.tokens.grand_total() == 0,
    }
}

/// The single highest live limit window across all providers whose usage sits in
/// the heads-up band `[LIMIT_HEADSUP_MIN, LIMIT_HEADSUP_MAX)`. Ties keep the first
/// (provider order) for determinism.
fn highest_headsup_limit(
    providers: &[ProviderUsage],
) -> Option<(&ProviderUsage, &stackpulse_protocol::LimitWindow)> {
    let mut best: Option<(&ProviderUsage, &stackpulse_protocol::LimitWindow)> = None;
    for p in providers {
        for lim in &p.limits {
            if lim.used_percent >= LIMIT_HEADSUP_MIN && lim.used_percent < LIMIT_HEADSUP_MAX {
                let better = match best {
                    Some((_, current)) => lim.used_percent > current.used_percent,
                    None => true,
                };
                if better {
                    best = Some((p, lim));
                }
            }
        }
    }
    best
}

/// Whether a mission looks stalled: quiet (idle status, or idle for 8–40 minutes)
/// while carrying enough turns to be mid-task rather than trivial or finished.
fn looks_stalled(m: &Mission, now_unix: i64) -> bool {
    let mins = (now_unix - m.last_activity_unix) / 60;
    let quiet = m.status == MissionStatus::Idle
        || (STALLED_MIN_MINUTES..=STALLED_MAX_MINUTES).contains(&mins);
    quiet && m.message_count >= STALLED_MIN_MESSAGES
}

/// " — resets in 2h 14m" when a future reset time is known, else "".
fn reset_phrase(resets_at_unix: Option<i64>, now_unix: i64) -> String {
    let Some(reset) = resets_at_unix else {
        return String::new();
    };
    let remaining = reset - now_unix;
    if remaining <= 0 {
        return " — resets soon".to_string();
    }
    let h = remaining / 3600;
    let m = (remaining % 3600) / 60;
    if h >= 24 {
        format!(" — resets in {}d {}h", h / 24, h % 24)
    } else if h > 0 {
        format!(" — resets in {h}h {m}m")
    } else {
        format!(" — resets in {m}m")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use stackpulse_protocol::{
        IntegrationHealth, LimitWindow, ModelUsage, Provenance, ProviderAnalytics, TokenTotals,
    };

    const NOW: i64 = 1_000_000;

    fn base_provider(id: ProviderId) -> ProviderUsage {
        ProviderUsage {
            provider: id,
            display_name: id.display_name().to_string(),
            health: IntegrationHealth::FullySupported,
            installed: true,
            authenticated: true,
            detected_version: None,
            plan_hint: None,
            // A used 30-day window by default → providers are NOT idle unless a
            // test clears this. Empty models/limits/analytics → no other rules.
            windows: vec![win("last_30_days", Some(5.0), 200_000, 0, 0, 20)],
            models: Vec::new(),
            limits: Vec::new(),
            capabilities: Vec::new(),
            notes: Vec::new(),
            analytics: None,
            balance: None,
        }
    }

    fn win(
        label: &str,
        cost: Option<f64>,
        input: u64,
        cache_read: u64,
        cache_creation: u64,
        records: u64,
    ) -> SpendWindow {
        SpendWindow {
            label: label.into(),
            tokens: TokenTotals {
                input_tokens: input,
                cache_read_tokens: cache_read,
                cache_creation_tokens: cache_creation,
                ..Default::default()
            },
            estimated_cost_usd: cost,
            records,
        }
    }

    fn model(name: &str, cost: f64) -> ModelUsage {
        ModelUsage {
            model: name.into(),
            tokens: TokenTotals::default(),
            estimated_cost_usd: Some(cost),
            records: 1,
        }
    }

    fn limit(label: &str, pct: f64) -> LimitWindow {
        LimitWindow {
            label: label.into(),
            used_percent: pct,
            window_minutes: 300,
            resets_at_unix: Some(NOW + 3600),
            provenance: Provenance::ProviderReported,
            captured_at_unix: None,
        }
    }

    fn mission(
        id: &str,
        provider: ProviderId,
        status: MissionStatus,
        last_activity_unix: i64,
        message_count: u64,
        project: Option<&str>,
    ) -> Mission {
        Mission {
            provider,
            session_id: id.into(),
            status,
            project_path: None,
            project_name: project.map(|s| s.to_string()),
            branch: None,
            model: None,
            started_at_unix: None,
            last_activity_unix,
            message_count,
            last_activity: None,
            tokens_last_hour: 0,
            changed_files: Vec::new(),
            last_message_preview: None,
            scope_flags: Vec::new(),
        }
    }

    fn of_kind(ins: &[Insight], kind: InsightKind) -> Vec<&Insight> {
        ins.iter().filter(|i| i.kind == kind).collect()
    }

    // ----- Low cache efficiency ------------------------------------------------

    #[test]
    fn low_cache_fires_with_volume() {
        let mut p = base_provider(ProviderId::Claude);
        p.windows = vec![win("last_30_days", Some(20.0), 500_000, 40_000, 60_000, 30)];
        p.analytics = Some(ProviderAnalytics {
            cache_hit_rate: Some(0.42),
            cache_savings_usd: Some(3.20),
            ..Default::default()
        });
        let ins = derive(&[p], &[], NOW);
        let low = of_kind(&ins, InsightKind::LowCacheEfficiency);
        assert_eq!(low.len(), 1);
        assert_eq!(low[0].impact, InsightImpact::Medium);
        assert_eq!(low[0].metric.as_deref(), Some("42% cache"));
        assert_eq!(low[0].provider, Some(ProviderId::Claude));
        assert!(low[0].detail.contains("$3.20"));
        assert_eq!(low[0].id, "insight:low_cache:claude");
    }

    #[test]
    fn healthy_cache_is_silent() {
        let mut p = base_provider(ProviderId::Claude);
        p.windows = vec![win("last_30_days", Some(20.0), 500_000, 90_000, 10_000, 30)];
        p.analytics = Some(ProviderAnalytics {
            cache_hit_rate: Some(0.85),
            ..Default::default()
        });
        assert!(of_kind(&derive(&[p], &[], NOW), InsightKind::LowCacheEfficiency).is_empty());
    }

    #[test]
    fn low_cache_needs_meaningful_volume() {
        let mut p = base_provider(ProviderId::Claude);
        // Low hit rate but tiny cache volume (2k < 20k) → do not nag.
        p.windows = vec![win("last_30_days", Some(0.10), 5_000, 1_000, 1_000, 2)];
        p.analytics = Some(ProviderAnalytics {
            cache_hit_rate: Some(0.40),
            ..Default::default()
        });
        assert!(of_kind(&derive(&[p], &[], NOW), InsightKind::LowCacheEfficiency).is_empty());
    }

    // ----- Spend anomaly -------------------------------------------------------

    #[test]
    fn spend_anomaly_high_tier() {
        let mut p = base_provider(ProviderId::Codex);
        p.windows = vec![
            win("last_30_days", Some(50.0), 1_000_000, 0, 0, 100),
            win("today", Some(12.0), 50_000, 0, 0, 10),
        ];
        p.analytics = Some(ProviderAnalytics {
            today_vs_avg_ratio: Some(3.4),
            ..Default::default()
        });
        let ins = derive(&[p], &[], NOW);
        let a = of_kind(&ins, InsightKind::SpendAnomaly);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].impact, InsightImpact::High);
        assert_eq!(a[0].metric.as_deref(), Some("3.4× avg"));
        assert!(a[0].detail.contains("$12.00"));
    }

    #[test]
    fn spend_anomaly_medium_tier() {
        let mut p = base_provider(ProviderId::Codex);
        p.analytics = Some(ProviderAnalytics {
            today_vs_avg_ratio: Some(2.3),
            ..Default::default()
        });
        let ins = derive(&[p], &[], NOW);
        let a = of_kind(&ins, InsightKind::SpendAnomaly);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].impact, InsightImpact::Medium);
    }

    #[test]
    fn spend_anomaly_below_ratio_is_silent() {
        let mut p = base_provider(ProviderId::Codex);
        p.analytics = Some(ProviderAnalytics {
            today_vs_avg_ratio: Some(1.5),
            ..Default::default()
        });
        assert!(of_kind(&derive(&[p], &[], NOW), InsightKind::SpendAnomaly).is_empty());
    }

    // ----- Approaching limit ---------------------------------------------------

    #[test]
    fn approaching_limit_picks_single_highest_in_band() {
        let mut a = base_provider(ProviderId::Codex);
        a.limits = vec![limit("5h", 65.0)];
        let mut b = base_provider(ProviderId::Claude);
        b.limits = vec![limit("weekly", 73.0)];
        let ins = derive(&[a, b], &[], NOW);
        let al = of_kind(&ins, InsightKind::ApproachingLimit);
        assert_eq!(al.len(), 1, "only the single highest window is emitted");
        assert_eq!(al[0].provider, Some(ProviderId::Claude));
        assert_eq!(al[0].impact, InsightImpact::Medium); // 73 >= 68
        assert_eq!(al[0].metric.as_deref(), Some("73%"));
    }

    #[test]
    fn approaching_limit_band_boundaries() {
        // 74% → no (upper edge exclusive, one point under the 75% alert).
        let mut p74 = base_provider(ProviderId::Codex);
        p74.limits = vec![limit("5h", 74.0)];
        assert!(of_kind(&derive(&[p74], &[], NOW), InsightKind::ApproachingLimit).is_empty());

        // 80% → no (that's alert territory, not a heads-up).
        let mut p80 = base_provider(ProviderId::Codex);
        p80.limits = vec![limit("5h", 80.0)];
        assert!(of_kind(&derive(&[p80], &[], NOW), InsightKind::ApproachingLimit).is_empty());

        // 65% → yes, Low impact (< 68).
        let mut p65 = base_provider(ProviderId::Codex);
        p65.limits = vec![limit("5h", 65.0)];
        let a65 = derive(&[p65], &[], NOW);
        let l65 = of_kind(&a65, InsightKind::ApproachingLimit);
        assert_eq!(l65.len(), 1);
        assert_eq!(l65[0].impact, InsightImpact::Low);

        // 60% → yes (inclusive lower edge).
        let mut p60 = base_provider(ProviderId::Codex);
        p60.limits = vec![limit("5h", 60.0)];
        assert_eq!(
            of_kind(&derive(&[p60], &[], NOW), InsightKind::ApproachingLimit).len(),
            1
        );

        // 68% → yes, Medium impact.
        let mut p68 = base_provider(ProviderId::Codex);
        p68.limits = vec![limit("5h", 68.0)];
        let a68 = derive(&[p68], &[], NOW);
        let l68 = of_kind(&a68, InsightKind::ApproachingLimit);
        assert_eq!(l68[0].impact, InsightImpact::Medium);

        // 59% → no (below the band).
        let mut p59 = base_provider(ProviderId::Codex);
        p59.limits = vec![limit("5h", 59.0)];
        assert!(of_kind(&derive(&[p59], &[], NOW), InsightKind::ApproachingLimit).is_empty());
    }

    // ----- Cost concentration --------------------------------------------------

    #[test]
    fn cost_concentration_fires_over_threshold() {
        let mut p = base_provider(ProviderId::Claude);
        p.models = vec![model("claude-opus", 8.0), model("claude-haiku", 2.0)]; // 80%
        let ins = derive(&[p], &[], NOW);
        let c = of_kind(&ins, InsightKind::CostConcentration);
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].impact, InsightImpact::Low);
        assert_eq!(c[0].metric.as_deref(), Some("80%"));
        assert!(c[0].detail.contains("claude-opus"));
        assert!(c[0].detail.contains("$8.00"));
        assert!(c[0].detail.contains("$10.00"));
    }

    #[test]
    fn cost_concentration_below_fraction_is_silent() {
        let mut p = base_provider(ProviderId::Claude);
        p.models = vec![model("a", 5.0), model("b", 5.0)]; // 50%
        assert!(of_kind(&derive(&[p], &[], NOW), InsightKind::CostConcentration).is_empty());
    }

    #[test]
    fn cost_concentration_ignores_trivial_totals() {
        let mut p = base_provider(ProviderId::Claude);
        // 83% share but only $0.60 total → below the $1 floor.
        p.models = vec![model("a", 0.50), model("b", 0.10)];
        assert!(of_kind(&derive(&[p], &[], NOW), InsightKind::CostConcentration).is_empty());
    }

    // ----- Idle provider -------------------------------------------------------

    #[test]
    fn idle_provider_fires() {
        let mut p = base_provider(ProviderId::Cursor);
        p.windows = vec![]; // no 30-day usage
        let ins = derive(&[p], &[], NOW);
        let idle = of_kind(&ins, InsightKind::IdleProvider);
        assert_eq!(idle.len(), 1);
        assert_eq!(idle[0].impact, InsightImpact::Low);
        assert_eq!(idle[0].provider, Some(ProviderId::Cursor));
        assert!(idle[0].detail.contains("last 30 days"));
    }

    #[test]
    fn used_provider_is_not_idle() {
        let p = base_provider(ProviderId::Cursor); // has a used 30d window
        assert!(of_kind(&derive(&[p], &[], NOW), InsightKind::IdleProvider).is_empty());
    }

    #[test]
    fn many_idle_providers_collapse_to_summary() {
        let ps: Vec<ProviderUsage> = [
            ProviderId::Cursor,
            ProviderId::Devin,
            ProviderId::Grok,
            ProviderId::Gemini,
        ]
        .into_iter()
        .map(|id| {
            let mut p = base_provider(id);
            p.windows = vec![];
            p
        })
        .collect();
        let ins = derive(&ps, &[], NOW);
        let idle = of_kind(&ins, InsightKind::IdleProvider);
        assert_eq!(
            idle.len(),
            1,
            "four idle providers collapse into one summary"
        );
        assert!(idle[0].provider.is_none());
        assert!(idle[0].title.contains('4'));
        assert_eq!(idle[0].id, "insight:idle:summary");
    }

    // ----- Stalled session -----------------------------------------------------

    #[test]
    fn stalled_session_is_hedged() {
        let m = mission(
            "sess-1",
            ProviderId::Claude,
            MissionStatus::Idle,
            NOW - 14 * 60,
            30,
            Some("stackpulse"),
        );
        let ins = derive(&[], &[m], NOW);
        let s = of_kind(&ins, InsightKind::StalledSession);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].impact, InsightImpact::Medium);
        assert_eq!(s[0].provider, Some(ProviderId::Claude));
        assert_eq!(s[0].metric.as_deref(), Some("idle ~14m"));
        assert!(s[0].title.contains("may be stalled"));
        // Honest, hedged language — never a claim of certainty.
        assert!(s[0].detail.contains("heuristic"));
        assert!(s[0].detail.contains("may"));
        assert!(s[0].detail.contains("stackpulse"));
    }

    #[test]
    fn stalled_ignores_active_and_low_turn_sessions() {
        // Active a minute ago (not idle, not in the 8–40m band).
        let active = mission(
            "a",
            ProviderId::Claude,
            MissionStatus::Active,
            NOW - 60,
            30,
            None,
        );
        // Idle but only 3 turns — too trivial to be "mid-task".
        let trivial = mission(
            "b",
            ProviderId::Claude,
            MissionStatus::Idle,
            NOW - 14 * 60,
            3,
            None,
        );
        let ins = derive(&[], &[active, trivial], NOW);
        assert!(of_kind(&ins, InsightKind::StalledSession).is_empty());
    }

    #[test]
    fn stalled_caps_at_three_most_recent() {
        let missions: Vec<Mission> = [
            ("s10", 10),
            ("s12", 12),
            ("s14", 14),
            ("s16", 16),
            ("s18", 18),
        ]
        .into_iter()
        .map(|(id, mins)| {
            mission(
                id,
                ProviderId::Claude,
                MissionStatus::Idle,
                NOW - mins * 60,
                20,
                None,
            )
        })
        .collect();
        let ins = derive(&[], &missions, NOW);
        let s = of_kind(&ins, InsightKind::StalledSession);
        assert_eq!(s.len(), 3, "capped at three");
        let ids: Vec<&str> = s.iter().map(|i| i.id.as_str()).collect();
        // The three most recent (smallest idle time) are kept.
        assert!(ids.contains(&"insight:stalled:s10"));
        assert!(ids.contains(&"insight:stalled:s12"));
        assert!(ids.contains(&"insight:stalled:s14"));
        assert!(!ids.contains(&"insight:stalled:s16"));
        assert!(!ids.contains(&"insight:stalled:s18"));
    }

    // ----- Ranking -------------------------------------------------------------

    #[test]
    fn insights_rank_high_to_low() {
        // High: spend anomaly on Claude.
        let mut high = base_provider(ProviderId::Claude);
        high.windows = vec![
            win("last_30_days", Some(50.0), 1_000_000, 0, 0, 100),
            win("today", Some(12.0), 50_000, 0, 0, 10),
        ];
        high.analytics = Some(ProviderAnalytics {
            today_vs_avg_ratio: Some(3.5),
            ..Default::default()
        });
        // Medium: low cache on Codex.
        let mut medium = base_provider(ProviderId::Codex);
        medium.windows = vec![win("last_30_days", Some(20.0), 500_000, 40_000, 60_000, 30)];
        medium.analytics = Some(ProviderAnalytics {
            cache_hit_rate: Some(0.40),
            cache_savings_usd: Some(3.20),
            ..Default::default()
        });
        // Low: idle Cursor.
        let mut low = base_provider(ProviderId::Cursor);
        low.windows = vec![];

        let ins = derive(&[high, medium, low], &[], NOW);
        assert!(ins.len() >= 3);
        let ranks: Vec<u8> = ins.iter().map(|i| impact_rank(i.impact)).collect();
        assert!(
            ranks.windows(2).all(|w| w[0] >= w[1]),
            "impacts must be non-increasing: {ranks:?}"
        );
        assert_eq!(ins.first().unwrap().impact, InsightImpact::High);
        assert_eq!(ins.first().unwrap().kind, InsightKind::SpendAnomaly);
        assert_eq!(ins.last().unwrap().impact, InsightImpact::Low);
    }

    #[test]
    fn empty_inputs_produce_no_insights() {
        assert!(derive(&[], &[], NOW).is_empty());
    }
}
