import SwiftUI
import AppKit

// MARK: - Shared mission views (reused by the section, Command Center, popover)

/// A status dot for a mission. When the mission is Active (and Reduce Motion is
/// off) a soft ring pulses outward from it — a subtle "live" heartbeat. Falls
/// back to a plain ``StatusDot`` for every other state and under Reduce Motion.
/// Color is never the sole signal; call sites pair it with the status label.
struct MissionPulseDot: View {
    let status: MissionStatus
    var size: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var isLive: Bool { status == .active && !reduceMotion }

    var body: some View {
        ZStack {
            if isLive {
                Circle()
                    .stroke(status.color.opacity(0.6), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(pulsing ? 2.3 : 1)
                    .opacity(pulsing ? 0 : 0.7)
            }
            StatusDot(color: status.color, size: size)
        }
        .frame(width: size + 12, height: size + 12)
        .onAppear {
            guard isLive else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small status pill (icon + label, tinted) — never color-only.
struct MissionStatusChip: View {
    let status: MissionStatus
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: status.icon).imageScale(.small)
            Text(status.label)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(status.color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.label)")
    }
}

/// A compact one-mission row: pulse dot, project + branch, last-activity summary,
/// and a trailing status + tokens/hr (or relative time). Used by the Command
/// Center Live Activity panel. Dense enough to list several without scrolling.
struct MissionRow: View {
    let mission: Mission

    var body: some View {
        HStack(spacing: 10) {
            MissionPulseDot(status: mission.statusKind)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(mission.projectLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let branch = mission.branch, !branch.isEmpty {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Text(mission.last_activity ?? mission.providerDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                MissionStatusChip(status: mission.statusKind)
                if let tph = mission.tokens_last_hour, tph > 0 {
                    Text("\(Format.tokens(tph))/hr")
                        .font(.system(size: 9)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                } else {
                    Text(Format.relative(mission.lastActivityAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["\(mission.projectLabel), \(mission.statusKind.label)"]
        if let last = mission.last_activity, !last.isEmpty { parts.append(last) }
        parts.append("active \(Format.relative(mission.lastActivityAt))")
        return parts.joined(separator: ". ")
    }
}

/// A full mission card for the Missions section: identity (provider chip, project,
/// branch, model), status + relative last-activity, the last-activity summary, and
/// a metrics row (messages, tokens/hr). Active cards carry a green glass tint.
struct MissionCard: View {
    let mission: Mission

    /// The strongest completion evidence we have for this session's project: a real
    /// test/check outcome. `nil` means unverified — which the UI says out loud
    /// rather than implying the work is fine.
    ///
    /// Resolved once for the whole list by the parent, not per card: the match
    /// depends only on the project path, so cards sharing a project would each
    /// rescan every captured run to reach the same answer, on every body pass.
    let verification: CommandRun?

    @EnvironmentObject private var store: SnapshotStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filesExpanded = false
    @State private var copied = false
    @State private var handedOff = false

    private var messageLabel: String? {
        guard let count = mission.message_count else { return nil }
        return "\(count) message\(count == 1 ? "" : "s")"
    }

    private var previewText: String? {
        guard let p = mission.last_message_preview, !p.isEmpty else { return nil }
        return p
    }

    private var revealPath: String? {
        guard let path = mission.project_path, !path.isEmpty else { return nil }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            identityRow
            if let last = mission.last_activity, !last.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.rays").imageScale(.small).foregroundStyle(.secondary)
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            if let preview = previewText {
                previewLine(preview)
            }
            if !mission.scopeFlags.isEmpty {
                scopeGuardBlock(mission.scopeFlags)
            }
            if !mission.changedFiles.isEmpty {
                changedFilesBlock(mission.changedFiles)
                verificationRow
            }
            metricsRow
            // Always present: a handoff package can be built for any session.
            actionsRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: cardTint, padding: 14)
        .accessibilityElement(children: .contain)
    }

    // MARK: Latest turn preview

    /// A quoted snippet of the session's most recent turn — the "latest turn."
    private func previewLine(_ preview: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            Text(preview)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Latest turn: \(preview)")
    }

    // MARK: Verification (evidence-based completion)

    /// Whether anything actually verified this session's changes. Shown only when
    /// the agent changed files — that's when "did anyone check?" matters.
    ///
    /// An agent going quiet is NOT evidence the work is good, so the no-evidence
    /// case is stated plainly instead of being left blank (which would read as
    /// "fine"). A passing run from *before* the session started is also called out,
    /// since it says nothing about what the agent just did.
    @ViewBuilder private var verificationRow: some View {
        if let v = verification {
            let stale = !MissionEvidence.isAfterSessionStart(v, mission)
            let tint: Color = stale ? .secondary : (v.status == .passed ? .green : .red)
            HStack(spacing: 6) {
                Image(systemName: v.status == .passed
                      ? (stale ? "clock.badge.questionmark" : "checkmark.seal.fill")
                      : "xmark.octagon.fill")
                    .imageScale(.small)
                    .foregroundStyle(tint)
                Text(stale
                     ? "\(v.label) passed, but before this session started — not evidence for these changes"
                     : "\(v.label) \(v.status == .passed ? "passed" : "failed") \(Format.relative(v.startedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(stale
                ? "Verification predates this session"
                : "\(v.label) \(v.status == .passed ? "passed" : "failed")")
        } else {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                Text("Not verified — no test run captured for this project since these changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not verified: no test run captured for these changes")
        }
    }

    // MARK: Scope guard

    /// Scope-guard flags: a compact, color-coded row warning what *kind* of change
    /// the session is making (touched secrets, migrations, dependencies, …). The
    /// color is always paired with the label text and an icon, never used alone.
    private func scopeGuardBlock(_ flags: [ScopeFlag]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "shield.lefthalf.filled")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("SCOPE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(flags) { flag in
                    let tint = ScopeStyle.tint(flag.severity)
                    // `matchedFileCount`, not `files.count`: the core caps the list
                    // at 8, so counting it announced "Security / auth code · 8" for
                    // a session that touched 40 auth files — a scope guard talking
                    // a change DOWN. The tooltip says so when the list is a sample.
                    Chip(
                        text: flag.matchedFileCount > 1 ? "\(flag.label) · \(flag.matchedFileCount)" : flag.label,
                        systemImage: ScopeStyle.icon(flag.kind),
                        tint: tint
                    )
                    .help(scopeHelp(flag))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scope: " + flags.map(\.label).joined(separator: ", "))
    }

    /// The flag's files, disclosing when the list is only a sample of the match.
    private func scopeHelp(_ flag: ScopeFlag) -> String {
        let list = flag.files.joined(separator: ", ")
        guard flag.filesAreSampled else { return list }
        return "Showing \(flag.files.count) of \(flag.matchedFileCount):\n\(list)"
    }

    // MARK: Changed files

    /// The mission's changed files: an orange "N changed" chip and up to five file
    /// names (middle-truncated monospace), with a tap-to-expand "+K more". The
    /// orange is paired with the count text and the clipboard glyph, never alone.
    private func changedFilesBlock(_ files: [String]) -> some View {
        let limit = 5
        let shown = filesExpanded ? files : Array(files.prefix(limit))
        let overflow = files.count - shown.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.and.list.clipboard")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                Chip(text: "\(files.count) changed", tint: .orange)
                Spacer(minLength: 0)
            }
            ForEach(shown, id: \.self) { file in
                Text(file)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if overflow > 0 || (filesExpanded && files.count > limit) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        filesExpanded.toggle()
                    }
                } label: {
                    Text(filesExpanded ? "Show less" : "+\(overflow) more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(files.count) changed file\(files.count == 1 ? "" : "s"): \(shown.joined(separator: ", "))")
    }

    // MARK: Quick actions (safe, local-only)

    private var actionsRow: some View {
        HStack(spacing: 8) {
            if let path = revealPath {
                Button {
                    revealInFinder(path)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show \(path) in Finder")
                .accessibilityLabel("Reveal project in Finder")
            }
            if let preview = previewText {
                Button {
                    copy(preview)
                } label: {
                    Label(copied ? "Copied" : "Copy latest turn",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy the latest turn")
                .accessibilityLabel(copied ? "Copied latest turn" : "Copy latest turn")
            }

            Button(action: copyHandoff) {
                Label(handedOff ? "Copied" : "Handoff",
                      systemImage: handedOff ? "checkmark" : "arrowshape.turn.up.right")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy a handoff package — what this session touched, what it risks, whether anything verified it, and how to get back")
            .accessibilityLabel(handedOff ? "Copied handoff package" : "Copy handoff package")

            Button(action: saveHandoff) {
                Label("Save…", systemImage: "square.and.arrow.down")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Save the handoff package as Markdown")

            Spacer(minLength: 0)
        }
    }

    /// Compose the handoff from what we already know about this session.
    private func handoffMarkdown() -> String {
        HandoffPackage.markdown(
            mission: mission,
            evidence: MissionEvidence.latestRun(for: mission, in: store.commandRuns),
            verification: verification,
            // Only checkpoints already loaded for this project — never trigger a
            // git read from a button tap in a list.
            checkpoints: mission.project_path.flatMap { store.checkpoints[$0] } ?? [],
            generatedAt: Date()
        )
    }

    private func copyHandoff() {
        CommandRunner.copy(handoffMarkdown())
        handedOff = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            handedOff = false
        }
    }

    private func saveHandoff() {
        Exporter.save(text: handoffMarkdown(),
                      suggestedName: HandoffPackage.suggestedFilename(for: mission))
    }

    // MARK: Actions

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { copied = false }
        }
    }

    /// Tint the glass for states that benefit from a glance signal; keep calmer
    /// states untinted so the section doesn't read as a wall of color.
    private var cardTint: Color? {
        switch mission.statusKind {
        case .active: return .green
        case .stalled: return .orange
        default: return nil
        }
    }

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 8) {
            MissionPulseDot(status: mission.statusKind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mission.projectLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let branch = mission.branch, !branch.isEmpty {
                        Chip(text: branch, systemImage: "arrow.triangle.branch", tint: .secondary)
                    }
                }
                HStack(spacing: 6) {
                    Chip(text: mission.providerDisplay, systemImage: "cpu", tint: .secondary)
                    if let model = mission.model, !model.isEmpty {
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                MissionStatusChip(status: mission.statusKind)
                Text("active \(Format.relative(mission.lastActivityAt))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 16) {
            if let messageLabel {
                metric(systemImage: "bubble.left.and.bubble.right", value: messageLabel)
            }
            if let tph = mission.tokens_last_hour {
                metric(systemImage: "bolt", value: "\(Format.tokens(tph)) tok/hr")
            }
            if let started = mission.startedAt {
                metric(systemImage: "hourglass", value: "started \(Format.relative(started))")
            }
            Spacer(minLength: 0)
        }
    }

    private func metric(systemImage: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).imageScale(.small).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Missions section (main window)

/// The Missions sidebar destination: every observed AI coding session on this
/// Mac, grouped by liveness (Active → Idle → Recent → Stalled → Unknown). Empty
/// / quiet state explains that nothing has been active recently.
struct MissionsSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SectionScaffold(section: .missions) { _ in
            let missions = store.missions
            if missions.isEmpty {
                EmptyStateView(
                    icon: "moon.zzz",
                    title: "No AI sessions right now",
                    message: "StackPulse hasn't seen an AI coding session on this Mac in the last 2 hours. Start one in Claude Code, Codex, Cursor or another supported tool and it shows up here live — what it's working on, its tokens per hour, and its branch."
                )
            } else {
                let verifications = verificationIndex(missions, store.commandRuns)
                VStack(alignment: .leading, spacing: 18) {
                    summaryBar(missions)
                    ForEach(groups(missions), id: \.0) { status, items in
                        groupBlock(status, items, verifications)
                    }
                }
            }
        }
    }

    // MARK: Verification index

    /// Each project's verifying run, resolved once for the whole list and keyed by
    /// `project_path` — the only field the match looks at.
    ///
    /// Defers to ``MissionEvidence/latestVerification(for:in:)`` rather than
    /// reimplementing the match, so what counts as verifying a mission stays
    /// defined in one place. A project with no verifying run is simply absent, so a
    /// miss reads back as the same `nil` the card renders as "not verified".
    ///
    /// `resolved` tracks paths already asked about, so a project that answers `nil`
    /// isn't rescanned once per mission it owns.
    private func verificationIndex(_ missions: [Mission], _ runs: [CommandRun]) -> [String: CommandRun] {
        var index: [String: CommandRun] = [:]
        var resolved: Set<String> = []
        for mission in missions {
            guard let path = mission.project_path, !path.isEmpty,
                  resolved.insert(path).inserted else { continue }
            index[path] = MissionEvidence.latestVerification(for: mission, in: runs)
        }
        return index
    }

    /// A mission's entry in the prebuilt index. The absent/empty-path guard mirrors
    /// ``MissionEvidence/latestVerification(for:in:)``, which refuses to hand a
    /// mission evidence when we don't know which project it belongs to.
    private func verification(for mission: Mission, in index: [String: CommandRun]) -> CommandRun? {
        guard let path = mission.project_path, !path.isEmpty else { return nil }
        return index[path]
    }

    // MARK: Summary

    private func summaryBar(_ missions: [Mission]) -> some View {
        let active = missions.filter { $0.statusKind == .active }.count
        return HStack(spacing: 10) {
            Label(
                "\(missions.count) session\(missions.count == 1 ? "" : "s") observed",
                systemImage: "bolt.horizontal.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            if active > 0 {
                Chip(text: "\(active) active", systemImage: "bolt.fill", tint: .green)
            }
            Spacer()
        }
    }

    // MARK: Status groups

    private func groups(_ all: [Mission]) -> [(MissionStatus, [Mission])] {
        [MissionStatus.active, .idle, .recent, .stalled, .unknown].compactMap { status in
            let items = all.filter { $0.statusKind == status }
            return items.isEmpty ? nil : (status, items)
        }
    }

    private func groupBlock(_ status: MissionStatus,
                            _ items: [Mission],
                            _ verifications: [String: CommandRun]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                Text(status.label)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { mission in
                MissionCard(mission: mission,
                            verification: verification(for: mission, in: verifications))
            }
        }
    }
}

// MARK: - Scope-guard styling

/// Maps scope-flag kinds/severities to a glyph and tint. Severity drives color
/// (high = red, notable = orange, info = secondary); kind drives the icon.
enum ScopeStyle {
    static func icon(_ kind: String) -> String {
        switch kind {
        case "secrets": return "key.fill"
        case "migrations": return "cylinder.split.1x2"
        case "security": return "lock.shield"
        case "dependencies": return "shippingbox"
        case "lockfile": return "lock.doc"
        case "build_config": return "gearshape.2"
        case "tests": return "checkmark.seal"
        default: return "doc"
        }
    }

    static func tint(_ severity: String) -> Color {
        switch severity {
        case "high": return .red
        case "notable": return .orange
        default: return .secondary
        }
    }
}
