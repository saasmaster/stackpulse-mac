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

            // Folders added but no AI tool detected yet: the aggregate above is all
            // dashes and every card below reads "not detected". Say why, and what
            // fills it, rather than leaving the reader to infer it.
            if snapshot.installedProviders.isEmpty {
                NoProvidersDetectedNote()
            }

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

            // A provider whose tokens and dollars are metered server-side gets its
            // measured activity and the reason for the missing money — never the
            // spend grid. Its windows carry `records` with zeroed tokens and no
            // cost, so the money UI would render "—" over "0 tok", asserting a zero
            // this Mac was never told.
            if provider.isActivityOnly {
                ProviderActivityRow(provider: provider)
                NoLocalSpendNote()
            } else {
                anomalyBadge

                HStack(alignment: .top, spacing: 0) {
                    spendCell("Today", provider.today)
                    Divider().frame(height: 38)
                    spendCell("30 days", provider.last30)
                        .padding(.leading, 12)
                }
            }

            limitRow

            // The per-model cost row prices tokens. With none measured locally it
            // can only restate the model name ``ProviderActivityRow`` already
            // carries, against an empty cost.
            if !provider.isActivityOnly, let top = topModel {
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
        if !provider.limits.isEmpty {
            VStack(spacing: 6) {
                // Every window, not just the hottest one: the session (5h) and the
                // weekly figure answer different questions and people read both.
                ForEach(provider.limits) { limit in
                    VStack(spacing: 3) {
                        HStack {
                            Text(limitLabel(limit.label))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.limitLeft(limit.used_percent))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                            if let countdown = Format.resetCountdown(limit.resets_at_unix) {
                                Text("· \(countdown)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        MeterBar(fraction: Format.limitLeftFraction(limit.used_percent),
                                 tint: SPStatus.limitColor(limit.used_percent),
                                 glowsWhenHigh: true)
                        if provider.provider == "claude",
                           limit.provenance == AnthropicUsageClient.liveProvenance {
                            LimitForecastNote(forecast: store.limitForecast(for: limit),
                                              isStale: limit.isStale(staleAfter: LimitWindow.liveStaleAfter))
                        }
                    }
                }
                // Every provider's limit can be old, not just Claude's. Codex's
                // come from whatever its logs last recorded — measured at 18.5
                // hours on this machine while the card rendered the % as "now".
                // The reading carries its own capture time now, so age it from the
                // limit itself rather than from a Claude-only store field.
                if let hottest = provider.hottestLimit {
                    LimitAgeNote(limit: hottest)
                }
                if provider.provider == "claude" {
                    LiveLimitsStatusNote(capturedAt: store.liveLimitsCapturedAt,
                                         isStale: store.liveLimitsAreStale,
                                         error: store.liveLimitsError,
                                         caveat: store.liveLimitsCaveat,
                                         onRenewLogin: renewAction)
                }
            }
        } else if provider.provider == "claude", let err = store.liveLimitsError {
            // "No live limits reported" blamed Claude for our own failure to
            // fetch. When we know the reason, give it — it's the difference
            // between a dead card and one telling you exactly what to do.
            LiveLimitsStatusNote(capturedAt: nil, isStale: false, error: err,
                                 onRenewLogin: renewAction)
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

    /// The one-click fix, offered only for the failure that actually has one.
    /// Keyed off the typed `Recovery`, never off the message text.
    private var renewAction: (() -> Void)? {
        store.liveLimitsRecovery == .renewLoginInTerminal ? { store.renewClaudeLogin() } : nil
    }

    private func limitLabel(_ raw: String) -> String {
        Format.limitLabel(raw)
    }
}
