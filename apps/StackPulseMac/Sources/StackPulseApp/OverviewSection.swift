import SwiftUI

/// Overview: an aggregate header plus a responsive grid of per-provider summary
/// cards (today + 30d cost, token volume, hottest live limit). Kept as an
/// internal pane; the ``OverviewDashboard`` body is the reusable part the Home
/// section also renders.
struct OverviewSection: View {
    var body: some View {
        SectionScaffold(section: .overview) { snapshot in
            OverviewDashboard(snapshot: snapshot)
        }
    }
}

/// The reusable overview body — aggregate stat tiles + a per-provider card grid +
/// the estimate footnote. Shared by ``OverviewSection`` and ``HomeSection`` so the
/// spend/limits dashboard is defined once (single owner of that rendering).
struct OverviewDashboard: View {
    let snapshot: UsageSnapshot
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            aggregateHeader(snapshot)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(snapshot.providers) { provider in
                    OverviewProviderCard(provider: provider)
                        .environmentObject(store)
                }
            }

            EstimateFootnote()
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 14, alignment: .top)]
    }

    private func aggregateHeader(_ snapshot: UsageSnapshot) -> some View {
        let detected = snapshot.installedProviders.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Across \(detected) detected provider\(detected == 1 ? "" : "s")",
                      systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 14
            ) {
                StatTile(
                    label: "30-day est.",
                    value: Format.usd(snapshot.total30Cost),
                    caption: "\(Format.usd(snapshot.totalTodayCost)) today",
                    systemImage: "dollarsign.circle",
                    tint: .green
                )
                StatTile(
                    label: "Cache saved (30d)",
                    value: Format.usd(snapshot.totalCacheSavings30d),
                    caption: "measured vs. full input rate",
                    systemImage: "bolt.horizontal.circle",
                    tint: .mint
                )
                StatTile(
                    label: "Burn rate",
                    value: Format.usd(snapshot.totalBurnRate30d),
                    caption: "est. $/active-day (combined)",
                    systemImage: "flame",
                    tint: .orange
                )
                StatTile(
                    label: "Turns (30d)",
                    value: Format.tokens(snapshot.total30Turns),
                    caption: "\(Format.tokens(snapshot.total30Tokens)) tokens",
                    systemImage: "arrow.left.arrow.right"
                )
                StatTile(
                    label: "Cache hit (30d)",
                    value: snapshot.aggregate30CacheHitRate.map { Format.percent($0 * 100) } ?? "—",
                    caption: "read ÷ (read + write)",
                    systemImage: "bolt.horizontal",
                    tint: .cyan
                )
            }
        }
        .glassCard(padding: 16)
    }
}

/// Compact per-provider card for the Overview grid.
struct OverviewProviderCard: View {
    let provider: ProviderUsage
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        if provider.installed {
            installedBody
        } else {
            NotDetectedCard(provider: provider)
        }
    }

    private var installedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            anomalyBadge

            HStack(alignment: .top, spacing: 0) {
                spendCell("Today", provider.today)
                Divider().frame(height: 38)
                spendCell("30 days", provider.last30)
                    .padding(.leading, 12)
            }

            limitRow

            if let top = topModel {
                Divider().opacity(0.4)
                HStack(spacing: 6) {
                    Image(systemName: "cpu").imageScale(.small).foregroundStyle(.secondary)
                    Text(top.model)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(Format.usd(top.estimated_cost_usd))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(color: SPStatus.healthColor(provider.health))
                .accessibilityLabel(SPStatus.healthLabel(provider.health))
            Text(provider.display_name)
                .font(.headline)
            Spacer()
            if let plan = provider.plan_hint {
                Chip(text: plan.capitalized, systemImage: "creditcard", tint: .cyan)
            }
        }
    }

    /// Amber "spend spike" badge when today runs hot vs. the 30-day daily
    /// average, or a quiet "below average" note when it runs cold. Never
    /// color-only — the text carries the meaning.
    @ViewBuilder private var anomalyBadge: some View {
        if let ratio = provider.analytics?.today_vs_avg_ratio {
            if ratio > 1.5 {
                Chip(text: "Spend spike — \(Format.ratio(ratio)) daily avg",
                     systemImage: "exclamationmark.triangle.fill",
                     tint: .orange)
            } else if ratio < 0.5 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.right").imageScale(.small)
                    Text("Today \(Format.ratio(ratio)) the daily average")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func spendCell(_ label: String, _ window: SpendWindow?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(Format.usd(window?.estimated_cost_usd))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(window.map { "\(Format.tokens($0.tokens.grandTotal)) tok · \($0.records) turns" } ?? "no activity")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var limitRow: some View {
        if let limit = provider.hottestLimit {
            VStack(spacing: 3) {
                HStack {
                    Text(limitLabel(limit.label))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.percent(limit.used_percent))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                    if let countdown = Format.resetCountdown(limit.resets_at_unix) {
                        Text("· \(countdown)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                MeterBar(fraction: limit.used_percent / 100,
                         tint: SPStatus.limitColor(limit.used_percent),
                         glowsWhenHigh: true)
                // Claude's limits can be a cached value the fetch could not
                // refresh. Unlabelled, a stale 82% reads exactly like a live 82% —
                // this card showed no age at all while the popover did.
                if provider.provider == "claude" {
                    LiveLimitsStatusNote(capturedAt: store.liveLimitsCapturedAt,
                                         isStale: store.liveLimitsAreStale,
                                         error: store.liveLimitsError)
                }
            }
        } else if provider.provider == "claude", let err = store.liveLimitsError {
            // "No live limits reported" blamed Claude for our own failure to
            // fetch. When we know the reason, give it — it's the difference
            // between a dead card and one telling you exactly what to do.
            LiveLimitsStatusNote(capturedAt: nil, isStale: false, error: err)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "gauge.open.with.lines.needle.33percent")
                    .imageScale(.small)
                Text("No live limits reported")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var topModel: ModelUsage? {
        provider.models.max(by: { ($0.estimated_cost_usd ?? -1) < ($1.estimated_cost_usd ?? -1) })
    }

    private func limitLabel(_ raw: String) -> String {
        switch raw {
        case "5h": return "Session (5h)"
        case "weekly": return "Weekly"
        default: return raw.capitalized
        }
    }
}
