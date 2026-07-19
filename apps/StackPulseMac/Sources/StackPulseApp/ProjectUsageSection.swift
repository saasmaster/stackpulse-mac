import SwiftUI

// MARK: - By Project section (main window)
//
// Answers "which projects is my AI spend actually going to?". The Rust core
// attributes each local session record to the working directory that session ran
// in, and returns the roll-up ALREADY SORTED by 30-day cost descending. This view
// deliberately never re-sorts: the ranking the core computed is the ranking the
// user sees, so the list order stays consistent with every other surface.
//
// Data contract (read-only from the store — this view performs no I/O):
//   store.projectUsage ([ProjectUsage]) · store.rescanProjectUsage() ·
//   store.isScanningProjectUsage · store.projectUsageUpdatedAt
//
// Every dollar here is a LOCAL LIST-PRICE ESTIMATE, never a billed amount. The
// section says so in its own copy and repeats it in the shared `EstimateFootnote`
// rather than letting a big "$" number imply an invoice.

// MARK: - Share basis

/// What the share-of-spend bar is proportional to.
///
/// Attribution is cost-based whenever the core produced any cost estimate. The
/// token fallback exists because a provider's records can carry no price data at
/// all — without it every bar would collapse to zero and the ranking would read
/// as "nothing happened". The UI always states which basis is live, so the bar's
/// length is never ambiguous and its color is never the only signal.
private enum ShareBasis {
    case cost
    case tokens

    /// The measured quantity, in words — used inside accessibility labels.
    var noun: String {
        switch self {
        case .cost: return "estimated cost"
        case .tokens: return "token volume"
        }
    }

    /// The visible explanation of what the bars mean.
    var note: String {
        switch self {
        case .cost:
            return "Bars show each project's estimated 30-day cost as a share of the top project's — a local estimate, not an amount billed to you."
        case .tokens:
            return "No cost estimates were available for these records, so bars show each project's 30-day token volume as a share of the top project's."
        }
    }
}

// MARK: - Section arithmetic

/// The whole section's arithmetic, computed once per render from values the store
/// already holds.
///
/// This exists so no row re-derives totals or maxima on its own: a single pass
/// over a small in-memory array replaces what would otherwise be an O(n²) sweep
/// across every card's body. Nothing here touches the filesystem.
private struct ProjectTotals {
    /// `nil` when not a single project carried a cost estimate — rendered as "—"
    /// instead of a misleading `$0.00`.
    let cost30: Double?
    let costToday: Double?
    let tokens30: UInt64
    let records30: UInt64
    let basis: ShareBasis
    /// The leader's value under `basis`; the denominator of every share bar.
    let maxShareValue: Double

    init(_ projects: [ProjectUsage]) {
        var cost = 0.0
        var anyCost = false
        var todayCost = 0.0
        var anyTodayCost = false
        var tokens: UInt64 = 0
        var records: UInt64 = 0
        var maxCost = 0.0
        var maxTokens: UInt64 = 0

        for project in projects {
            if let window = project.last30 {
                if let estimate = window.estimated_cost_usd {
                    cost += estimate
                    anyCost = true
                    maxCost = max(maxCost, estimate)
                }
                tokens += window.tokens.grandTotal
                records += window.records
                maxTokens = max(maxTokens, window.tokens.grandTotal)
            }
            if let estimate = project.today?.estimated_cost_usd {
                todayCost += estimate
                anyTodayCost = true
            }
        }

        cost30 = anyCost ? cost : nil
        costToday = anyTodayCost ? todayCost : nil
        tokens30 = tokens
        records30 = records
        basis = maxCost > 0 ? .cost : .tokens
        maxShareValue = maxCost > 0 ? maxCost : Double(maxTokens)
    }

    /// This project's share of the leader, 0…1. Zero when there is nothing to
    /// scale against, which draws an empty bar rather than a full one.
    func share(_ project: ProjectUsage) -> Double {
        guard maxShareValue > 0 else { return 0 }
        let value: Double
        switch basis {
        case .cost: value = project.last30?.estimated_cost_usd ?? 0
        case .tokens: value = Double(project.last30?.tokens.grandTotal ?? 0)
        }
        return min(1, max(0, value / maxShareValue))
    }
}

/// A provider id resolved to a display name once, at ranking time, so a card
/// never rescans the snapshot to label its chips.
private struct ProviderTag: Identifiable {
    let id: String
    let name: String

    var tint: Color { TrendsPalette.tint(for: id) }
}

