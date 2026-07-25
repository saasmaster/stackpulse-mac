import SwiftUI

// MARK: - Insights section (main window)
//
// Ranked, actionable insights derived from the user's local usage — ways to save
// money and work more efficiently. Mirrors the AlertsSection look: grouped glass
// cards with a leading glyph, a bold title, a wrapping detail, and a footer row
// of chips (provider · kind · metric · relative time). Purely a read-only,
// suggestions surface — nothing here mutates state.

// MARK: - Impact (icon + color are always paired with a text label)

/// Interpreted impact of an ``Insight``. The wire value is a `String` so a newer
/// core can add levels without breaking decoding; anything unknown maps to `.low`.
/// `Comparable` by weight so a set can be grouped/sorted High → Medium → Low, and
/// `max()` finds the most impactful. Color is never the sole signal — every call
/// site pairs it with the `icon` and the `label` (and the group header it lives
/// under).
private enum InsightImpact: Int, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    init(_ raw: String) {
        switch raw {
        case "high": self = .high
        case "medium": self = .medium
        default: self = .low
        }
    }

    static func < (lhs: InsightImpact, rhs: InsightImpact) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Semantic tint — always accompanied by the icon and a text label, never the
    /// sole signal. High reads warm/urgent, medium amber, low stays quiet.
    var color: Color {
        switch self {
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .high: return "chevron.up.circle.fill"
        case .medium: return "equal.circle.fill"
        case .low: return "chevron.down.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .high: return "High impact"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

private extension Insight {
    /// Interpreted impact (icon / color / label / ordering live on ``InsightImpact``).
    var impactKind: InsightImpact { InsightImpact(impact) }
}

// MARK: - Kind → glyph + human label

/// Maps a machine `kind` to a small SF Symbol and a human label. The wire value
/// is a `String` so a newer core can add kinds without breaking decoding; unknown
/// kinds fall back to a neutral lightbulb and a title-cased version of the raw id.
private enum InsightKind {
    static func icon(_ kind: String) -> String {
        switch kind {
        case "low_cache_efficiency": return "square.stack.3d.up"
        case "spend_anomaly": return "chart.line.uptrend.xyaxis"
        case "approaching_limit": return "gauge.high"
        case "idle_provider": return "moon.zzz"
        case "cost_concentration": return "dollarsign.circle"
        case "stalled_session": return "pause.circle"
        default: return "lightbulb"
        }
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case "low_cache_efficiency": return "Cache efficiency"
        case "spend_anomaly": return "Spend spike"
        case "approaching_limit": return "Approaching limit"
        case "idle_provider": return "Idle"
        case "cost_concentration": return "Cost concentration"
        case "stalled_session": return "Possibly stalled"
        default: return SPStatus.healthLabel(kind)   // title-cases the raw value
        }
    }
}

// MARK: - Section

struct InsightsSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SectionScaffold(section: .insights) { snapshot in
            let insights = store.insights
            if insights.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    summaryBar(insights)
                    reassurance
                    ForEach(groups(insights), id: \.0) { impact, items in
                        groupBlock(impact, items, snapshot: snapshot)
                    }
                }
            }
        }
    }

    // MARK: Intro

    /// A count line plus a one-tap-nothing reassurance, so the surface reads as
    /// helpful suggestions rather than actions that already happened.
    private func summaryBar(_ insights: [Insight]) -> some View {
        let high = insights.filter { $0.impactKind == .high }.count
        return HStack(spacing: 10) {
            Label(
                "\(insights.count) insight\(insights.count == 1 ? "" : "s")",
                systemImage: "lightbulb.max"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            if high > 0 {
                Chip(text: "\(high) high impact",
                     systemImage: InsightImpact.high.icon, tint: .orange)
            }
            Spacer()
        }
    }

    private var reassurance: some View {
        Label(
            "These are suggestions derived from your own local usage — nothing changes automatically.",
            systemImage: "info.circle"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Impact groups

    private func groups(_ all: [Insight]) -> [(InsightImpact, [Insight])] {
        // High → Medium → Low; within each, the core's most-useful-first order is
        // preserved (filter is stable).
        [InsightImpact.high, .medium, .low].compactMap { impact in
            let items = all.filter { $0.impactKind == impact }
            return items.isEmpty ? nil : (impact, items)
        }
    }

    private func groupBlock(_ impact: InsightImpact, _ items: [Insight], snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: impact.icon)
                    .foregroundStyle(impact.color)
                Text(impact.label)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { insight in
                InsightCard(
                    insight: insight,
                    providerName: resolvedProviderName(for: insight.provider, in: snapshot)
                )
            }
        }
    }

    /// Prefers the live snapshot's own display name for a provider, falling back to
    /// a friendly inline map, then a title-cased id. `nil` when the insight isn't
    /// scoped to a provider (a global observation).
    private func resolvedProviderName(for id: String?, in snapshot: UsageSnapshot) -> String? {
        guard let id, !id.isEmpty else { return nil }
        if let name = snapshot.providers.first(where: { $0.provider == id })?.display_name {
            return name
        }
        return Self.prettyProviderName(id)
    }

    /// Friendly names for known provider ids (kept inline so the section is
    /// self-contained), title-cased otherwise.
    private static func prettyProviderName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case "antigravity": return "Antigravity"
        case "devin": return "Devin"
        case "grok": return "Grok"
        case "minimax": return "MiniMax"
        case "open_code": return "OpenCode"
        case "open_router": return "OpenRouter"
        case "zai": return "Z.ai"
        case "gemini": return "Gemini"
        default:
            return id.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lightbulb.max")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("No insights yet")
                .font(.headline)
            Text("StackPulse surfaces efficiency and cost tips here as it learns your usage — nothing needs your attention right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .glassCard(padding: 24)
    }
}

// MARK: - Insight card

/// A full insight card: a leading kind glyph (tinted by impact), the bold title, a
/// wrapping detail, and a footer of chips — provider, kind, the highlighted metric
/// when present, and a relative timestamp. Tinted by the impact color; impact is
/// also carried by the group header and the accessibility label, so color is never
/// the sole signal.
struct InsightCard: View {
    let insight: Insight
    /// Resolved display name, or `nil` for a global (provider-less) insight.
    let providerName: String?

    private var impact: InsightImpact { insight.impactKind }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: InsightKind.icon(insight.kind))
                .font(.title3)
                .foregroundStyle(impact.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(insight.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                footer
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: impact.color, padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let providerName {
                Chip(text: providerName, systemImage: "cpu", tint: .secondary)
            }
            Chip(text: InsightKind.label(insight.kind), tint: impact.color)
            if let metric = insight.metric, !metric.isEmpty {
                Chip(text: metric, systemImage: "sparkles", tint: impact.color)
            }
            Label(Format.relative(insight.createdAt), systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 0)
        }
    }

    /// One combined label so VoiceOver reads impact + kind + provider + title +
    /// detail (+ metric) as a single element, never color-only.
    private var accessibilityText: String {
        var parts = ["\(impact.label), \(InsightKind.label(insight.kind))"]
        if let providerName { parts.append(providerName) }
        parts.append(insight.title)
        parts.append(insight.detail)
        if let metric = insight.metric, !metric.isEmpty {
            parts.append(metric)
        }
        return parts.joined(separator: ". ")
    }
}
