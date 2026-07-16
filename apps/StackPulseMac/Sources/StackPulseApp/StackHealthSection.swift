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
///
/// `status` and `actionRank` are interpreted ONCE here rather than being computed
/// properties: `sorted(by:)` evaluates `actionRank` on both sides of every
/// comparison, so re-deriving `DepStatus` from the raw string on each access ran
/// the string switch O(n log n) times per project per body evaluation.
private struct Resolved: Identifiable {
    let dep: Dependency
    let latest: String?
    let status: DepStatus
    let advisoryCount: Int
    let worstAdvisory: AdvisoryLevel?
    /// Sort key: advisories first, then most-behind, then unknown, then up-to-date.
    let actionRank: Int

    var id: String { dep.id }

    init(
        dep: Dependency,
        latest: String?,
        statusRaw: String,
        advisoryCount: Int,
        worstAdvisory: AdvisoryLevel?
    ) {
        let status = DepStatus(statusRaw)
        self.dep = dep
        self.latest = latest
        self.status = status
        self.advisoryCount = advisoryCount
        self.worstAdvisory = worstAdvisory
        if advisoryCount > 0 {
            self.actionRank = 0
        } else {
            switch status {
            case .majorBehind, .deprecated: self.actionRank = 1
            case .minorBehind: self.actionRank = 2
            case .unknown: self.actionRank = 3
            case .upToDate: self.actionRank = 4
            }
        }
    }
}

// MARK: - Per-project fold (one pass over the dependency list)

/// Every number a project card displays, folded from its dependency list in a
/// SINGLE pass. The header line and the card accent each used to re-walk the list
/// (a `filter` per counter plus `contains` / `allSatisfy` / `reduce`), so a card
/// traversed its dependencies ~10 times per body evaluation to produce six numbers.
///
/// `major` counts majorBehind ∪ deprecated: the accent and the summary line have
/// always shared that exact predicate, so one counter serves both.
///
/// HONESTY: this folds `Resolved` values, which already encode "not yet enriched"
/// as `.unknown`. Unknown deps land in `total` and in NEITHER `major` nor `minor`
/// — identical to the filters this replaces. The fold adds no knowledge: it cannot
/// turn a pending enrichment into a confident zero, because it never invents a
/// status the resolver didn't already produce.
private struct ProjectSummary {
    let total: Int
    let major: Int
    let minor: Int
    let upToDate: Int
    /// Deps whose latest version we don't know yet — counted so the header can say
    /// "not checked" instead of reporting them as nothing-to-see.
    let unknown: Int
    let advisories: Int
    let worstAdvisory: AdvisoryLevel?

    init(_ resolved: [Resolved]) {
        var major = 0
        var minor = 0
        var upToDate = 0
        var unknown = 0
        var advisories = 0
        var worst: AdvisoryLevel?
        for r in resolved {
            switch r.status {
            case .majorBehind, .deprecated: major += 1
            case .minorBehind: minor += 1
            case .upToDate: upToDate += 1
            case .unknown: unknown += 1
            }
            advisories += r.advisoryCount
            if let w = r.worstAdvisory {
                worst = worst.map { Swift.max($0, w) } ?? w
            }
        }
        self.total = resolved.count
        self.major = major
        self.minor = minor
        self.upToDate = upToDate
        self.unknown = unknown
        self.advisories = advisories
        self.worstAdvisory = worst
    }
}

// MARK: - Derivations (file-scope: a card folds these in `init`, before `self` exists)

/// The status of ONE dependency IN ONE project.
///
/// `StackHealthClient.enrich` keys its map by `ecosystem + name`, so every project
/// using a dep shares a single `DependencyEnrichment` — and its `status` was
/// computed from whichever project's installed version the client happened to fold
/// last. That verdict is wrong for everyone else: 45 of this portfolio's 63
/// multi-project deps sit at different versions per project (`react` spans
/// 18.3.1…19.2.7, `tailwindcss` 3.4.19…4.3.2), so the shared verdict would report
/// the 18.3.1 project as "Up to date" — a confident answer about a dep nobody
/// compared, the same failure mode as the "0 outdated" header this file already fixed.
///
/// `latest` IS a property of the package, not of a project, so it's safe to share.
/// Re-running the client's own pure comparison against THIS project's installed
/// version is the identical formula with the correct input: no network, no new
/// core request, and one extra O(1) parse inside a pass the caller already makes.
private func projectStatusRaw(_ dep: Dependency, latest: String?) -> String {
    StackHealthClient.compareStatus(
        installed: StackHealthClient.installedVersion(dep),
        latest: latest
    )
}