/// A project plus its already-computed rank, share, and provider labels.
///
/// Rows carry pre-chewed values for two reasons: the card view does no
/// arithmetic during layout, and `ForEach` gets a genuinely `Identifiable`
/// element (an `enumerated()` tuple is not one).
private struct RankedProject: Identifiable {
    let rank: Int
    let project: ProjectUsage
    let share: Double
    let providers: [ProviderTag]

    var id: String { project.project_path }
}

// MARK: - Section

struct ProjectUsageSection: View {
    @EnvironmentObject var store: SnapshotStore

    /// The list is capped so a Mac with hundreds of project folders still scrolls
    /// smoothly; the tail is one toggle away.
    @State private var showAll = false

    private static let collapsedLimit = 15

    var body: some View {
        SectionScaffold(section: .projectUsage) { snapshot in
            if store.projectUsage.isEmpty {
                if store.isScanningProjectUsage {
                    scanningState
                } else if store.projectUsageScanFailed {
                    failedState
                } else {
                    emptyState
                }
            } else {
                loaded(snapshot)
            }
        }
        // Scanning walks the local session logs, so it only kicks off when there
        // is nothing to show — revisiting the section must not re-trigger it.
        .onAppear {
            if store.projectUsage.isEmpty { store.rescanProjectUsage() }
        }
    }

    // MARK: Loaded content

    private func loaded(_ snapshot: UsageSnapshot) -> some View {
        let totals = ProjectTotals(store.projectUsage)
        let rows = Self.rank(
            store.projectUsage,
            totals: totals,
            limit: showAll ? nil : Self.collapsedLimit,
            snapshot: snapshot
        )

        return VStack(alignment: .leading, spacing: 18) {
            toolbar
            summary(totals)
            basisNote(totals)

            VStack(spacing: 12) {
                ForEach(rows) { row in
                    ProjectSpendCard(row: row, basis: totals.basis)
                }
            }

            if store.projectUsage.count > Self.collapsedLimit {
                showAllToggle
            }

            EstimateFootnote()
        }
    }

    /// Pairs each project with its rank, share, and resolved provider names in a
    /// single pass, preserving the core's cost-descending order.
    private static func rank(
        _ projects: [ProjectUsage],
        totals: ProjectTotals,
        limit: Int?,
        snapshot: UsageSnapshot
    ) -> [RankedProject] {
        var rows: [RankedProject] = []
        let cap = limit ?? projects.count
        for (index, project) in projects.prefix(cap).enumerated() {
            rows.append(
                RankedProject(
                    rank: index + 1,
                    project: project,
                    share: totals.share(project),
                    providers: project.providers.map { id in
                        ProviderTag(id: id, name: Self.displayName(for: id, in: snapshot))
                    }
                )
            )
        }
        return rows
    }

    /// Prefers the live snapshot's own display name for a provider, falling back
    /// to a title-cased id so a provider that only shows up in attribution still
    /// reads nicely. Mirrors the resolution used by Trends and Insights.
    private static func displayName(for provider: String, in snapshot: UsageSnapshot) -> String {
        if let name = snapshot.providers.first(where: { $0.provider == provider })?.display_name {
            return name
        }
        return provider.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(
                "\(store.projectUsage.count) project\(store.projectUsage.count == 1 ? "" : "s")",
                systemImage: "folder.badge.gearshape"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            if let updated = store.projectUsageUpdatedAt {
                Text("· updated \(Format.relative(updated))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if store.isScanningProjectUsage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Scanning local session logs")
            }

            Spacer()

            Button {
                store.rescanProjectUsage()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass(tint: .accentColor))
            .disabled(store.isScanningProjectUsage)
            .help("Re-read your local session logs and re-attribute spend to projects")
        }
    }

    // MARK: Summary

    private func summary(_ totals: ProjectTotals) -> some View {
        HStack(alignment: .top, spacing: 14) {
            StatTile(
                label: "Attributed · 30 days",
                value: Format.usd(totals.cost30),
                caption: "estimated, not billed",
                systemImage: "dollarsign.circle",
                tint: .accentColor
            )
            StatTile(
                label: "Tokens · 30 days",
                value: Format.tokens(totals.tokens30),
                caption: "\(totals.records30) turns",
                systemImage: "number"
            )
            StatTile(
                label: "Today",
                value: Format.usd(totals.costToday),
                caption: "estimated so far",
                systemImage: "sun.max"
            )
        }
        .glassCard(padding: 14)
    }

