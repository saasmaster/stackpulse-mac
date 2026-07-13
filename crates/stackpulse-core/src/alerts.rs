//! Needs-attention alert engine.
//!
//! Alerts are derived **locally** from the same snapshot the core just computed
//! — no network, no polling of remote services. The rules are deterministic and
//! tested; thresholds are conservative defaults (a config surface can come
//! later). The UI renders these in a menu-bar badge, the popover, and a
//! Needs-Attention inbox.

use stackpulse_protocol::{Alert, AlertKind, AlertSeverity, IntegrationHealth, ProviderUsage};

/// Usage-limit percentage at/above which we raise a critical alert.
const CRIT_PCT: f64 = 90.0;
/// Usage-limit percentage at/above which we raise a warning.
const WARN_PCT: f64 = 75.0;
/// Today-vs-average spend multiple at/above which we flag a spend anomaly.
const ANOMALY_RATIO: f64 = 2.5;

/// Derive the needs-attention alerts for a set of providers, most severe first.
pub fn derive_alerts(providers: &[ProviderUsage], now_unix: i64) -> Vec<Alert> {
    let mut alerts = Vec::new();

    for p in providers {
        // 1) Live usage limits crossing a threshold.
        for lim in &p.limits {
            let severity = if lim.used_percent >= CRIT_PCT {
                AlertSeverity::Critical
            } else if lim.used_percent >= WARN_PCT {
                AlertSeverity::Warning
            } else {
                continue;
            };
            alerts.push(Alert {
                id: format!("{:?}:usage:{}", p.provider, lim.label),
                provider: p.provider,
                severity,
                kind: AlertKind::UsageThreshold,
                title: format!(
                    "{} {} limit at {:.0}%",
                    p.display_name, lim.label, lim.used_percent
                ),
                detail: format!(
                    "The {} window is {:.0}% consumed{}.",
                    lim.label,
                    lim.used_percent,
                    reset_phrase(lim.resets_at_unix, now_unix)
                ),
                created_at_unix: now_unix,
            });
        }

        // 2) Integration health problems that need the user.
        if let Some((severity, label)) = integration_issue(p.health) {
            alerts.push(Alert {
                id: format!("{:?}:integration", p.provider),
                provider: p.provider,
                severity,
                kind: AlertKind::IntegrationIssue,
                title: format!("{} integration needs attention", p.display_name),
                detail: format!("{} status: {label}.", p.display_name),
                created_at_unix: now_unix,
            });
        }

        // 3) Spend anomaly (today well above the 30-day daily average).
        if let Some(ratio) = p.analytics.as_ref().and_then(|a| a.today_vs_avg_ratio) {
            if ratio >= ANOMALY_RATIO {
                alerts.push(Alert {
                    id: format!("{:?}:anomaly", p.provider),
                    provider: p.provider,
                    severity: AlertSeverity::Warning,
                    kind: AlertKind::SpendAnomaly,
                    title: format!("{} spend spike today", p.display_name),
                    detail: format!(
                        "Today's estimated {} spend is {ratio:.1}× your 30-day daily average.",
                        p.display_name
                    ),
                    created_at_unix: now_unix,
                });
            }
        }
    }

    // Most severe first; stable within a severity (preserves provider order).
    alerts.sort_by_key(|a| std::cmp::Reverse(sev_rank(a.severity)));
    alerts
}

fn sev_rank(s: AlertSeverity) -> u8 {
    match s {
        AlertSeverity::Critical => 2,
        AlertSeverity::Warning => 1,
        AlertSeverity::Info => 0,
    }
}

