import SwiftUI

// MARK: - Stack Health section (main window)
//
// Renders the per-project dependency health of every approved folder. The Rust
// core supplies an OFFLINE inventory (installed versions only); this view folds
// in the network enrichment from `StackHealthClient` — latest versions + OSV
// advisories — and computes an outdated/vulnerable picture.
//
// Data contract (all read-only from the store):
//   store.stackHealth ([ProjectStack]) · store.rescanStackHealth() ·
//   store.isScanningStack · store.stackUpdatedAt · store.stackCheckUpdates ·
//   store.approvedRoots
//
// Network enrichment is gated on `store.stackCheckUpdates`: when off, the section
// shows the offline inventory only and says so (nothing leaves the machine).

// MARK: - Interpreted status (icon + color are always paired with a text label)

/// Interpreted dependency status. The wire value is a `String` so a newer core can
/// add states without breaking decoding; anything unknown maps to `.unknown`.
/// Color is never the sole signal — every call site pairs it with the icon and a
/// text label (chip / accessibility string).
private enum DepStatus {
    case upToDate
    case minorBehind
    case majorBehind
    case deprecated
    case unknown

    init(_ raw: String) {
        switch raw {
        case "up_to_date": self = .upToDate
        case "minor_behind": self = .minorBehind
        case "major_behind": self = .majorBehind
        case "deprecated": self = .deprecated
        default: self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .upToDate: return .green
        case .minorBehind: return .yellow
        case .majorBehind: return .orange
        case .deprecated: return .red
        case .unknown: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .upToDate: return "checkmark.circle.fill"
        case .minorBehind: return "arrow.up.circle"
        case .majorBehind: return "arrow.up.circle.fill"
        case .deprecated: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .upToDate: return "Up to date"
        case .minorBehind: return "Minor behind"
        case .majorBehind: return "Major behind"
        case .deprecated: return "Deprecated"
        case .unknown: return "Unknown"
        }
    }
}

/// Interpreted advisory severity. `Comparable` by weight so `.max()` surfaces the
/// worst level for a project accent. Unknown-severity advisories still read as a
/// vulnerability (red), never as "no problem".
private enum AdvisoryLevel: Int, Comparable {
    case unknown = 0
    case low = 1
    case moderate = 2
    case high = 3
    case critical = 4

    init(_ raw: String) {
        switch raw.lowercased() {
        case "low": self = .low
        case "moderate", "medium": self = .moderate
        case "high": self = .high
        case "critical": self = .critical
        default: self = .unknown
        }
    }

    static func < (lhs: AdvisoryLevel, rhs: AdvisoryLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: Color {
        switch self {
        case .critical, .high, .unknown: return .red
        case .moderate: return .orange
        case .low: return .yellow
        }
    }
}

// MARK: - Resolved (per-dependency view model, enrichment ∪ core)

/// One dependency reduced to what a row needs, preferring live enrichment and
/// falling back to the core's offline fields when enrichment isn't ready.
private struct Resolved: Identifiable {
    let dep: Dependency
    let latest: String?
    let statusRaw: String
    let advisoryCount: Int
    let worstAdvisory: AdvisoryLevel?

    var id: String { dep.id }
    var status: DepStatus { DepStatus(statusRaw) }

    /// Sort key: advisories first, then most-behind, then unknown, then up-to-date.
    var actionRank: Int {
        if advisoryCount > 0 { return 0 }
        switch status {
        case .majorBehind, .deprecated: return 1
        case .minorBehind: return 2
        case .unknown: return 3
        case .upToDate: return 4
        }
    }
}

// MARK: - Section

struct StackHealthSection: View {
    @EnvironmentObject var store: SnapshotStore

    /// Network enrichment keyed by `Dependency.id`, filled off the main actor.
    @State private var enrichment: [String: StackHealthClient.DependencyEnrichment] = [:]
    @State private var enriching = false
    /// Projects whose "up to date" rows are expanded.
    @State private var expandedProjects: Set<String> = []

    var body: some View {
        SectionScaffold(section: .stackHealth) { _ in
            if store.approvedRoots.isEmpty {
                emptyRoots
            } else if store.stackHealth.isEmpty {
                loadingOrEmpty
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    toolbar
                    if !store.stackCheckUpdates { updateCheckOffNote }
                    ForEach(store.stackHealth) { proj in
                        projectBlock(proj)
                    }
                }
            }
        }
        .onAppear {
            if store.stackHealth.isEmpty, !store.approvedRoots.isEmpty { store.rescanStackHealth() }
            runEnrichment()
        }
        // A fresh scan invalidates enrichment — clear and re-fetch.
        .onChange(of: store.stackUpdatedAt) { _, _ in
            enrichment = [:]
            runEnrichment()
        }
        // Toggling update-checking on kicks a fetch; off clears any live data.
        .onChange(of: store.stackCheckUpdates) { _, isOn in
            if isOn { runEnrichment() } else { enrichment = [:] }
        }
    }