/// Prefers live enrichment; falls back to the core's offline fields while a
/// fetch is pending; shows inventory-only when update-checking is off.
private func resolve(
    _ dep: Dependency,
    enrichment: [String: StackHealthClient.DependencyEnrichment],
    checking: Bool
) -> Resolved {
    if checking, let e = enrichment[dep.id] {
        let worst = e.advisories.map { AdvisoryLevel($0.severity) }.max()
        return Resolved(
            dep: dep, latest: e.latest,
            statusRaw: projectStatusRaw(dep, latest: e.latest),
            advisoryCount: e.advisories.count, worstAdvisory: worst
        )
    }
    if checking {
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
private func summaryLine(_ s: ProjectSummary, checking: Bool) -> String {
    let depWord = s.total == 1 ? "dep" : "deps"
    guard checking else {
        return "\(s.total) \(depWord) · update checking off"
    }
    var parts = ["\(s.total) \(depWord)"]

    // "0 outdated" is only true of deps we actually checked. Enrichment is a
    // network round-trip, so a freshly-opened project is all-unknown — and it used
    // to announce "0 outdated", which reads as a clean bill of health for deps
    // nobody has looked at yet. Report what we don't know instead of scoring it 0.
    if s.unknown == s.total {
        parts.append("not checked yet")
    } else {
        parts.append("\(s.major + s.minor) outdated")
        if s.major > 0 { parts.append("\(s.major) major") }
        if s.unknown > 0 { parts.append("\(s.unknown) unchecked") }
    }
    if s.advisories > 0 {
        parts.append("\(s.advisories) advisor\(s.advisories == 1 ? "y" : "ies")")
    }
    return parts.joined(separator: " · ")
}

/// The card's top accent, driven by the worst thing in it: any advisory →
/// its severity color; else major/deprecated → orange; minor → yellow; all
/// up-to-date → green; otherwise neutral. Order of the tests is load-bearing.
private func cardAccent(_ s: ProjectSummary, checking: Bool) -> Color {
    guard checking else { return .secondary }
    if let worst = s.worstAdvisory { return worst.color }
    if s.major > 0 { return .orange }
    if s.minor > 0 { return .yellow }
    if s.total > 0, s.upToDate == s.total { return .green }
    return .secondary
}

// MARK: - Cross-project digest (one fold across every project)

/// How many rows each digest list shows before collapsing into "+N more". The
/// digest earns its place by being shorter than the cards it summarises; a feed
/// long enough to scroll is just the wall of cards again.
private let digestAdvisoryLimit = 4
private let digestUpdateLimit = 5

/// One dependency aggregated across every project that uses it — the digest's
/// unit, and the thing the per-project cards structurally cannot show.
private struct DigestGroup: Identifiable {
    let id: String
    let name: String
    let latest: String?
    /// The projects this row is about: everyone using the dep on an advisory row,
    /// only the projects actually behind on an update row.
    let projects: [String]
    /// Distinct installed versions among `projects`.
    let versions: [String]
    let advisoryCount: Int
    let worstAdvisory: AdvisoryLevel?
    let deprecated: Bool
    /// Whether every project using this dep runs the SAME version. OSV is queried
    /// once per dep id, at one version, and an advisory is version-specific — so
    /// only when this holds does the advisory provably apply to all of `projects`.
    /// When it's false the row says so instead of naming projects as confirmed.
    let versionsAgree: Bool
}

/// Per-dependency accumulator for the fold below.
private struct DigestAccum {
    var name: String
    var latest: String?
    var allProjects: [String] = []
    var allVersions: Set<String> = []
    var actionProjects: [String] = []
    var actionVersions: Set<String> = []
    var advisoryCount = 0
    var worst: AdvisoryLevel?
    var hasDeprecated = false
}

/// The whole digest, folded from every project's dependency list in a SINGLE pass.
///
/// HONESTY: this reports only what enrichment actually established. A dep with no
/// `latest` resolves to `.unknown` and lands in `uncheckedDeps` — never in a clean
/// count — so `advisories.isEmpty && updates.isEmpty` means "nothing found in what
/// was checked", not "all clear". Every consumer of that state pairs it with
/// `uncheckedDeps`, because an un-enriched portfolio is entirely `.unknown` and an
/// empty feed over it would otherwise read as a pass.
private struct StackDigest {
    let advisories: [DigestGroup]
    let updates: [DigestGroup]
    let totalDeps: Int
    /// Deps with no known latest version — not checked, and not "fine".
    let uncheckedDeps: Int
    let projectCount: Int

    var checkedDeps: Int { totalDeps - uncheckedDeps }
    /// Nothing has been compared against a registry yet — the feed has no opinion.
    var nothingChecked: Bool { totalDeps > 0 && uncheckedDeps == totalDeps }
    var foundNothing: Bool { advisories.isEmpty && updates.isEmpty }

    init(projects: [ProjectStack], enrichment: [String: StackHealthClient.DependencyEnrichment]) {
        var acc: [String: DigestAccum] = [:]
        var total = 0
        var unchecked = 0

        for proj in projects {
            for dep in proj.dependencies {
                total += 1
                let e = enrichment[dep.id]
                let latest = e?.latest
                let status = DepStatus(projectStatusRaw(dep, latest: latest))
                if status == .unknown { unchecked += 1 }

                let version = StackHealthClient.installedVersion(dep) ?? "—"
                var a = acc[dep.id] ?? DigestAccum(name: dep.name, latest: latest)
                a.latest = latest
                a.allProjects.append(proj.name)
                a.allVersions.insert(version)
                if let e, !e.advisories.isEmpty {
                    // ASSIGNED, never summed: enrichment holds ONE advisory record
                    // per dep id, which every project using that dep reads. Summing
                    // across projects would multiply the same two advisories into
                    // "eight" — a count nobody could stand behind.
                    a.advisoryCount = e.advisories.count
                    a.worst = e.advisories.map { AdvisoryLevel($0.severity) }.max()
                }
                if status == .majorBehind || status == .deprecated {
                    a.actionProjects.append(proj.name)
                    a.actionVersions.insert(version)
                    if status == .deprecated { a.hasDeprecated = true }
                }
                acc[dep.id] = a
            }
        }

        var advisoryGroups: [DigestGroup] = []
        var updateGroups: [DigestGroup] = []
        for (id, a) in acc {
            let agree = a.allVersions.count == 1
            if a.advisoryCount > 0 {
                advisoryGroups.append(DigestGroup(
                    id: id, name: a.name, latest: a.latest,
                    projects: a.allProjects.sorted(), versions: a.allVersions.sorted(),
                    advisoryCount: a.advisoryCount, worstAdvisory: a.worst,
                    deprecated: a.hasDeprecated, versionsAgree: agree
                ))
            }
            if !a.actionProjects.isEmpty {
                updateGroups.append(DigestGroup(
                    id: id, name: a.name, latest: a.latest,
                    projects: a.actionProjects.sorted(), versions: a.actionVersions.sorted(),
                    advisoryCount: 0, worstAdvisory: nil,
                    deprecated: a.hasDeprecated, versionsAgree: agree
                ))
            }
        }

        // Ranked by what deserves action first. Both comparators end on `id` so a
        // dictionary's arbitrary iteration order can't reorder equal rows between
        // body evaluations.
        advisoryGroups.sort { l, r in
            let ls = l.worstAdvisory ?? .unknown
            let rs = r.worstAdvisory ?? .unknown
            if ls != rs { return ls > rs }
            if l.advisoryCount != r.advisoryCount { return l.advisoryCount > r.advisoryCount }
            if l.projects.count != r.projects.count { return l.projects.count > r.projects.count }
            return l.id < r.id
        }
        // Breadth first: the digest's whole reason to exist is that one bump can
        // clear many projects at once. A single-project major sorts last here — its
        // own card already says so.
        updateGroups.sort { l, r in
            if l.deprecated != r.deprecated { return l.deprecated }
            if l.projects.count != r.projects.count { return l.projects.count > r.projects.count }
            return l.id < r.id
        }

        self.advisories = advisoryGroups
        self.updates = updateGroups
        self.totalDeps = total
        self.uncheckedDeps = unchecked
        self.projectCount = projects.count
    }
}

/// Names the projects a row is about — "project-aware" means a row must say WHERE,
/// not just what. Capped so one ubiquitous dep can't turn a row into a paragraph.
private func projectList(_ names: [String]) -> String {
    let shown = names.prefix(3)
    let rest = names.count - shown.count
    let joined = shown.joined(separator: ", ")
    return rest > 0 ? "\(joined) +\(rest)" : joined
}

/// `installed → latest` for an update row. Projects behind on the same dep aren't
/// necessarily on the same version, so the left side collapses to a count rather
/// than picking one project's version to speak for the rest.
private func versionArrow(_ g: DigestGroup) -> String {
    let from = g.versions.count == 1 ? (g.versions.first ?? "—") : "\(g.versions.count) versions"
    guard let latest = g.latest, !latest.isEmpty else { return from }
    return "\(from) → \(latest)"
}

// MARK: - Section

struct StackHealthSection: View {
    @EnvironmentObject var store: SnapshotStore

    /// Network enrichment keyed by `Dependency.id`, filled off the main actor.
    /// Enrichment lives on the store, not here: this view is an Advisor tab and is
    /// destroyed on every tab switch, which previously threw the whole download
    /// away and re-fetched it.
    private var enrichment: [String: StackHealthClient.DependencyEnrichment] { store.stackEnrichment }
    private var enriching: Bool { store.isEnrichingStack }
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
                    // Only with update-checking ON: offline there is nothing to
                    // rank (the core reports every dep as `unknown`), and
                    // `updateCheckOffNote` above already says exactly that. A
                    // digest there could only be an empty feed pretending to be
                    // a verdict.
                    if store.stackCheckUpdates {
                        StackDigestCard(
                            projects: store.stackHealth,
                            enrichment: enrichment,
                            scannedAt: store.stackUpdatedAt,
                            enriching: enriching
                        )
                    }
                    // LAZY on purpose, like `RunConsoleView`'s console log. This
                    // sits in `SectionScaffold`'s ScrollView and renders one tall
                    // card per approved project — a real portfolio scan is ~27
                    // projects / ~570 deps, and until enrichment lands every dep
                    // is `.unknown`, i.e. every row is a visible row. A plain
                    // VStack built and laid out all of them on every body
                    // evaluation, including the cards nowhere near the viewport.
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(store.stackHealth) { proj in
                            StackProjectCard(
                                proj: proj,
                                enrichment: enrichment,
                                checking: store.stackCheckUpdates,
                                expanded: expandedProjects.contains(proj.id),
                                onToggle: { toggleExpanded(proj.id) }
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            if store.stackHealth.isEmpty, !store.approvedRoots.isEmpty { store.rescanStackHealth() }
            store.enrichStack()
        }
        // A fresh scan invalidates enrichment — clear and re-fetch.
        .onChange(of: store.stackUpdatedAt) { _, _ in
            store.enrichStack(force: true)
        }
        // Toggling update-checking on kicks a fetch; off clears any live data.
        .onChange(of: store.stackCheckUpdates) { _, isOn in
            if isOn { store.enrichStack() } else { store.clearStackEnrichment() }
        }
    }

    // MARK: Enrichment


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

// MARK: - Cross-project digest card

/// The ranked "what needs my attention across everything" feed that opens the
/// section. 27 projects / ~570 deps is 27 cards of scrolling before you know
/// whether anything is on fire; this answers that in one card.
///
/// Like `StackProjectCard`, the whole fold runs ONCE in `init` and the body only
/// reads stored `let`s. This is the section's single aggregate pass over every
/// dependency — the per-project cards each fold their own list, and neither
/// re-walks anything in `body`.
private struct StackDigestCard: View {
    /// Passed in, never read from the clock here: the exit criteria ask for
    /// timestamped recommendations, and a view must not sample `Date()` in render.
    let scannedAt: Date?
    let enriching: Bool

    private let digest: StackDigest

    init(
        projects: [ProjectStack],
        enrichment: [String: StackHealthClient.DependencyEnrichment],
        scannedAt: Date?,
        enriching: Bool
    ) {
        self.scannedAt = scannedAt
        self.enriching = enriching
        self.digest = StackDigest(projects: projects, enrichment: enrichment)
    }

    /// Green requires a COMPLETE check: with anything still unchecked the card
    /// stays neutral, because "we found nothing" and "we looked at everything" are
    /// different claims and only the second one earns an all-clear color.
    private var accent: Color {
        if let worst = digest.advisories.first?.worstAdvisory { return worst.color }
        if !digest.updates.isEmpty { return .orange }
        if digest.totalDeps > 0, digest.uncheckedDeps == 0 { return .green }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if digest.nothingChecked {
                notCheckedNote
            } else {
                if !digest.advisories.isEmpty { advisorySection }
                if !digest.updates.isEmpty { updateSection }
                if digest.foundNothing { foundNothingNote }
                if digest.uncheckedDeps > 0 { uncheckedNote }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: accent, padding: 14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(accent)
                Text("Needs attention first")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if enriching {
                    ProgressView().controlSize(.small)
                }
                // The scan time is the only timestamp that exists — the store keeps
                // no separate enrichment time — so it's labelled as what it is
                // rather than passed off as when the registries were queried.
                Text("scanned \(Format.relative(scannedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let projWord = digest.projectCount == 1 ? "project" : "projects"
        let base = "\(digest.projectCount) \(projWord) · \(digest.totalDeps) deps"
        guard !digest.nothingChecked else { return base }
        return "\(base) · \(digest.checkedDeps) checked"
    }

    // MARK: Ranked lists

    private var advisorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            listLabel("Security advisories", systemImage: "exclamationmark.shield.fill", tint: .red)
            ForEach(digest.advisories.prefix(digestAdvisoryLimit)) { g in
                advisoryRow(g)
            }
            if digest.advisories.count > digestAdvisoryLimit {
                moreNote(digest.advisories.count - digestAdvisoryLimit, noun: "more with advisories")
            }
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            listLabel("Major updates", systemImage: "arrow.up.circle.fill", tint: .orange)
            ForEach(digest.updates.prefix(digestUpdateLimit)) { g in
                updateRow(g)
            }
            if digest.updates.count > digestUpdateLimit {
                moreNote(digest.updates.count - digestUpdateLimit, noun: "more behind a major")
            }
        }
    }

    private func advisoryRow(_ g: DigestGroup) -> some View {
        let level = g.worstAdvisory ?? .unknown
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                StatusDot(color: level.color, size: 7)
                Text(g.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(g.versionsAgree ? (g.versions.first ?? "—") : "\(g.versions.count) versions")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Chip(
                    text: "\(g.advisoryCount) advisor\(g.advisoryCount == 1 ? "y" : "ies")",
                    systemImage: "exclamationmark.shield.fill",
                    tint: level.color
                )
                Spacer(minLength: 8)
                Text(projectList(g.projects))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // OSV answered for one version of this dep, and these projects don't
            // all run that version — so which of them is actually vulnerable is
            // not something this data can say. Say that, rather than name them.
            if !g.versionsAgree {
                Text("checked at one version · these \(g.projects.count) projects run \(g.versions.count) different versions — open their cards to confirm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(advisoryAccessibilityText(g))
    }

    private func updateRow(_ g: DigestGroup) -> some View {
        let status: DepStatus = g.deprecated ? .deprecated : .majorBehind
        let projWord = g.projects.count == 1 ? "project" : "projects"
        return HStack(spacing: 8) {
            StatusDot(color: status.color, size: 7)
            Text(g.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(versionArrow(g))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Chip(text: status.label, systemImage: status.icon, tint: status.color)
            Spacer(minLength: 8)
            Text("\(g.projects.count) \(projWord) · \(projectList(g.projects))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(g.name), \(versionArrow(g)), \(status.label), \(g.projects.count) \(projWord): \(g.projects.joined(separator: ", "))"
        )
    }

    private func advisoryAccessibilityText(_ g: DigestGroup) -> String {
        var parts = [g.name]
        parts.append("\(g.advisoryCount) advisor\(g.advisoryCount == 1 ? "y" : "ies")")
        if let worst = g.worstAdvisory, worst != .unknown {
            parts.append("worst severity \(severityWord(worst))")
        } else {
            parts.append("severity unknown")
        }
        parts.append("used by \(g.projects.joined(separator: ", "))")
        if !g.versionsAgree {
            parts.append("checked at one version, these projects run \(g.versions.count) different versions")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Honest states

    /// Enrichment is a network round-trip, so a freshly-opened section knows
    /// NOTHING — every dep is `.unknown`. Rendering an empty ranked feed here would
    /// read as an all-clear over deps nobody has looked at.
    private var notCheckedNote: some View {
        Label(
            enriching
                ? "Checking \(digest.totalDeps) deps against npm, crates.io and OSV…"
                : "Not checked yet — none of these \(digest.totalDeps) deps has been compared against a registry. This is not an all-clear.",
            systemImage: enriching ? "arrow.triangle.2.circlepath" : "questionmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Scoped to what was actually checked — never "you're all good".
    private var foundNothingNote: some View {
        Label(
            "No advisories or major updates in the \(digest.checkedDeps) deps checked.",
            systemImage: "checkmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var uncheckedNote: some View {
        Label(
            "\(digest.uncheckedDeps) of \(digest.totalDeps) deps have no latest version yet — not counted as up to date.",
            systemImage: "questionmark.circle"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Bits

    private func listLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .padding(.top, 2)
    }

    private func moreNote(_ n: Int, noun: String) -> some View {
        Text("+\(n) \(noun)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func severityWord(_ level: AdvisoryLevel) -> String {
        switch level {
        case .critical: return "critical"
        case .high: return "high"
        case .moderate: return "moderate"
        case .low: return "low"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Per-project card (stack health)

/// One project's stack-health glass card. Named for its section because
/// `ProjectsSection` already owns an unrelated, module-visible `ProjectCard`.
///
/// A `View` rather than a `@ViewBuilder` method on the section so the whole
/// per-card derivation — resolve → sort → split → fold — runs ONCE in `init`,
/// and only for the cards the enclosing `LazyVStack` actually materializes.
/// Everything the body reads is a stored `let`; the body itself derives nothing.
private struct StackProjectCard: View {
    let proj: ProjectStack
    let checking: Bool
    let expanded: Bool
    let onToggle: () -> Void

    private let notUpToDate: [Resolved]
    private let upToDate: [Resolved]
    private let summary: ProjectSummary
    private let accent: Color

    init(
        proj: ProjectStack,
        enrichment: [String: StackHealthClient.DependencyEnrichment],
        checking: Bool,
        expanded: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.proj = proj
        self.checking = checking
        self.expanded = expanded
        self.onToggle = onToggle

        let resolved = proj.dependencies.map { resolve($0, enrichment: enrichment, checking: checking) }
        // Same comparator over the same values as before, so the same order out.
        let sorted = resolved.sorted { $0.actionRank < $1.actionRank }
        // One walk instead of the two order-preserving `filter`s it replaces.
        var notUp: [Resolved] = []
        var up: [Resolved] = []
        for r in sorted {
            if r.status == .upToDate { up.append(r) } else { notUp.append(r) }
        }
        let summary = ProjectSummary(resolved)

        self.notUpToDate = notUp
        self.upToDate = up
        self.summary = summary
        self.accent = cardAccent(summary, checking: checking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if proj.dependencies.isEmpty {
                Text("No dependencies found in this project's manifests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(notUpToDate) { r in
                        DepRow(resolved: r, checking: checking)
                    }
                    if !upToDate.isEmpty {
                        if expanded {
                            ForEach(upToDate) { r in
                                DepRow(resolved: r, checking: checking)
                            }
                        }
                        Button(action: onToggle) {
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

    private var header: some View {
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
            Text(summaryLine(summary, checking: checking))
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
