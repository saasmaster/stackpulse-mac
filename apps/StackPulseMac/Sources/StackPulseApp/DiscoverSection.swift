import SwiftUI
import AppKit

// MARK: - Discover / Repository Radar (main window)
//
// Project-aware, explainable recommendations the core's radar drew from the
// user's own local projects — never a generic feed. Each card answers the
// spec's "must explain" questions: why it's relevant, which projects benefit,
// the evidence, effort, risk, and whether no change is safer. Read-only: it
// surfaces opportunities and a Copy action (paste into a task or an agent), but
// changes nothing on disk.
//
// Data contract: `store.radar` (RadarReport?), `store.rescanRadar()`,
// `store.isScanningRadar`, `store.radarUpdatedAt`, `store.approvedRoots`.

struct DiscoverSection: View {
    @EnvironmentObject var store: SnapshotStore

    private var recs: [Recommendation] { store.radar?.recommendations ?? [] }

    var body: some View {
        SectionScaffold(section: .discover) { _ in
            if store.approvedRoots.isEmpty {
                noRootsState
            } else if let report = store.radar {
                if report.recommendations.isEmpty {
                    allClearState(scanned: report.projects_scanned)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        toolbar(report)
                        categoryStrip
                        ForEach(recs) { rec in
                            RecommendationCard(rec: rec)
                        }
                    }
                }
            } else {
                loadingOrPrompt
            }
        }
        // Guarded like every sibling section: the radar walks all approved roots
        // and shells out to git per project, and this view is an Advisor tab — so
        // an unguarded onAppear re-ran the whole scan every time you switched tabs
        // back to a report that was already on screen.
        .onAppear { if store.radar == nil { store.rescanRadar() } }
    }

    // MARK: Toolbar

    private func toolbar(_ report: RadarReport) -> some View {
        HStack(spacing: 10) {
            Label(
                "\(report.recommendations.count) opportunit\(report.recommendations.count == 1 ? "y" : "ies")",
                systemImage: "sparkles"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            Text("· \(report.projects_scanned) projects scanned")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let updated = store.radarUpdatedAt {
                Text("· \(Format.relative(updated))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button { copyAll() } label: {
                Label("Copy all", systemImage: "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Copy every recommendation as text")

            Button { store.rescanRadar() } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass(tint: .accentColor))
            .disabled(store.isScanningRadar)
            .help("Run the radar again")
        }
    }

    /// A compact tally of opportunities by category.
    private var categoryStrip: some View {
        let counts = Dictionary(grouping: recs, by: { $0.category }).mapValues(\.count)
        let ordered = counts.sorted { $0.value > $1.value }
        return FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(ordered, id: \.key) { key, count in
                Chip(
                    text: "\(RadarStyle.categoryLabel(key)) · \(count)",
                    systemImage: RadarStyle.categoryIcon(key),
                    tint: RadarStyle.categoryTint(key)
                )
            }
        }
    }

    // MARK: States

    private var noRootsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Point the radar at your projects")
                .font(.headline)
            Text("Add project folders (in Projects) and the radar surfaces concrete, explainable improvements it finds in them — nothing generic.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { store.addRoot() } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.glass(tint: .accentColor, prominent: true))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .glassCard(padding: 24)
    }

    private func allClearState(scanned: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Nothing to flag")
                .font(.headline)
            Text("The radar scanned \(scanned) project\(scanned == 1 ? "" : "s") and found no obvious gaps — instructions, tests, ignores, and git state look healthy. No change is the right call here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { store.rescanRadar() } label: {
                Label("Rescan", systemImage: "arrow.clockwise").font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .disabled(store.isScanningRadar)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard(padding: 24)
    }

    private var loadingOrPrompt: some View {
        VStack(spacing: 12) {
            if store.isScanningRadar {
                ProgressView()
                Text("Scanning your projects for opportunities…")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text("Ready when you are")
                    .font(.headline)
                Button { store.rescanRadar() } label: {
                    Label("Run the radar", systemImage: "play.fill").font(.caption.weight(.medium))
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .glassCard(padding: 24)
    }

    // MARK: Actions

    private func copyAll() {
        let text = recs.map(RadarStyle.plainText).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Recommendation card

struct RecommendationCard: View {
    let rec: Recommendation

    @State private var copied = false
    @State private var expanded = false

    private var tint: Color { RadarStyle.categoryTint(rec.category) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            Text(rec.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !rec.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rec.evidence.prefix(4), id: \.self) { line in
                        Label(line, systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(EvidenceLabelStyle())
                            .lineLimit(2)
                    }
                }
            }

            if !rec.affected_projects.isEmpty {
                affectedProjects
            }

            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: tint, padding: 16)
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: RadarStyle.categoryIcon(rec.category))
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RadarStyle.categoryLabel(rec.category))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 6)
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Copy this recommendation (paste into a task or an agent prompt)")
        }
    }

    private var affectedProjects: some View {
        let shown = expanded ? rec.affected_projects : Array(rec.affected_projects.prefix(8))
        let overflow = rec.affected_projects.count - shown.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("AFFECTS \(rec.affected_projects.count) PROJECT\(rec.affected_projects.count == 1 ? "" : "S")")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(shown, id: \.self) { name in
                    Chip(text: name, systemImage: "folder", tint: .secondary)
                }
                if overflow > 0 {
                    Button { expanded = true } label: {
                        Chip(text: "+\(overflow) more", systemImage: "ellipsis", tint: .accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            Chip(text: "Effort: \(rec.effort.capitalized)", systemImage: "gauge.with.needle", tint: .secondary)
            Chip(text: "Risk: \(rec.risk.capitalized)", systemImage: RadarStyle.riskIcon(rec.risk),
                 tint: RadarStyle.riskTint(rec.risk))
            if !rec.recommend_change {
                Chip(text: "Often fine to leave", systemImage: "hand.raised", tint: .secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RadarStyle.plainText(rec), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// Evidence bullet: a tiny leading dot, tightly spaced.
private struct EvidenceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(.tertiary)
            configuration.title
        }
    }
}

// MARK: - Category / risk styling

enum RadarStyle {
    static func categoryLabel(_ c: String) -> String {
        switch c {
        case "ai_context": return "AI Context"
        case "hygiene": return "Repo Hygiene"
        case "testing": return "Testing"
        case "git": return "Git"
        case "setup": return "Setup"
        case "efficiency": return "Efficiency"
        case "tooling": return "Tooling"
        case "security": return "Security"
        default: return c.capitalized
        }
    }

    static func categoryIcon(_ c: String) -> String {
        switch c {
        case "ai_context": return "text.book.closed"
        case "hygiene": return "sparkles"
        case "testing": return "checkmark.seal"
        case "git": return "arrow.triangle.branch"
        case "setup": return "gearshape.2"
        case "efficiency": return "bolt"
        case "tooling": return "wrench.and.screwdriver"
        case "security": return "lock.shield"
        default: return "lightbulb"
        }
    }

    static func categoryTint(_ c: String) -> Color {
        switch c {
        case "ai_context": return .blue
        case "hygiene": return .teal
        case "testing": return .green
        case "git": return .purple
        case "setup": return .orange
        case "efficiency": return .yellow
        case "tooling": return .cyan
        case "security": return .red
        default: return .accentColor
        }
    }

    static func riskIcon(_ r: String) -> String {
        switch r {
        case "none": return "checkmark.circle"
        case "medium": return "exclamationmark.triangle"
        default: return "circle"
        }
    }

    static func riskTint(_ r: String) -> Color {
        switch r {
        case "none": return .green
        case "medium": return .orange
        default: return .secondary
        }
    }

    /// A plain-text rendering of one recommendation, for Copy / Copy-all.
    static func plainText(_ r: Recommendation) -> String {
        var lines = ["• \(r.title) [\(categoryLabel(r.category))]", r.detail]
        if !r.evidence.isEmpty {
            lines.append("Evidence: " + r.evidence.joined(separator: "; "))
        }
        if !r.affected_projects.isEmpty {
            lines.append("Projects: " + r.affected_projects.joined(separator: ", "))
        }
        lines.append("Effort: \(r.effort.capitalized) · Risk: \(r.risk.capitalized)"
            + (r.recommend_change ? "" : " · often fine to leave as-is"))
        return lines.joined(separator: "\n")
    }
}
