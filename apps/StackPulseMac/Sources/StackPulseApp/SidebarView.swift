import SwiftUI

/// The always-available edge sidebar content: a compact totals strip, live
/// activity + needs-attention, then a rich condensed per-provider list. Shares
/// the app's single ``SnapshotStore``. Hosted by ``EdgeSidebarController`` in a
/// non-activating floating panel pinned to either screen edge.
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
            // Quick toggle: flip the sidebar to the other screen edge live.
            Button(action: { store.sidebarOnLeft.toggle() }) {
                Image(systemName: store.sidebarOnLeft ? "arrow.right.to.line" : "arrow.left.to.line")
            }
            .buttonStyle(.borderless)
            .help(store.sidebarOnLeft ? "Move sidebar to the right edge" : "Move sidebar to the left edge")
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
                    summaryStrip(snapshot)

                    ActiveNowBlock(missions: store.activeMissions, maxItems: 3,
                                   onTap: onOpenMainWindow)
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

    /// A compact two-cell totals strip: today's spend + volume across all
    /// providers, and a live status (active sessions / items needing attention).
    private func summaryStrip(_ snapshot: UsageSnapshot) -> some View {
        let todayCost = snapshot.providers.compactMap { $0.today?.estimated_cost_usd }.reduce(0, +)
        let todayTokens = snapshot.providers.compactMap { $0.today?.tokens.grandTotal }.reduce(0, +)
        let active = store.activeMissionCount
        let alerts = store.activeAlerts.count
        return HStack(spacing: 0) {
            sidebarStat(
                "Today",
                Format.usd(todayCost == 0 ? nil : todayCost),
                "\(Format.tokens(todayTokens)) tokens"
            )
            Divider().frame(height: 34)
            sidebarStat(
                "Live",
                active > 0 ? "▶ \(active)" : "—",
                alerts > 0 ? "\(alerts) to check" : "all clear",
                accent: active > 0 ? .green : .secondary
            )
        }
        .glassCard(padding: 10)
    }

    private func sidebarStat(_ label: String, _ value: String, _ sub: String,
                             accent: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(accent)
            Text(sub)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, label == "Live" ? 12 : 0)
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

/// One rich condensed provider row for the edge sidebar: health dot, name, spend
/// (or a server-side note), a metrics line (tokens · turns · cache, or sessions ·
/// model for activity-only providers like Antigravity), and the hottest live
/// limit as a meter.
private struct SidebarProviderRow: View {
    let provider: ProviderUsage

    /// True when the core measured real token/cost usage locally (Claude/Codex).
    private var hasSpend: Bool {
        (provider.today?.tokens.grandTotal ?? 0) > 0
            || (provider.last30?.tokens.grandTotal ?? 0) > 0
            || (provider.today?.estimated_cost_usd ?? 0) > 0
            || (provider.last30?.estimated_cost_usd ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: SPStatus.healthColor(provider.health))
                    .accessibilityLabel(SPStatus.healthLabel(provider.health))
                Text(provider.display_name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if hasSpend {
                    Text("\(Format.usd(provider.today?.estimated_cost_usd)) / \(Format.usd(provider.last30?.estimated_cost_usd))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            metricsLine

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

    /// The at-a-glance metrics: tokens · turns · cache for measured providers, or
    /// sessions · model for activity-only ones (server-side cost, e.g. Antigravity).
    @ViewBuilder private var metricsLine: some View {
        if hasSpend {
            HStack(spacing: 10) {
                if let t = provider.today?.tokens.grandTotal, t > 0 {
                    metric("bolt.fill", "\(Format.tokens(t)) today")
                }
                if let turns = provider.today?.records, turns > 0 {
                    metric("arrow.triangle.2.circlepath", "\(turns) turns")
                }
                if let hit = provider.analytics?.cache_hit_rate {
                    metric("square.stack.3d.up", "\(Int((hit * 100).rounded()))% cache")
                }
                Spacer(minLength: 0)
            }
        } else if let sessions = provider.last30?.records, sessions > 0 {
            HStack(spacing: 10) {
                metric("bubble.left.and.text.bubble.right", "\(sessions) session\(sessions == 1 ? "" : "s")")
                if let model = provider.models.first?.model {
                    metric("cpu", model)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 9)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private func limitLabel(_ raw: String) -> String {
        switch raw {
        case "5h": return "Session (5h)"
        case "weekly": return "Weekly"
        default: return raw.capitalized
        }
    }
}
