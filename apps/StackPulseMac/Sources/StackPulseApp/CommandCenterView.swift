import AppKit
import SwiftUI

/// Two dashboard layouts for the Command Center window.
enum CommandCenterPreset: Hashable, CaseIterable {
    case usage     // usage-forward: big per-provider cards + KPIs
    case mission   // alerts/activity-forward: needs-attention, limits, activity

    var label: String {
        switch self {
        case .usage: return "AI Usage"
        case .mission: return "Mission Control"
        }
    }

    var systemImage: String {
        switch self {
        case .usage: return "chart.bar.fill"
        case .mission: return "dot.radiowaves.left.and.right"
        }
    }

    static var segments: [GlassSegment<CommandCenterPreset>] {
        allCases.map { GlassSegment(value: $0, systemImage: $0.systemImage, label: $0.label) }
    }
}

/// The Command Center dashboard: a dense, second-display monitor over the shared
/// snapshot. Read-only — it never mutates provider data; the only interactions are
/// the preset switch, refresh, display move, and full-screen toggle.
struct CommandCenterView: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onMoveToScreen: (Int) -> Void
    var onToggleFullScreen: () -> Void

    @State private var preset: CommandCenterPreset = .usage

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(WindowBackdrop().ignoresSafeArea())
        .preferredColorScheme(theme.colorScheme)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("Command Center")
                    .font(.title3.weight(.bold))
            }

            GlassSegmentedControl(segments: CommandCenterPreset.segments, selection: $preset)
                .frame(width: 320)

            Spacer()

            meta
            displayMenu

            Button(action: onToggleFullScreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Toggle full screen")

            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isLoading && !reduceMotion ? 360 : 0))
                    .animation(store.isLoading && !reduceMotion
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default, value: store.isLoading)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text("Updated \(Format.relative(store.lastUpdated))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var displayMenu: some View {
        let screens = NSScreen.screens
        if screens.count > 1 {
            Menu {
                ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                    Button {
                        onMoveToScreen(index)
                    } label: {
                        Label(screenName(screen, index: index), systemImage: "display")
                    }
                }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move to a display")
        }
    }

    private func screenName(_ screen: NSScreen, index: Int) -> String {
        let name = screen.localizedName
        return name.isEmpty ? "Display \(index + 1)" : name
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let snapshot = store.snapshot {
            switch preset {
            case .usage: UsageLayout(snapshot: snapshot)
            case .mission: MissionLayout(snapshot: snapshot)
            }
        } else if store.isLoading {
            LoadingStateView()
        } else {
            ErrorStateView(message: store.lastError ?? "No data yet.") { store.refresh() }
        }
    }
}

// MARK: - Usage layout

private struct UsageLayout: View {
    let snapshot: UsageSnapshot
    @EnvironmentObject var store: SnapshotStore

    private var cards: [ProviderUsage] {
        snapshot.installedProviders.filter(\.hasUsageData)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            KPIRow(snapshot: snapshot)

            if cards.isEmpty {
                EmptyStateView(
                    icon: "chart.bar",
                    title: "No usage data yet",
                    message: "Detected providers have no local session history to chart yet."
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360, maximum: 620), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(cards) { provider in
                        BigUsageCard(provider: provider)
                            .environmentObject(store)
                    }
                }
            }

            EstimateFootnote()
        }
    }
}

/// The top KPI band shared by the usage layout.
private struct KPIRow: View {
    let snapshot: UsageSnapshot

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 14
        ) {
            StatTile(label: "30-day est.", value: Format.usd(snapshot.total30Cost),
                     caption: "\(Format.usd(snapshot.totalTodayCost)) today",
                     systemImage: "dollarsign.circle", tint: .green)
            StatTile(label: "Cache saved (30d)", value: Format.usd(snapshot.totalCacheSavings30d),
                     caption: "measured vs. full input rate",
                     systemImage: "bolt.horizontal.circle", tint: .mint)
            StatTile(label: "Burn rate", value: Format.usd(snapshot.totalBurnRate30d),
                     caption: "est. $/active-day", systemImage: "flame", tint: .orange)
            StatTile(label: "Turns (30d)", value: Format.tokens(snapshot.total30Turns),
                     caption: "\(Format.tokens(snapshot.total30Tokens)) tokens",
                     systemImage: "arrow.left.arrow.right")
            StatTile(label: "Cache hit (30d)",
                     value: snapshot.aggregate30CacheHitRate.map { Format.percent($0 * 100) } ?? "—",
                     caption: "read ÷ (read + write)",
                     systemImage: "bolt.horizontal", tint: .cyan)
        }
        .glassCard(padding: 16)
    }
}

