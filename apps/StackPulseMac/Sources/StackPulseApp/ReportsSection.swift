import SwiftUI

// MARK: - Reports section (main window)
//
// A composed, shareable snapshot of the user's usage / efficiency / active work /
// stack — built entirely from data already in the store, then exportable. Nothing
// here touches the network: the report text is handed to the clipboard or to a
// file the user picks in a Save panel (see ``Exporter``). Costs are the same local
// list-price estimates used everywhere else, never a billed amount.
//
// On screen it renders as a stack of Liquid-Glass cards (meta + toolbar, spend,
// efficiency, insights, active work, stack). The same six sections are mirrored by
// `markdownReport(_:)`, which is what "Copy summary" and "Export Markdown" emit.

struct ReportsSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SectionScaffold(section: .reports) { snapshot in
            let model = ReportModel(
                snapshot: snapshot,
                missions: store.missions,
                insights: store.insights,
                stacks: store.stackHealth,
                generatedAt: Date(timeIntervalSince1970: TimeInterval(snapshot.generated_at_unix))
            )

            VStack(alignment: .leading, spacing: 18) {
                metaCard(model, snapshot: snapshot)
                spendCard(model)
                efficiencyCard(model)
                insightsCard(model)
                activeWorkCard(model)
                stackCard(model)
                EstimateFootnote()
            }
        }
    }

    // MARK: 1 · Header / meta + export toolbar

    private func metaCard(_ model: ReportModel, snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage Report")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text("as of \(Format.relative(model.generatedAt)) · UTC \(snapshot.bucket_date_utc)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Button {
                    Exporter.copyToClipboard(markdownReport(model))
                } label: {
                    Label("Copy summary", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))

                Button {
                    Exporter.save(text: markdownReport(model),
                                  suggestedName: "stackpulse-report.md")
                } label: {
                    Label("Export Markdown", systemImage: "text.alignleft")
                }
                .buttonStyle(.glass)

                Button {
                    Exporter.save(text: Exporter.snapshotCSV(snapshot),
                                  suggestedName: "stackpulse-report.csv")
                } label: {
                    Label("Export CSV", systemImage: "tablecells")
                }
                .buttonStyle(.glass)

                Button {
                    Exporter.save(text: Exporter.snapshotJSON(snapshot),
                                  suggestedName: "stackpulse-report.json")
                } label: {
                    Label("Export JSON", systemImage: "curlybraces")
                }
                .buttonStyle(.glass)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    // MARK: 2 · Spend & volume

    private func spendCard(_ model: ReportModel) -> some View {
        ReportCard(title: "Spend & volume", systemImage: "dollarsign.circle") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                reportTile("Today", Format.usd(model.todayCost),
                           caption: "\(Format.tokens(model.todayTokens)) tokens",
                           systemImage: "sun.max", tint: .orange)
                reportTile("30-day est.", Format.usd(model.last30Cost),
                           caption: "\(Format.tokens(model.last30Tokens)) tokens",
                           systemImage: "calendar", tint: .mint)
                reportTile("Providers", "\(model.providersWithUsage.count)",
                           caption: "with usage data",
                           systemImage: "cpu", tint: .blue)
            }

            if model.providersWithUsage.isEmpty {
                inlineEmpty("No usage recorded yet — run an AI tool and refresh.")
            } else {
                VStack(spacing: 0) {
                    spendHeaderRow
                    ForEach(model.providersWithUsage) { p in
                        spendRow(p)
                    }
                }
                .padding(.top, 2)
            }

            Text("Estimates from a local price table (\(model.pricingNote)).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var spendHeaderRow: some View {
        HStack {
            Text("PROVIDER").frame(maxWidth: .infinity, alignment: .leading)
            Text("TODAY").frame(width: 110, alignment: .trailing)
            Text("30 DAYS").frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
        .accessibilityHidden(true)
    }

    private func spendRow(_ p: ProviderUsage) -> some View {
        let todayTok = p.today?.tokens.grandTotal ?? 0
        let last30Tok = p.last30?.tokens.grandTotal ?? 0
        return HStack {
            Text(p.display_name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(Format.usd(p.today?.estimated_cost_usd)) · \(Format.tokens(todayTok))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text("\(Format.usd(p.last30?.estimated_cost_usd)) · \(Format.tokens(last30Tok))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(p.display_name): today \(Format.usd(p.today?.estimated_cost_usd)), "
            + "\(Format.tokens(todayTok)) tokens; 30 days \(Format.usd(p.last30?.estimated_cost_usd)), "
            + "\(Format.tokens(last30Tok)) tokens."
        )
    }

    // MARK: 3 · Efficiency

    private func efficiencyCard(_ model: ReportModel) -> some View {
        ReportCard(title: "Efficiency", systemImage: "square.stack.3d.up") {
            if model.efficiencyRows.isEmpty {
                inlineEmpty("No cache analytics yet — these appear once a provider has local session history.")
            } else {
                if let savings = model.totalCacheSavings {
                    reportTile("Measured cache savings", Format.usd(savings),
                               caption: "vs. paying full input rate (30d)",
                               systemImage: "arrow.down.circle", tint: .green)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                VStack(spacing: 8) {
                    ForEach(model.efficiencyRows) { row in
                        efficiencyRow(row)
                    }
                }
            }
        }
    }

    private func efficiencyRow(_ row: ReportModel.EffRow) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: .green, size: 8)
            Text(row.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            if let hit = row.cacheHitRate {
                Chip(text: "\(Format.percent(hit * 100)) cache hit",
                     systemImage: "square.stack.3d.up", tint: .green)
            }
            if let savings = row.cacheSavings {
                Chip(text: "\(Format.usd(savings)) saved", systemImage: "arrow.down", tint: .mint)
            }
            Spacer(minLength: 0)
            if let burn = row.burnPerDay {
                Text("\(Format.usd(burn))/day")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }

    // MARK: 4 · Insights

    private func insightsCard(_ model: ReportModel) -> some View {
        ReportCard(title: "Insights", systemImage: "lightbulb.max") {
            if model.topInsights.isEmpty {
                inlineEmpty("No insights right now.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.topInsights) { insight in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .foregroundStyle(.yellow)
                                .imageScale(.small)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.title)
                                    .font(.callout.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let metric = insight.metric, !metric.isEmpty {
                                    Text(metric)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: 5 · Active work

    private func activeWorkCard(_ model: ReportModel) -> some View {
        ReportCard(title: "Active work", systemImage: "bolt.fill") {
            if model.recentMissions.isEmpty {
                inlineEmpty("No active sessions.")
            } else {
                HStack(spacing: 8) {
                    Chip(text: "\(model.activeMissionCount) active",
                         systemImage: "bolt.fill", tint: .green)
                    Chip(text: "\(model.recentMissions.count) recent",
                         systemImage: "clock.arrow.circlepath", tint: .secondary)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.recentMissions) { mission in
                        HStack(spacing: 8) {
                            Image(systemName: mission.statusKind.icon)
                                .foregroundStyle(mission.statusKind.color)
                                .imageScale(.small)
                            Text("\(mission.providerDisplay) · \(mission.projectLabel)")
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(mission.statusKind.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(mission.statusKind.color)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(mission.providerDisplay), \(mission.projectLabel), \(mission.statusKind.label)."
                        )
                    }
                }
            }
        }
    }

    // MARK: 6 · Stack

    private func stackCard(_ model: ReportModel) -> some View {
        ReportCard(title: "Stack", systemImage: "shippingbox") {
            if model.stacks.isEmpty {
                inlineEmpty("Add project folders in Settings to include stack health.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.stacks) { stack in
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                            Text(stackLine(stack))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: - Small shared pieces

    private func reportTile(_ label: String, _ value: String, caption: String,
                            systemImage: String, tint: Color) -> some View {
        StatTile(label: label, value: value, caption: caption,
                 systemImage: systemImage, tint: tint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label): \(value), \(caption).")
    }

    private func inlineEmpty(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A one-line stack summary, e.g. "stackpulse — 42 deps, 3 major-behind, 1 advisory".
    private func stackLine(_ stack: ProjectStack) -> String {
        let s = stack.summary
        var parts = ["\(s.total) dep\(s.total == 1 ? "" : "s")"]
        if s.major_behind > 0 { parts.append("\(s.major_behind) major-behind") }
        if s.minor_behind > 0 { parts.append("\(s.minor_behind) minor-behind") }
        if s.vulnerable > 0 { parts.append("\(s.vulnerable) \(s.vulnerable == 1 ? "advisory" : "advisories")") }
        if s.deprecated > 0 { parts.append("\(s.deprecated) deprecated") }
        return "\(stack.name) — \(parts.joined(separator: ", "))"
    }

    // MARK: - Markdown composition (Copy summary / Export Markdown)

    /// Composes the full report as Markdown, mirroring the on-screen sections. This
    /// is the string emitted by "Copy summary" and "Export Markdown". Kept plain
    /// (no HTML) so it pastes cleanly into a note, issue, or message.
    private func markdownReport(_ model: ReportModel) -> String {
        var out: [String] = []
        out.append("# StackPulse Usage Report")
        out.append("_As of \(Format.relative(model.generatedAt)) · UTC \(model.bucketDate)_")
        out.append("")

        // Spend & volume
        out.append("## Spend & volume")
        out.append("- **Today:** \(Format.usd(model.todayCost)) · \(Format.tokens(model.todayTokens)) tokens")
        out.append("- **Last 30 days:** \(Format.usd(model.last30Cost)) · \(Format.tokens(model.last30Tokens)) tokens")
        if model.providersWithUsage.isEmpty {
            out.append("- _No usage recorded yet._")
        } else {
            out.append("")
            out.append("| Provider | Today | 30 days |")
            out.append("| --- | --- | --- |")
            for p in model.providersWithUsage {
                let today = "\(Format.usd(p.today?.estimated_cost_usd)) · \(Format.tokens(p.today?.tokens.grandTotal ?? 0))"
                let last30 = "\(Format.usd(p.last30?.estimated_cost_usd)) · \(Format.tokens(p.last30?.tokens.grandTotal ?? 0))"
                out.append("| \(p.display_name) | \(today) | \(last30) |")
            }
        }
        out.append("")

        // Efficiency
        out.append("## Efficiency")
        if model.efficiencyRows.isEmpty {
            out.append("- _No cache analytics yet._")
        } else {
            if let savings = model.totalCacheSavings {
                out.append("- **Measured cache savings (30d):** \(Format.usd(savings))")
            }
            for row in model.efficiencyRows {
                var bits: [String] = []
                if let hit = row.cacheHitRate { bits.append("\(Format.percent(hit * 100)) cache hit-rate") }
                if let savings = row.cacheSavings { bits.append("\(Format.usd(savings)) saved") }
                if let burn = row.burnPerDay { bits.append("\(Format.usd(burn))/day burn") }
                out.append("- **\(row.name):** \(bits.isEmpty ? "—" : bits.joined(separator: " · "))")
            }
        }
        out.append("")

        // Insights
        out.append("## Insights")
        if model.topInsights.isEmpty {
            out.append("- _No insights right now._")
        } else {
            for insight in model.topInsights {
                if let metric = insight.metric, !metric.isEmpty {
                    out.append("- **\(insight.title)** — \(metric)")
                } else {
                    out.append("- **\(insight.title)**")
                }
            }
        }
        out.append("")

        // Active work
        out.append("## Active work")
        if model.recentMissions.isEmpty {
            out.append("- _No active sessions._")
        } else {
            out.append("- \(model.activeMissionCount) active · \(model.recentMissions.count) recent")
            for mission in model.recentMissions {
                out.append("- \(mission.providerDisplay) · \(mission.projectLabel) · \(mission.statusKind.label)")
            }
        }
        out.append("")

        // Stack
        out.append("## Stack")
        if model.stacks.isEmpty {
            out.append("- _Add project folders in Settings to include stack health._")
        } else {
            for stack in model.stacks {
                out.append("- \(stackLine(stack))")
            }
        }
        out.append("")

        // Footer
        out.append("---")
        out.append("_Generated locally by StackPulse — nothing here is uploaded. Costs are list-price estimates from a local price table (\(model.pricingNote)), not amounts billed to you (subscriptions bill a flat fee)._")

        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Report card shell

/// A titled Liquid-Glass card with a leading glyph header — the consistent
/// container for every report section, keeping them scannable and uniform.
private struct ReportCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }
}

// MARK: - Report model (pure, view-layer aggregation)

/// A pure roll-up of everything the report shows, built once from the live
/// snapshot plus the store's missions / insights / stack health. Holds no SwiftUI
/// state, so both the on-screen cards and `markdownReport(_:)` compose from the
/// same numbers. Costs are the local list-price estimates used elsewhere.
private struct ReportModel {
    let bucketDate: String
    let generatedAt: Date
    let pricingNote: String

    let providersWithUsage: [ProviderUsage]
    let todayTokens: UInt64
    let todayCost: Double?
    let last30Tokens: UInt64
    let last30Cost: Double?

    let efficiencyRows: [EffRow]
    let totalCacheSavings: Double?

    let topInsights: [Insight]
    let recentMissions: [Mission]
    let activeMissionCount: Int
    let stacks: [ProjectStack]

    /// One provider's efficiency line: cache hit-rate, measured savings, and burn.
    struct EffRow: Identifiable {
        let id: String
        let name: String
        let cacheHitRate: Double?
        let cacheSavings: Double?
        let burnPerDay: Double?

        var accessibilityLabel: String {
            var parts = [name]
            if let hit = cacheHitRate { parts.append("\(Format.percent(hit * 100)) cache hit-rate") }
            if let savings = cacheSavings { parts.append("\(Format.usd(savings)) saved") }
            if let burn = burnPerDay { parts.append("\(Format.usd(burn)) per day") }
            return parts.joined(separator: ", ") + "."
        }
    }

    init(snapshot: UsageSnapshot, missions: [Mission], insights: [Insight],
         stacks: [ProjectStack], generatedAt: Date) {
        self.bucketDate = snapshot.bucket_date_utc
        self.generatedAt = generatedAt
        self.pricingNote = snapshot.pricing_note

        let withUsage = snapshot.providers.filter { $0.hasUsageData }
        self.providersWithUsage = withUsage

        self.todayTokens = withUsage.reduce(UInt64(0)) { $0 + ($1.today?.tokens.grandTotal ?? 0) }
        self.last30Tokens = withUsage.reduce(UInt64(0)) { $0 + ($1.last30?.tokens.grandTotal ?? 0) }
        self.todayCost = ReportModel.sumCost(withUsage.map { $0.today?.estimated_cost_usd })
        self.last30Cost = ReportModel.sumCost(withUsage.map { $0.last30?.estimated_cost_usd })

        let rows: [EffRow] = snapshot.providers.compactMap { p in
            guard let a = p.analytics else { return nil }
            // Skip a provider whose analytics carry nothing meaningful to show.
            if a.cache_hit_rate == nil && a.cache_savings_usd == nil && a.burn_rate_usd_per_day == nil {
                return nil
            }
            return EffRow(
                id: p.provider,
                name: p.display_name,
                cacheHitRate: a.cache_hit_rate,
                cacheSavings: a.cache_savings_usd,
                burnPerDay: a.burn_rate_usd_per_day
            )
        }
        self.efficiencyRows = rows
        self.totalCacheSavings = ReportModel.sumCost(rows.map { $0.cacheSavings })

        // Top few insights (already most-useful-first) keep the report scannable.
        self.topInsights = Array(insights.prefix(5))

        // Observed sessions (most-recently-active first); show a handful.
        self.recentMissions = Array(missions.prefix(6))
        self.activeMissionCount = missions.filter { $0.statusKind == .active }.count

        self.stacks = stacks
    }

    /// Sums the present costs; `nil` when none of the windows carried one, so the
    /// UI shows an em dash rather than a misleading $0.00.
    private static func sumCost(_ costs: [Double?]) -> Double? {
        let present = costs.compactMap { $0 }
        return present.isEmpty ? nil : present.reduce(0, +)
    }
}
