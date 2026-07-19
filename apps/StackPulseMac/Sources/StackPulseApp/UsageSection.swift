import SwiftUI

/// Usage: deeper analytics per installed provider — a per-model cost table and
/// the three spend windows with a token-category breakdown and cache-hit rate.
struct UsageSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SectionScaffold(section: .usage) { snapshot in
            VStack(alignment: .leading, spacing: 20) {
                // Nothing detected yet: guide the reader instead of leading with a
                // stack of "not detected" cards and an estimate footnote for zero data.
                if snapshot.installedProviders.isEmpty {
                    NoProvidersDetectedNote()
                }
                ForEach(snapshot.providers) { provider in
                    if provider.installed {
                        UsageProviderBlock(provider: provider)
                    } else {
                        NotDetectedCard(provider: provider)
                    }
                }
                EstimateFootnote()
            }
        }
    }
}

private struct UsageProviderBlock: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            analyticsBlock

            if hasAnyActivity {
                modelTable
                windowsBlock
            } else {
                Label("No recorded activity in the last 30 days.",
                      systemImage: "moon.zzz")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(color: SPStatus.healthColor(provider.health), size: 9)
                .accessibilityLabel(SPStatus.healthLabel(provider.health))
            Text(provider.display_name)
                .font(.title3.weight(.semibold))
            if let version = provider.detected_version {
                Text("v\(version)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let plan = provider.plan_hint {
                Chip(text: plan.capitalized, systemImage: "creditcard", tint: .cyan)
            }
        }
    }

    // MARK: 30-day analytics (savings / burn / cache + daily chart)

    /// Present only for providers the core computed analytics for; detection-only
    /// providers have `analytics == nil` and this collapses to nothing.
    @ViewBuilder private var analyticsBlock: some View {
        if let a = provider.analytics {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    StatTile(
                        label: "Cache saved (30d)",
                        value: Format.usd(a.cache_savings_usd),
                        caption: "measured vs. full input rate",
                        systemImage: "bolt.horizontal.circle",
                        tint: .mint
                    )
                    StatTile(
                        label: "Burn rate",
                        value: Format.usd(a.burn_rate_usd_per_day),
                        caption: "est. $/active-day",
                        systemImage: "flame",
                        tint: .orange
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Daily \(dailyMetricLabel(a)) (last 30 days)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let ratio = a.today_vs_avg_ratio, ratio > 1.5 {
                            Chip(text: "Today \(Format.ratio(ratio)) avg",
                                 systemImage: "exclamationmark.triangle.fill",
                                 tint: .orange)
                        }
                    }
                    DailyBarChart(daily: a.daily)
                }
            }
        }
    }

    private func dailyMetricLabel(_ a: ProviderAnalytics) -> String {
        a.daily.contains { $0.estimated_cost_usd != nil } ? "estimated cost" : "token volume"
    }

    // MARK: Model breakdown table

    @ViewBuilder private var modelTable: some View {
        let models = provider.models.sorted {
            ($0.estimated_cost_usd ?? -1) > ($1.estimated_cost_usd ?? -1)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Models (by estimated cost)")
                .font(.subheadline.weight(.semibold))

            if models.isEmpty {
                Text("No per-model data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("Model")
                        Text("Tokens").gridColumnAlignment(.trailing)
                        Text("Est. cost").gridColumnAlignment(.trailing)
                        Text("Turns").gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal).gridCellColumns(4)

                    ForEach(models) { model in
                        GridRow {
                            Text(model.model)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Format.tokens(model.tokens.grandTotal))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(Format.usd(model.estimated_cost_usd))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(model.estimated_cost_usd == nil ? .tertiary : .primary)
                            Text("\(model.records)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Spend windows

    private var windowsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spend windows")
                .font(.subheadline.weight(.semibold))
            ForEach(provider.orderedWindows) { window in
                SpendWindowRow(window: window)
            }
        }
    }

    private var hasAnyActivity: Bool {
        provider.orderedWindows.contains { $0.tokens.grandTotal > 0 || $0.records > 0 }
            || !provider.models.isEmpty
    }
}

/// One spend window: label, headline cost/tokens/turns, cache-hit rate, and a
/// per-category token breakdown with proportional meters.
private struct SpendWindowRow: View {
    let window: SpendWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(prettyLabel)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(Format.usd(window.estimated_cost_usd))
                    .font(.callout.monospacedDigit().weight(.semibold))
                Text(metaLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if window.records == 0 {
                // Genuinely nothing happened in this window.
                Text("No activity in this window.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if window.tokens.grandTotal == 0 {
                // Activity happened (turns > 0) but this provider accounts tokens
                // server-side — showing "0 tok / No activity" here would both emit
                // a forbidden fake-zero and contradict the "N turns" just above.
                Text("Usage is counted server-side — no local token breakdown.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                categoryBreakdown
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var categoryBreakdown: some View {
        let total = Double(window.tokens.grandTotal)
        return VStack(spacing: 5) {
            ForEach(categories, id: \.label) { category in
                let value = Double(category.value)
                HStack(spacing: 8) {
                    Text(category.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    MeterBar(fraction: total == 0 ? 0 : value / total, tint: category.tint)
                    Text(Format.tokens(category.value))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    private var categories: [(label: String, value: UInt64, tint: Color)] {
        let t = window.tokens
        return [
            ("Input", t.input_tokens, .blue),
            ("Output", t.output_tokens, .green),
            ("Cache read", t.cache_read_tokens, .cyan),
            ("Cache write", t.cache_creation_tokens, .teal),
            ("Reasoning", t.reasoning_tokens, .purple),
        ]
    }

    /// The token/turns meta line. Only shows a token count when there actually is
    /// one — an activity-only provider (turns > 0, tokens 0) must never render the
    /// forbidden "0 tok".
    private var metaLine: String {
        if window.tokens.grandTotal > 0 {
            return "· \(Format.tokens(window.tokens.grandTotal)) tok · \(window.records) turns"
        }
        return "· \(window.records) turns"
    }

    private var prettyLabel: String {
        switch window.label {
        case "today": return "Today"
        case "yesterday": return "Yesterday"
        case "last_30_days": return "Last 30 days"
        default: return SPStatus.healthLabel(window.label)
        }
    }
}