/// A large per-provider usage card for the second display.
private struct BigUsageCard: View {
    let provider: ProviderUsage
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .top, spacing: 0) {
                spendCell("Today", provider.today)
                Divider().frame(height: 40)
                spendCell("30 days", provider.last30).padding(.leading, 14)
            }

            if let limit = provider.hottestLimit {
                limitMeter(limit)
            }
            if let cache = provider.last30?.tokens.cacheHitRate {
                meter("Cache hit rate", fraction: cache, tint: .cyan, valueText: Format.percent(cache * 100))
            }

            if let daily = provider.analytics?.daily, daily.contains(where: { $0.tokens.grandTotal > 0 }) {
                Divider().opacity(0.4)
                DailyBarChart(daily: daily, tint: .blue, height: 64)
            }

            if let top = provider.models.max(by: { ($0.estimated_cost_usd ?? -1) < ($1.estimated_cost_usd ?? -1) }) {
                Divider().opacity(0.4)
                HStack(spacing: 6) {
                    Image(systemName: "cpu").imageScale(.small).foregroundStyle(.secondary)
                    Text(top.model).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Format.usd(top.estimated_cost_usd))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(color: SPStatus.healthColor(provider.health))
                .accessibilityLabel(SPStatus.healthLabel(provider.health))
            Text(provider.display_name).font(.title3.weight(.semibold))
            Spacer()
            if let plan = provider.plan_hint {
                Chip(text: plan.capitalized, systemImage: "creditcard", tint: .cyan)
            }
            Chip(text: store.isAuthenticated(provider) ? "Auth" : "No auth",
                 systemImage: store.isAuthenticated(provider) ? "checkmark.seal" : "seal",
                 tint: store.isAuthenticated(provider) ? .green : .secondary)
        }
    }

    private func spendCell(_ label: String, _ window: SpendWindow?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(Format.usd(window?.estimated_cost_usd))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(window.map { "\(Format.tokens($0.tokens.grandTotal)) tok · \($0.records) turns" } ?? "no activity")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func limitMeter(_ limit: LimitWindow) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(limitLabel(limit.label)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(limit.used_percent))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                if let countdown = Format.resetCountdown(limit.resets_at_unix) {
                    Text("· \(countdown)").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            MeterBar(fraction: limit.used_percent / 100,
                     tint: SPStatus.limitColor(limit.used_percent),
                     glowsWhenHigh: true)
        }
    }

    private func meter(_ title: String, fraction: Double, tint: Color, valueText: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(valueText).font(.caption2.weight(.medium).monospacedDigit())
            }
            MeterBar(fraction: fraction, tint: tint)
        }
    }

    private func limitLabel(_ raw: String) -> String {
        switch raw {
        case "5h": return "Session (5h)"
        case "weekly": return "Weekly"
        default: return raw.capitalized
        }
    }
}

// MARK: - Mission Control layout

private struct MissionLayout: View {
    let snapshot: UsageSnapshot
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Prominent, full-width live-activity band above the panel grid.
            LiveActivityPanel().environmentObject(store)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 380, maximum: 720), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 16
            ) {
                NeedsAttentionPanel(snapshot: snapshot).environmentObject(store)
                LiveLimitsPanel(snapshot: snapshot)
                TopModelsPanel(snapshot: snapshot)
                ProviderStatusPanel(snapshot: snapshot).environmentObject(store)
            }
        }
    }
}

/// A prominent live band of AI coding sessions (active + idle), compact rows
/// reused from the Missions section. Headlines the Mission Control preset; shows a
/// calm "nothing running" state when there are none.
private struct LiveActivityPanel: View {
    @EnvironmentObject var store: SnapshotStore

    /// Active and idle sessions — the ones worth watching in real time.
    private var live: [Mission] {
        store.missions.filter { $0.statusKind == .active || $0.statusKind == .idle }
    }

