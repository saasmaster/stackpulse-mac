import SwiftUI

// MARK: - Needs Attention (shared compact block)

/// A compact "needs attention" summary reused by the popover and the edge
/// sidebar: a header with a count, the top few alerts (icon + title + one-line
/// detail), and a "+N more" affordance. Tapping anywhere runs `onTap` (wired to
/// open the full inbox). Renders nothing when there are no alerts, so callers can
/// drop it in unconditionally.
struct NeedsAttentionBlock: View {
    let alerts: [Alert]
    var maxItems: Int = 3
    var onTap: (() -> Void)? = nil

    private var shown: [Alert] { Array(alerts.prefix(maxItems)) }
    private var overflow: Int { max(0, alerts.count - maxItems) }
    private var topSeverity: AlertSeverity { alerts.map(\.severityKind).max() ?? .info }

    var body: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: topSeverity.icon)
                        .foregroundStyle(topSeverity.color)
                    Text("Needs attention")
                        .font(.subheadline.weight(.semibold))
                    Chip(text: "\(alerts.count)", tint: topSeverity.color)
                    Spacer()
                    if onTap != nil {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { alert in
                        AlertRow(alert: alert)
                    }
                }

                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: 16, tint: topSeverity.color, padding: 12)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .help(onTap == nil ? "" : "Open the needs-attention inbox")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Needs attention: \(alerts.count) alert\(alerts.count == 1 ? "" : "s")")
        }
    }
}

/// A single dense alert line: severity glyph + title + one-line detail.
private struct AlertRow: View {
    let alert: Alert

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: alert.severityKind.icon)
                .foregroundStyle(alert.severityKind.color)
                .imageScale(.small)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(alert.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.severityKind.label): \(alert.title). \(alert.detail)")
    }
}

// MARK: - Needs Attention section (main window)

/// First sidebar destination: the full inbox of everything the core flagged,
/// grouped by severity, each acknowledgeable for the session. Empty / all-clear
/// state is friendly and offers to restore anything dismissed.
struct AlertsSection: View {
    @EnvironmentObject var store: SnapshotStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingAckAll = false

    var body: some View {
        SectionScaffold(section: .alerts) { snapshot in
            let active = store.activeAlerts
            if active.isEmpty {
                allClear
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    toolbar(active)
                    ForEach(groups(active), id: \.0) { severity, items in
                        groupBlock(severity, items, snapshot: snapshot)
                    }
                }
            }
        }
        .overlay {
            if confirmingAckAll {
                GlassConfirmDialog(
                    title: "Acknowledge all?",
                    message: "This clears the needs-attention list for now. You can restore dismissed items anytime.",
                    confirmTitle: "Acknowledge all",
                    onCancel: { confirmingAckAll = false },
                    onConfirm: {
                        store.acknowledgeAll()
                        confirmingAckAll = false
                    }
                )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: confirmingAckAll)
    }

    // MARK: Toolbar

    private func toolbar(_ active: [Alert]) -> some View {
        HStack(spacing: 10) {
            Label(
                "\(active.count) item\(active.count == 1 ? "" : "s") need\(active.count == 1 ? "s" : "") attention",
                systemImage: "bell.badge"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            Spacer()

            if store.acknowledgedCount > 0 {
                Button {
                    store.restoreAcknowledged()
                } label: {
                    Label("Restore \(store.acknowledgedCount) dismissed", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Button {
                confirmingAckAll = true
            } label: {
                Label("Acknowledge all", systemImage: "checkmark.circle")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass(tint: .accentColor))
        }
    }

    // MARK: Severity groups

    private func groups(_ active: [Alert]) -> [(AlertSeverity, [Alert])] {
        [AlertSeverity.critical, .warning, .info].compactMap { severity in
            let items = active.filter { $0.severityKind == severity }
            return items.isEmpty ? nil : (severity, items)
        }
    }

    private func groupBlock(_ severity: AlertSeverity, _ items: [Alert], snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: severity.icon)
                    .foregroundStyle(severity.color)
                Text(severity.label)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { alert in
                AlertCard(
                    alert: alert,
                    providerName: displayName(for: alert.provider, in: snapshot),
                    onDismiss: { store.acknowledge(alert.id) }
                )
            }
        }
    }

    private func displayName(for providerID: String, in snapshot: UsageSnapshot) -> String {
        snapshot.providers.first { $0.provider == providerID }?.display_name
            ?? providerID.capitalized
    }

    // MARK: All-clear

    private var allClear: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("All clear")
                    .font(.headline)
                Text("Nothing needs your attention.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
            .glassCard(padding: 24)

            if store.acknowledgedCount > 0 {
                Button {
                    store.restoreAcknowledged()
                } label: {
                    Label("Restore \(store.acknowledgedCount) dismissed", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}

/// A full alert card: severity glyph, title, detail, provider chip, relative time,
/// and a session-only dismiss control.
struct AlertCard: View {
    let alert: Alert
    let providerName: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.severityKind.icon)
                .font(.title3)
                .foregroundStyle(alert.severityKind.color)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(alert.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(alert.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Chip(text: providerName, systemImage: "cpu", tint: .secondary)
                    Chip(text: alert.kindLabel, tint: alert.severityKind.color)
                    Label(Format.relative(alert.createdAt), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss for this session")
            .accessibilityLabel("Dismiss \(alert.title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: alert.severityKind.color, padding: 14)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Glass confirmation dialog

/// A hand-crafted Liquid Glass confirmation dialog: a dimmed scrim behind a
/// centered frosted card with a title, message, and Cancel / Confirm glass
/// buttons. Used for the reversible "Acknowledge all" action (reference #4).
struct GlassConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    var confirmTint: Color = .accentColor
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.28))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.glass)
                        // Escape must dismiss. Without this the only ways out of
                        // this dialog were the mouse — and it fronts four
                        // destructive confirms (restore a checkpoint, remove a
                        // worktree, stop a service, acknowledge all alerts).
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.glass(tint: confirmTint, prominent: true))
                        // Deliberately NOT `.defaultAction`: Return must never fire
                        // a destructive action just because the dialog appeared.
                        // Same reasoning as CommandConfirmDialog.
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: 380, alignment: .leading)
            .liquidGlass(cornerRadius: 24, prominence: .elevated, padding: 24)
            .padding(40)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .accessibilityAddTraits(.isModal)
    }
}
