import SwiftUI

/// The always-available edge sidebar content: a compact totals strip, live
/// activity + needs-attention, then a rich condensed per-provider list. Shares
/// the app's single ``SnapshotStore``. Hosted by ``EdgeSidebarController`` in a
/// non-activating floating panel pinned to either screen edge.
/// Which slice of the sidebar is showing. Persisted across launches so the
/// sidebar reopens on the tab you left it on.
enum SidebarTab: String, CaseIterable {
    case cards, activity, apps

    var label: String {
        switch self {
        case .cards: return "Cards"
        case .activity: return "Live"
        case .apps: return "Apps"
        }
    }

    var systemImage: String {
        switch self {
        case .cards: return "rectangle.stack"
        case .activity: return "bolt.horizontal"
        case .apps: return "rocket"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager
    /// Hide the panel (wired to the controller).
    var onClose: (() -> Void)? = nil
    /// Open the full main window / inbox.
    var onOpenMainWindow: (() -> Void)? = nil

    @AppStorage("sidebar.tab") private var tabRaw: String = SidebarTab.cards.rawValue
    /// Apps-tab filter text and favorites-only toggle.
    @State private var appQuery = ""
    @State private var favoritesOnly = false
    private var tab: SidebarTab {
        get { SidebarTab(rawValue: tabRaw) ?? .cards }
        nonmutating set { tabRaw = newValue.rawValue }
    }

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
            // These three are icon-only, so each needs an explicit label — the
            // `.help` beside it is AX *help* (supplemental, hint-gated), not a name.
            Button(action: { store.sidebarOnLeft.toggle() }) {
                Image(systemName: store.sidebarOnLeft ? "arrow.right.to.line" : "arrow.left.to.line")
            }
            .buttonStyle(.borderless)
            .help(store.sidebarOnLeft ? "Move sidebar to the right edge" : "Move sidebar to the left edge")
            .accessibilityLabel(store.sidebarOnLeft ? "Move sidebar to the right edge" : "Move sidebar to the left edge")
            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .accessibilityLabel("Refresh now")
            .disabled(store.isLoading)
            if onClose != nil {
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide sidebar")
                .accessibilityLabel("Hide sidebar")
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
                    tabBar

                    switch tab {
                    case .cards: cardsTab(snapshot)
                    case .activity: activityTab
                    case .apps: appsTab
                    }

                    quickNav
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

    // MARK: Tab bar

    /// A frosted segmented control switching the sidebar between its provider
    /// cards, live activity, and web-preview views.
    private var tabBar: some View {
        GlassSegmentedControl(
            segments: SidebarTab.allCases.map {
                GlassSegment(value: $0, systemImage: $0.systemImage, label: $0.label)
            },
            selection: Binding(get: { tab }, set: { tab = $0 })
        )
        .font(.caption)
    }

    // MARK: Tabs

    /// Cards: the rich condensed per-provider list (the default).
    @ViewBuilder private func cardsTab(_ snapshot: UsageSnapshot) -> some View {
        if snapshot.installedProviders.isEmpty {
            Text("No providers detected on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } else {
            ForEach(snapshot.installedProviders) { provider in
                SidebarProviderRow(provider: provider)
            }
        }
    }

    /// Activity: current AI coding sessions and anything needing attention, with
    /// more room than the always-on cards tab affords.
    @ViewBuilder private var activityTab: some View {
        ActiveNowBlock(missions: store.activeMissions, maxItems: 6,
                       onTap: onOpenMainWindow)
        NeedsAttentionBlock(alerts: store.activeAlerts, maxItems: 6,
                            onTap: onOpenMainWindow)
        if store.activeMissions.isEmpty && store.activeAlerts.isEmpty {
            sidebarEmpty("checkmark.circle", "Nothing needs you right now",
                         "Active coding sessions and alerts show up here.")
        }
    }

    /// Apps: every launchable web project — favorites pinned on top, filterable —
    /// each with a one-paste **Copy** command and a **Launch** (or **Open** when
    /// running). A mini Launcher right in the edge sidebar.
    private var appsTab: some View {
        let all = store.projects.filter(WebPreview.isLaunchable)
        let filtered = store.favoritesFirst(all.filter { p in
            (appQuery.isEmpty || p.name.localizedCaseInsensitiveContains(appQuery))
                && (!favoritesOnly || store.isFavorite(p.path))
        })
        return VStack(alignment: .leading, spacing: 8) {
            if all.isEmpty {
                sidebarEmpty("rocket", "No apps yet",
                             "Add a project folder in Projects — your apps show up here to launch.")
                Button {
                    store.pendingSection = .launcher
                    onOpenMainWindow?()
                } label: {
                    Label("Open Launcher", systemImage: "rocket")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass(tint: .accentColor))
            } else {
                appsFilterBar
                if filtered.isEmpty {
                    Text(favoritesOnly ? "No favorites yet — tap a star to pin one." : "No apps match “\(appQuery)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(filtered) { project in
                        SidebarAppRow(project: project)
                    }
                }
            }
        }
        .onAppear {
            if store.projects.isEmpty && !store.approvedRoots.isEmpty { store.rescanProjects() }
            store.rescanServices()
        }
    }

    /// A compact filter row: a name search field and a favorites-only toggle.
    private var appsFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
            TextField("Filter apps", text: $appQuery)
                .textFieldStyle(.plain)
                .font(.caption)
            if !appQuery.isEmpty {
                Button { appQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(favoritesOnly ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(favoritesOnly ? "Showing favorites only" : "Show favorites only")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .liquidGlass(cornerRadius: 8, prominence: .low, padding: 0)
    }

    private func sidebarEmpty(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassCard(padding: 12)
    }

    /// A compact launcher so the side card jumps straight into the useful main
    /// sections — the dashboards/analytics live one tap away, not buried behind
    /// the Settings gear.
    private static let quickSections: [MainSection] = MainSection.primary

    private var quickNav: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OPEN IN APP")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 86), spacing: 6)],
                spacing: 6
            ) {
                ForEach(Self.quickSections) { section in
                    Button {
                        store.pendingSection = section
                        onOpenMainWindow?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 10))
                                .foregroundStyle(.tint)
                            Text(section.title)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlass(cornerRadius: 9, prominence: .low, padding: 0)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(section.title)")
                }
            }
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

/// A compact launchable-app row for the sidebar Apps tab: a favorite star, the
/// project name (green dot when running), a one-paste **Copy command**, and
/// **Launch** (or **Open** when a matching dev server is running). The full recipe
/// (which reads `package.json`) is resolved only when tapped, so the list stays
/// cheap to render.
private struct SidebarAppRow: View {
    let project: Project
    @EnvironmentObject private var store: SnapshotStore
    @State private var copied = false

    private var liveURL: String? { WebPreview.runningURL(for: project, among: store.services) }
    private var isFavorite: Bool { store.isFavorite(project.path) }

    var body: some View {
        HStack(spacing: 6) {
            Button { store.toggleFavorite(project.path) } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Unpin" : "Pin to top")

            if liveURL != nil {
                StatusDot(color: .green).accessibilityLabel("running")
            }
            Text(project.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            Button(action: copyCommand) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2)
            }
            .buttonStyle(.glass)
            .help("Copy the one-paste launch command")

            if let live = liveURL {
                Button { WebPreview.open(live) } label: {
                    Image(systemName: "arrow.up.right.square").font(.caption2)
                }
                .buttonStyle(.glass(tint: .accentColor))
                .help("Open \(live)")
            } else {
                Button(action: launch) {
                    Image(systemName: "play.fill").font(.caption2)
                }
                .buttonStyle(.glass(tint: .blue))
                .help("Launch \(project.name) and open it when ready")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 8)
    }

    /// Resolve the recipe on demand (reads node_modules + package.json once, on tap).
    private func recipe() -> WebPreview.Recipe? {
        let installed = FileManager.default.fileExists(
            atPath: (project.path as NSString).appendingPathComponent("node_modules"))
        return WebPreview.recipe(for: project, installNeeded: !installed)
    }

    private func launch() {
        if let recipe = recipe() { WebPreview.launch(recipe) }
    }

    private func copyCommand() {
        guard let recipe = recipe() else { return }
        CommandRunner.copy(recipe.oneLiner)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
    }
}