    var body: some View {
        Panel(title: "Live activity",
              systemImage: "waveform.path.ecg",
              tint: store.activeMissionCount > 0 ? .green : .accentColor) {
            if live.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                    Text("No active AI coding sessions right now.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Chip(text: "\(store.activeMissionCount) active", systemImage: "bolt.fill", tint: .green)
                        let idle = live.count - store.activeMissionCount
                        if idle > 0 {
                            Chip(text: "\(idle) idle", systemImage: "pause.circle", tint: .yellow)
                        }
                        Spacer()
                    }
                    ForEach(live) { mission in
                        MissionRow(mission: mission)
                        if mission.id != live.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
    }
}

/// The active needs-attention inbox, as dismissable alert cards.
private struct NeedsAttentionPanel: View {
    let snapshot: UsageSnapshot
    @EnvironmentObject var store: SnapshotStore

    private var active: [Alert] { store.activeAlerts }

    var body: some View {
        Panel(title: "Needs attention",
              systemImage: active.isEmpty ? "checkmark.seal.fill" : "bell.badge",
              tint: active.isEmpty ? .green : (active.map(\.severityKind).max() ?? .info).color) {
            if active.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("All clear — nothing needs your attention.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    ForEach(active) { alert in
                        AlertCard(
                            alert: alert,
                            providerName: displayName(for: alert.provider),
                            onDismiss: { store.acknowledge(alert.id) }
                        )
                    }
                }
            }
        }
    }

    private func displayName(for providerID: String) -> String {
        snapshot.providers.first { $0.provider == providerID }?.display_name ?? providerID.capitalized
    }
}

/// Every live limit across providers, with meters and reset countdowns.
private struct LiveLimitsPanel: View {
    let snapshot: UsageSnapshot

    private var rows: [(String, LimitWindow)] {
        snapshot.installedProviders.flatMap { p in p.limits.map { (p.display_name, $0) } }
    }

    var body: some View {
        Panel(title: "Live limits", systemImage: "gauge.with.needle", tint: .accentColor) {
            if rows.isEmpty {
                Text("No live limits reported by any provider.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(spacing: 3) {
                            HStack {
                                Text(row.0).font(.caption.weight(.semibold))
                                Text(limitLabel(row.1.label)).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(Format.percent(row.1.used_percent))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                if let countdown = Format.resetCountdown(row.1.resets_at_unix) {
                                    Text("· \(countdown)").font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                            MeterBar(fraction: row.1.used_percent / 100,
                                     tint: SPStatus.limitColor(row.1.used_percent),
                                     glowsWhenHigh: true)
                        }
                    }
                }
            }
        }
    }

    private func limitLabel(_ raw: String) -> String {
        switch raw {
        case "5h": return "Session (5h)"
        case "weekly": return "Weekly"
        default: return raw.capitalized
        }
    }
}

/// The costliest models across every provider (30-day scope), ranked.
private struct TopModelsPanel: View {
    let snapshot: UsageSnapshot

    private struct Row: Identifiable {
        let id = UUID()
        let provider: String
        let model: ModelUsage
    }

    private var rows: [Row] {
        let all = snapshot.installedProviders.flatMap { p in
            p.models.map { Row(provider: p.display_name, model: $0) }
        }
        return all
            .sorted { ($0.model.estimated_cost_usd ?? -1) > ($1.model.estimated_cost_usd ?? -1) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        Panel(title: "Top models", systemImage: "cpu", tint: .blue) {
            if rows.isEmpty {
                Text("No per-model usage recorded yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            Text(row.model.model).font(.caption).lineLimit(1).truncationMode(.middle)
                            Chip(text: row.provider, tint: .secondary)
                            Spacer()
                            Text("\(Format.tokens(row.model.tokens.grandTotal)) tok")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(Format.usd(row.model.estimated_cost_usd))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// A compact detection/health/auth strip for every provider.
private struct ProviderStatusPanel: View {
    let snapshot: UsageSnapshot
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        Panel(title: "Providers", systemImage: "square.stack.3d.up", tint: .purple) {
            VStack(spacing: 7) {
                ForEach(snapshot.providers) { p in
                    HStack(spacing: 8) {
                        StatusDot(color: SPStatus.healthColor(p.health))
                            .accessibilityLabel(SPStatus.healthLabel(p.health))
                        Text(p.display_name).font(.caption.weight(.medium))
                        if store.isAuthenticated(p) {
                            Image(systemName: "checkmark.seal.fill")
                                .imageScale(.small).foregroundStyle(.green)
                        }
                        Spacer()
                        Text(p.installed ? SPStatus.healthLabel(p.health) : "Not detected")
                            .font(.system(size: 9))
                            .foregroundStyle(p.installed ? .secondary : .tertiary)
                    }
                }
            }
        }
    }
}

/// A titled glass panel shell used by the Mission Control layout.
private struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }
}
