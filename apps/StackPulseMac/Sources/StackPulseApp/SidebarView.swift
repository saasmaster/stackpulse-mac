import SwiftUI

/// The always-available edge sidebar content: a needs-attention summary on top
/// of a condensed per-provider health list. Shares the app's single
/// ``SnapshotStore``. Hosted by ``EdgeSidebarController`` in a non-activating
/// floating panel pinned to the right screen edge.
struct SidebarView: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager
    /// Hide the panel (wired to the controller).
    var onClose: (() -> Void)? = nil
    /// Open the full main window / inbox.
    var onOpenMainWindow: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowBackdrop().ignoresSafeArea())
        .preferredColorScheme(theme.colorScheme)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
            Text("StackPulse")
                .font(.headline)
            Spacer()
            if store.keepAwake {
                Image(systemName: "cup.and.saucer.fill")
                    .imageScale(.small)
                    .foregroundStyle(.yellow)
                    .help("Keep Awake is on")
                    .accessibilityLabel("Keep Awake is on")
            }
            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(store.isLoading)
            if onClose != nil {
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide sidebar")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let snapshot = store.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    NeedsAttentionBlock(alerts: store.activeAlerts, maxItems: 3,
                                        onTap: onOpenMainWindow)

                    ForEach(snapshot.installedProviders) { provider in
                        SidebarProviderRow(provider: provider)
                    }

                    if snapshot.installedProviders.isEmpty {
                        Text("No providers detected on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                .padding(12)
            }
            footer
        } else if store.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Scanning…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(.orange)
                Text(store.lastError ?? "No data yet").font(.callout)
                Button("Try again") { store.refresh() }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var footer: some View {
        HStack {
            Text("Updated \(Format.relative(store.lastUpdated))")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            if onOpenMainWindow != nil {
                Button(action: { onOpenMainWindow?() }) {
                    Label("Open", systemImage: "macwindow")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One condensed provider row for the edge sidebar: health dot, name, today /
/// 30-day cost, and the hottest live limit as a meter.
private struct SidebarProviderRow: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: SPStatus.healthColor(provider.health))
                    .accessibilityLabel(SPStatus.healthLabel(provider.health))
                Text(provider.display_name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(Format.usd(provider.today?.estimated_cost_usd)) / \(Format.usd(provider.last30?.estimated_cost_usd))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let limit = provider.hottestLimit {
                VStack(spacing: 2) {
                    HStack {
                        Text(limitLabel(limit.label))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.percent(limit.used_percent))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                        if let countdown = Format.resetCountdown(limit.resets_at_unix) {
                            Text("· \(countdown)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    MeterBar(fraction: limit.used_percent / 100,
                             tint: SPStatus.limitColor(limit.used_percent),
                             height: 5,
                             glowsWhenHigh: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 10)
    }

    private func limitLabel(_ raw: String) -> String {
        switch raw {
        case "5h": return "Session (5h)"
        case "weekly": return "Weekly"
        default: return raw.capitalized
        }
    }
}