/// Map a degraded integration health to (severity, human label). Healthy /
/// not-detected / partially-supported states produce no alert.
fn integration_issue(health: IntegrationHealth) -> Option<(AlertSeverity, &'static str)> {
    use IntegrationHealth::*;
    match health {
        TemporarilyBroken => Some((AlertSeverity::Critical, "integration temporarily broken")),
        Discontinued => Some((AlertSeverity::Critical, "provider discontinued")),
        AuthenticationChanged => Some((AlertSeverity::Warning, "authentication changed")),
        EndpointChanged => Some((AlertSeverity::Warning, "endpoint changed")),
        SessionSchemaChanged => Some((AlertSeverity::Warning, "session schema changed")),
        MetricsUnavailable => Some((AlertSeverity::Warning, "metrics unavailable")),
        UserActionRequired => Some((AlertSeverity::Warning, "user action required")),
        AppVersionUntested => Some((AlertSeverity::Info, "app version untested")),
        FullySupported | PartiallySupported | NotDetected => None,
    }
}

/// " — resets in 2h 14m" when a future reset time is known, else "".
fn reset_phrase(resets_at_unix: Option<i64>, now_unix: i64) -> String {
    let Some(reset) = resets_at_unix else {
        return String::new();
    };
    let remaining = reset - now_unix;
    if remaining <= 0 {
        return " — resetting now".to_string();
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
    use stackpulse_protocol::{LimitWindow, Provenance, ProviderAnalytics, ProviderId};

    fn base_provider(id: ProviderId) -> ProviderUsage {
        ProviderUsage {
            provider: id,
            display_name: id.display_name().to_string(),
            health: IntegrationHealth::FullySupported,
            installed: true,
            authenticated: true,
            detected_version: None,
            plan_hint: None,
            windows: Vec::new(),
            models: Vec::new(),
            limits: Vec::new(),
            capabilities: Vec::new(),
            notes: Vec::new(),
            analytics: None,
            balance: None,
        }
    }

    fn limit(label: &str, pct: f64) -> LimitWindow {
        LimitWindow {
            label: label.into(),
            used_percent: pct,
            window_minutes: 300,
            resets_at_unix: Some(1_000_000 + 3600),
            provenance: Provenance::ProviderReported,
        }
    }

    #[test]
    fn critical_and_warning_thresholds() {
        let mut p = base_provider(ProviderId::Codex);
        p.limits = vec![limit("5h", 96.0), limit("weekly", 80.0)];
        let alerts = derive_alerts(&[p], 1_000_000);
        assert_eq!(alerts.len(), 2);
        // Critical (96%) sorts before Warning (80%).
        assert_eq!(alerts[0].severity, AlertSeverity::Critical);
        assert_eq!(alerts[0].kind, AlertKind::UsageThreshold);
        assert!(alerts[0].title.contains("96%"));
        assert!(alerts[0].detail.contains("resets in 1h"));
        assert_eq!(alerts[1].severity, AlertSeverity::Warning);
    }

    #[test]
    fn below_threshold_is_silent() {
        let mut p = base_provider(ProviderId::Codex);
        p.limits = vec![limit("weekly", 42.0)];
        assert!(derive_alerts(&[p], 1_000_000).is_empty());
    }

    #[test]
    fn integration_and_anomaly() {
        let mut broken = base_provider(ProviderId::Claude);
        broken.health = IntegrationHealth::TemporarilyBroken;

        let mut spendy = base_provider(ProviderId::Codex);
        spendy.analytics = Some(ProviderAnalytics {
            today_vs_avg_ratio: Some(3.2),
            ..Default::default()
        });

        let alerts = derive_alerts(&[spendy, broken], 1_000_000);
        // Critical integration issue sorts ahead of the warning anomaly.
        assert_eq!(alerts[0].severity, AlertSeverity::Critical);
        assert_eq!(alerts[0].kind, AlertKind::IntegrationIssue);
        assert!(alerts.iter().any(|a| a.kind == AlertKind::SpendAnomaly));
    }

    #[test]
    fn healthy_provider_has_no_alerts() {
        let p = base_provider(ProviderId::Claude);
        assert!(derive_alerts(&[p], 1_000_000).is_empty());
    }
}