    private func basisNote(_ totals: ProjectTotals) -> some View {
        Label(totals.basis.note, systemImage: "chart.bar.xaxis")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Show-all toggle

    private var showAllToggle: some View {
        Button {
            showAll.toggle()
        } label: {
            Label(
                showAll
                    ? "Show top \(Self.collapsedLimit) only"
                    : "Show all \(store.projectUsage.count) projects",
                systemImage: showAll ? "chevron.up" : "chevron.down"
            )
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: States

    private var emptyState: some View {
        EmptyStateView(
            icon: "folder.badge.questionmark",
            title: "No project-attributed usage yet",
            message: "StackPulse attributes each local session record to the folder that session ran in. Nothing has been attributed so far — run an AI coding session inside a project, then rescan."
        )
    }

    /// Shown when the scan *failed*, distinct from a genuine empty — otherwise a
    /// read error reads as "you've simply used nothing", a false all-clear.
    private var failedState: some View {
        EmptyStateView(
            icon: "exclamationmark.triangle",
            title: "Couldn't attribute usage",
            message: "The scan couldn't run just now, so this isn't a confirmed “nothing here”. Try rescanning."
        )
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Attributing local session records to projects…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .glassCard(padding: 24)
    }
}

// MARK: - Project card

/// One ranked project. Reads only the pre-computed values on its `RankedProject`,
/// so nothing here scales with the size of the list.
private struct ProjectSpendCard: View {
    let row: RankedProject
    let basis: ShareBasis

    @EnvironmentObject private var store: SnapshotStore

    private var project: ProjectUsage { row.project }

    /// True when this "project" is actually one of the watched parent folders —
    /// i.e. sessions were started in the umbrella directory rather than inside a
    /// specific repo. Attribution is honest (that *is* the recorded working
    /// directory), but without saying so the entry reads as "one project ate the
    /// whole budget", which would be misleading.
    private var isUmbrella: Bool { store.approvedRoots.contains(project.project_path) }

    /// Card accent: the project's first (core-ordered) provider. Always paired
    /// with the named provider chips below, so the color carries no meaning on
    /// its own.
    private var tint: Color { row.providers.first?.tint ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isUmbrella { umbrellaNote }
            shareBar
            metrics
            if !row.providers.isEmpty { providerChips }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: tint, padding: 14)
    }

    /// Explains an umbrella-folder entry rather than letting it masquerade as a
    /// single project.
    private var umbrellaNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "folder.badge.questionmark")
                .imageScale(.small)
                .foregroundStyle(.orange)
            Text("This is a watched parent folder, not one project — it counts every session started here instead of inside a specific repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Parent folder, not a single project: counts sessions started in the folder itself.")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("#\(row.rank)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Rank \(row.rank)")

            VStack(alignment: .leading, spacing: 3) {
                Text(project.project_name)
                    .font(.headline)
                    .lineLimit(1)

                Text(project.project_path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityLabel("Path \(project.project_path)")
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.usd(project.last30?.estimated_cost_usd))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text("est. · 30 days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Estimated 30-day cost \(Format.usd(project.last30?.estimated_cost_usd))"
            )
        }
    }

    // MARK: Share bar

    /// The bar that makes the ranking legible at a glance: this project's 30-day
    /// spend against the highest project's. The percentage is always spelled out
    /// next to it — the bar length is a shortcut, not the only way to read it.
    private var shareBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            MeterBar(fraction: row.share, tint: tint, height: 6)

            Text("\(Format.percent(row.share * 100)) of the top project's 30-day \(basis.noun)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Share of the top project's 30-day \(basis.noun)")
        .accessibilityValue(Format.percent(row.share * 100))
    }

    // MARK: Metrics

    private var metrics: some View {
        FlowLayout(spacing: 16, lineSpacing: 8) {
            metric("Today", value: Format.usd(project.today?.estimated_cost_usd), caption: activity(project.today))
            metric("30 days", value: Format.usd(project.last30?.estimated_cost_usd), caption: activity(project.last30))
            metric("Turns", value: "\(project.last30?.records ?? 0)", caption: "records · 30 days")
            metric("Last active", value: Format.relative(project.lastActivityAt), caption: nil)
        }
    }

    private func metric(_ label: String, value: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(caption.map { ", \($0)" } ?? "")")
    }

    /// Token + turn detail for a window, or an explicit "no activity" so a blank
    /// caption never reads as missing data.
    private func activity(_ window: SpendWindow?) -> String {
        guard let window, window.tokens.grandTotal > 0 || window.records > 0 else {
            return "no activity"
        }
        return "\(Format.tokens(window.tokens.grandTotal)) tok · \(window.records) turns"
    }

    // MARK: Providers

    private var providerChips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(row.providers) { tag in
                Chip(text: tag.name, systemImage: "sparkle", tint: tag.tint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Providers used: \(row.providers.map(\.name).joined(separator: ", "))"
        )
    }
}
