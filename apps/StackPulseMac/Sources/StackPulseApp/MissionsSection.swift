import SwiftUI

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

    private var messageLabel: String? {
        guard let count = mission.message_count else { return nil }
        return "\(count) message\(count == 1 ? "" : "s")"
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
            metricsRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: cardTint, padding: 14)
        .accessibilityElement(children: .contain)
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
                    title: "No active sessions",
                    message: "No AI coding sessions in the last 2 hours."
                )
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    summaryBar(missions)
                    ForEach(groups(missions), id: \.0) { status, items in
                        groupBlock(status, items)
                    }
                }
            }
        }
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

    private func groupBlock(_ status: MissionStatus, _ items: [Mission]) -> some View {
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
                MissionCard(mission: mission)
            }
        }
    }
}