    // MARK: Enrichment

    /// Fetches latest versions + advisories for every dependency and folds the
    /// result into `@State`. Gated on the update-check toggle; a no-op while a
    /// fetch is already in flight or there's nothing to check. `enrich(...)` runs
    /// off the main actor (its statics are nonisolated), so the `await` suspends
    /// this main-actor `Task` off-main and resumes here to publish the result.
    private func runEnrichment() {
        guard store.stackCheckUpdates, !enriching else { return }
        let deps = store.stackHealth.flatMap(\.dependencies)
        guard !deps.isEmpty else { return }
        enriching = true
        Task {
            let result = await StackHealthClient.enrich(deps)
            self.enrichment = result
            self.enriching = false
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $store.stackCheckUpdates) {
                Text("Check for updates")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .help("Query public registries (npm, crates.io, OSV) for latest versions and security advisories.")

            if enriching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("as of \(Format.relative(store.stackUpdatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                store.rescanStackHealth()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass(tint: .accentColor))
            .disabled(store.isScanningStack)
        }
    }

    private var updateCheckOffNote: some View {
        Label(
            "Update checking is off — showing installed versions only. Turn it on to see latest versions and security advisories (StackPulse then queries public registries; nothing else leaves your Mac).",
            systemImage: "wifi.slash"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Per-project block

    private func projectBlock(_ proj: ProjectStack) -> some View {
        let resolved = proj.dependencies.map(resolve)
        let sorted = resolved.sorted { $0.actionRank < $1.actionRank }
        let notUpToDate = sorted.filter { $0.status != .upToDate }
        let upToDate = sorted.filter { $0.status == .upToDate }
        let accent = accentColor(resolved)
        let expanded = expandedProjects.contains(proj.id)

        return VStack(alignment: .leading, spacing: 10) {
            projectHeader(proj, resolved: resolved, accent: accent)

            if proj.dependencies.isEmpty {
                Text("No dependencies found in this project's manifests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(notUpToDate) { r in
                        DepRow(resolved: r, checking: store.stackCheckUpdates)
                    }
                    if !upToDate.isEmpty {
                        if expanded {
                            ForEach(upToDate) { r in
                                DepRow(resolved: r, checking: store.stackCheckUpdates)
                            }
                        }
                        Button {
                            toggleExpanded(proj.id)
                        } label: {
                            Label(
                                expanded
                                    ? "Hide \(upToDate.count) up to date"
                                    : "+\(upToDate.count) up to date",
                                systemImage: expanded ? "chevron.up" : "chevron.down"
                            )
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: accent, padding: 14)
    }

    private func projectHeader(_ proj: ProjectStack, resolved: [Resolved], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(accent)
                Text(proj.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Chip(text: proj.ecosystem, tint: .secondary)
                if let pm = proj.package_manager, !pm.isEmpty {
                    Chip(text: pm, systemImage: "shippingbox", tint: .secondary)
                }
                Spacer(minLength: 0)
            }
            Text(summaryLine(resolved))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(proj.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Derivations

    /// Prefers live enrichment; falls back to the core's offline fields while a
    /// fetch is pending; shows inventory-only when update-checking is off.
    private func resolve(_ dep: Dependency) -> Resolved {
        if store.stackCheckUpdates, let e = enrichment[dep.id] {
            let worst = e.advisories.map { AdvisoryLevel($0.severity) }.max()
            return Resolved(
                dep: dep, latest: e.latest, statusRaw: e.status,
                advisoryCount: e.advisories.count, worstAdvisory: worst
            )
        }
        if store.stackCheckUpdates {
            // Enrichment not ready yet → the core's own (possibly "unknown") data.
            let worst = dep.advisories.map { AdvisoryLevel($0.severity) }.max()
            return Resolved(
                dep: dep, latest: dep.latest, statusRaw: dep.status,
                advisoryCount: dep.advisories.count, worstAdvisory: worst
            )
        }
        // Update-checking off → installed inventory only.
        return Resolved(
            dep: dep, latest: nil, statusRaw: "inventory",
            advisoryCount: 0, worstAdvisory: nil
        )
    }

    /// The header summary line, built from enriched data when checking, or a plain
    /// count when update-checking is off.
    private func summaryLine(_ resolved: [Resolved]) -> String {
        let total = resolved.count
        let depWord = total == 1 ? "dep" : "deps"
        guard store.stackCheckUpdates else {
            return "\(total) \(depWord) · update checking off"
        }
        let major = resolved.filter { $0.status == .majorBehind || $0.status == .deprecated }.count
        let minor = resolved.filter { $0.status == .minorBehind }.count
        let outdated = major + minor
        let advisories = resolved.reduce(0) { $0 + $1.advisoryCount }

        var parts = ["\(total) \(depWord)", "\(outdated) outdated"]
        if major > 0 { parts.append("\(major) major") }
        if advisories > 0 {
            parts.append("\(advisories) advisor\(advisories == 1 ? "y" : "ies")")
        }
        return parts.joined(separator: " · ")
    }

    /// The card's top accent, driven by the worst thing in it: any advisory →
    /// its severity color; else major/deprecated → orange; minor → yellow; all
    /// up-to-date → green; otherwise neutral.
    private func accentColor(_ resolved: [Resolved]) -> Color {
        guard store.stackCheckUpdates else { return .secondary }
        if let worst = resolved.compactMap({ $0.worstAdvisory }).max() {
            return worst.color
        }
        if resolved.contains(where: { $0.status == .majorBehind || $0.status == .deprecated }) {
            return .orange
        }
        if resolved.contains(where: { $0.status == .minorBehind }) { return .yellow }
        if !resolved.isEmpty, resolved.allSatisfy({ $0.status == .upToDate }) { return .green }
        return .secondary
    }

    private func toggleExpanded(_ id: String) {
        if expandedProjects.contains(id) {
            expandedProjects.remove(id)
        } else {
            expandedProjects.insert(id)
        }
    }

    // MARK: Empty / loading states

    private var loadingOrEmpty: some View {
        VStack(spacing: 8) {
            if store.isScanningStack { ProgressView() }
            Text(store.isScanningStack ? "Analyzing your stack…" : "No dependency data yet")
                .font(.headline)
            Text("StackPulse reads each project's manifests and lockfiles.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard(padding: 24)
    }

    private var emptyRoots: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Add a project folder to see stack health")
                .font(.headline)
            Text("Approve folders in Projects → StackPulse reads their manifests and lockfiles to flag outdated dependencies and advisories.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard(padding: 24)
    }
}

// MARK: - Dependency row

/// A dense per-dependency line: a leading status dot (never color-only — always
/// paired with a chip + text), the name, an optional `dev` chip, the installed →
/// latest versions, a status chip, and a red advisory chip when advisories exist.
private struct DepRow: View {
    let resolved: Resolved
    let checking: Bool

    private var status: DepStatus { resolved.status }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: checking ? status.color : .secondary, size: 7)

            Text(resolved.dep.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if resolved.dep.is_dev {
                Chip(text: "dev", systemImage: "hammer", tint: .secondary)
            }

            Spacer(minLength: 8)

            versionText

            if checking {
                Chip(text: status.label, systemImage: status.icon, tint: status.color)
                if resolved.advisoryCount > 0 {
                    Chip(
                        text: "\(resolved.advisoryCount) advisor\(resolved.advisoryCount == 1 ? "y" : "ies")",
                        systemImage: "exclamationmark.shield.fill",
                        tint: .red
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var versionText: some View {
        Group {
            if let installed = resolved.dep.installed, !installed.isEmpty {
                if checking, let latest = resolved.latest, !latest.isEmpty, latest != installed {
                    Text("\(installed) → \(latest)")
                } else {
                    Text(installed)
                }
            } else if let required = resolved.dep.required, !required.isEmpty {
                Text(required)
            } else {
                Text("—")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// One combined label so VoiceOver reads name + versions + status + advisories
    /// as a single element, never color-only.
    private var accessibilityText: String {
        var parts = [resolved.dep.name]
        if resolved.dep.is_dev { parts.append("dev dependency") }
        if let installed = resolved.dep.installed, !installed.isEmpty {
            if checking, let latest = resolved.latest, !latest.isEmpty, latest != installed {
                parts.append("installed \(installed), latest \(latest)")
            } else {
                parts.append("installed \(installed)")
            }
        }
        if checking {
            parts.append(status.label)
            if resolved.advisoryCount > 0 {
                parts.append("\(resolved.advisoryCount) advisor\(resolved.advisoryCount == 1 ? "y" : "ies")")
            }
        }
        return parts.joined(separator: ", ")
    }
}
