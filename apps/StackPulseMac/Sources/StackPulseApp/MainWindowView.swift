import SwiftUI

// MARK: - Sections

/// The top-level destinations in the main window sidebar.
/// A routable pane. The five **primary** sections (`home`, `usage`, `missions`,
/// `advisor`, `projects`) are what the sidebar shows — each a deep surface that
/// answers one user question. The rest are **internal sub-panes** reused by those
/// composites (e.g. `insights`/`discover`/`stackHealth` live under Advisor;
/// `usage`'s breakdown/`trends`/`reports` under Usage) or reached from chrome
/// (`alerts` from the toolbar bell; `integrations`/`settings` in the Settings
/// window). Keeping them as cases lets each existing view stay the single owner
/// of its own rendering (information hiding) while the nav stays small.
enum MainSection: String, CaseIterable, Identifiable {
    // Primary (sidebar)
    case home
    case launcher
    case usage
    case missions
    case advisor
    case projects
    // Internal sub-panes / chrome
    case alerts
    case insights
    case overview
    case trends
    case reports
    case projectUsage
    case discover
    case stackHealth
    case services
    case integrations
    case settings

    /// The deep sections shown in the sidebar, ordered so related surfaces sit
    /// together: what's happening now (Home), your apps (Launcher → Projects),
    /// your agents (Missions), your numbers (Usage), what to improve (Advisor).
    /// Launcher and Projects are adjacent because they're two views of the same
    /// thing — run it vs. manage it.
    static let primary: [MainSection] = [.home, .launcher, .projects, .missions, .usage, .advisor]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .launcher: return "Launcher"
        case .advisor: return "Advisor"
        case .alerts: return "Needs Attention"
        case .missions: return "Missions"
        case .insights: return "Insights"
        case .overview: return "Overview"
        case .usage: return "Usage"
        case .trends: return "Trends"
        case .reports: return "Reports"
        case .projectUsage: return "By Project"
        case .projects: return "Projects"
        case .discover: return "Discover"
        case .stackHealth: return "Stack Health"
        case .services: return "Services"
        case .integrations: return "Integrations"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .launcher: return "rocket"
        case .advisor: return "sparkles"
        case .alerts: return "bell.badge"
        case .missions: return "bolt.horizontal.circle"
        case .insights: return "lightbulb.max"
        case .overview: return "square.grid.2x2"
        case .usage: return "chart.line.uptrend.xyaxis"
        case .trends: return "chart.xyaxis.line"
        case .reports: return "doc.text"
        case .projectUsage: return "folder.badge.gearshape"
        case .projects: return "folder"
        case .discover: return "sparkle.magnifyingglass"
        case .stackHealth: return "shield.lefthalf.filled"
        case .services: return "server.rack"
        case .integrations: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        }
    }

    /// One-line description shown under the section title.
    var summary: String {
        switch self {
        case .home: return "What's happening right now — today's spend and live limits, active AI sessions, and anything that needs you."
        case .launcher: return "Launch a demo app in one tap — every web app in your folders, with a copy-and-paste command and a shareable URL."
        case .advisor: return "Everything you could improve, in one place — efficiency, your projects, and dependency health & security."
        case .alerts: return "Everything the core flagged as needing attention — usage thresholds, resets, and integration issues."
        case .missions: return "Live AI coding sessions observed on this Mac — what each is working on, right now."
        case .insights: return "Ways to save money and work more efficiently — spotted from your own local usage."
        case .overview: return "At-a-glance spend, volume, and live limits across every detected provider."
        case .usage: return "Where your tokens and money go — per-model and per-window breakdowns, long-run trends, and a shareable report."
        case .trends: return "Long-run spend and token trends across providers, built from durable usage history that outlives the 30-day logs."
        case .projectUsage: return "Which projects your AI spend actually went to — attributed from the working directory each session ran in."
        case .reports: return "A shareable snapshot of your usage, efficiency, projects, and stack — export it as text, Markdown, CSV, or JSON."
        case .projects: return "Your code and what's running — remembered commands, live dev servers, and one-tap web preview."
        case .discover: return "Project-aware, explainable recommendations drawn from your own local projects — what to add, fix, or safely leave alone."
        case .stackHealth: return "Is each project's stack current, compatible, and secure — outdated dependencies, breaking updates, and advisories."
        case .services: return "Dev servers and services running right now — their ports, which project they belong to, and quick actions."
        case .integrations: return "Detection, health, and the capability matrix for each provider."
        case .settings: return "Versions, refresh cadence, cost methodology, and accessibility."
        }
    }
}

// MARK: - Root split view

struct MainWindowView: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager
    @State private var selection: MainSection = .home
    @State private var showingAlerts = false
    @State private var showingOnboarding = false
    /// Set once the first-run flow is finished or skipped (also reset from Settings).
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @Namespace private var navGlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
            applyPendingSection()
            // First run: greet once, explain the trust story, and get folders added.
            if !onboardingCompleted { showingOnboarding = true }
        }
        .onChange(of: store.pendingSection) { applyPendingSection() }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(onFinish: { showingOnboarding = false })
                .environmentObject(store)
        }
    }

    /// Consumes a one-shot navigation request from the store (e.g. the popover's
    /// "Active now" block asking to jump to Missions), then clears it. Runs on
    /// first appear (first open) and on change (subsequent opens of a live window).
    private func applyPendingSection() {
        guard let target = store.pendingSection else { return }
        if reduceMotion {
            selection = target
        } else {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                selection = target
            }
        }
        store.pendingSection = nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                brand
                Spacer()
                alertsBell
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ScrollView {
                // Five deep sections, each answering one user question. No technical
                // "Monitor vs Build" grouping — the labels carry the meaning, and a
                // flat list of five keeps the nav small (low cognitive load).
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(MainSection.primary) { navRow($0) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Divider().opacity(0.4)
                Button {
                    NotificationCenter.default.post(name: .stackPulseOpenSettings, object: nil)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("Settings")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("⌘,")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .help("Open the Settings window (⌘,)")

                sidebarFooter
            }
        }
        .background(WindowBackdrop().ignoresSafeArea())
    }

    /// A single navigation row. The selected row is a glazed accent-tinted glass
    /// capsule with a colored glow; the glow slides between rows on selection
    /// (matchedGeometryEffect, spring — skipped under Reduce Motion). Unselected
    /// rows stay quiet.
    @ViewBuilder private func navRow(_ section: MainSection) -> some View {
        let isSelected = selection == section
        let badge = badge(for: section)
        Button {
            if reduceMotion {
                selection = section
            } else {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                    selection = section
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                Text(section.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Spacer(minLength: 4)
                if badge.count > 0 {
                    Text("\(badge.count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(badge.color))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    Color.clear
                        .liquidGlass(cornerRadius: 10, prominence: .elevated,
                                     tint: .accentColor, padding: 0)
                        .matchedGeometryEffect(id: "sidebarSelection", in: navGlow)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Count badge for a sidebar row: Missions shows active AI coding sessions
    /// (green); Advisor shows how many improvements are waiting (blue) — efficiency
    /// insights plus repository-radar recommendations. Needs-attention lives in the
    /// toolbar bell, not a nav row.
    private func badge(for section: MainSection) -> (count: Int, color: Color) {
        switch section {
        case .missions: return (store.activeMissionCount, .green)
        case .advisor:
            return (store.insights.count + (store.radar?.recommendations.count ?? 0), .blue)
        default: return (0, .clear)
        }
    }

    /// A bell in the sidebar header that opens the needs-attention inbox as a
    /// popover (it's cross-cutting chrome, not a peer section). Red badge = count.
    private var alertsBell: some View {
        let count = store.activeAlerts.count
        return Button { showingAlerts.toggle() } label: {
            Image(systemName: count > 0 ? "bell.badge" : "bell")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(count > 0 ? Color.red : Color.secondary)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 9, y: -7)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(count > 0 ? "Needs attention — \(count) to check" : "Needs attention")
        .accessibilityLabel(count > 0 ? "Needs attention, \(count) items" : "Needs attention")
        .popover(isPresented: $showingAlerts, arrowEdge: .bottom) {
            AlertsInboxPopover().environmentObject(store)
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text("StackPulse")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 6)
        .textCase(nil)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().opacity(0.4)
            HStack(spacing: 6) {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                } else if let providers = store.snapshot?.providers {
                    let detected = providers.filter(\.installed).count
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("\(detected) of \(providers.count) detected")
                } else {
                    Image(systemName: "clock")
                    Text("No data yet")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .padding(.top, 2)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        // Primary, deep sections.
        case .home: HomeSection(onOpen: { store.pendingSection = $0 })
        case .launcher: LauncherSection()
        case .usage: UsageHubSection()
        case .missions: MissionsSection()
        case .advisor: AdvisorSection()
        case .projects: ProjectsSection()
        // Internal sub-panes (reached via a composite's sub-tabs) and chrome.
        case .alerts: AlertsSection()
        case .insights: InsightsSection()
        case .overview: OverviewSection()
        case .trends: TrendsSection()
        case .reports: ReportsSection()
        case .projectUsage: ProjectUsageSection()
        case .discover: DiscoverSection()
        case .stackHealth: StackHealthSection()
        case .services: ServicesSection()
        case .integrations: IntegrationsSection()
        case .settings: SettingsSection()
        }
    }
}

// MARK: - Needs-attention inbox (toolbar bell popover)

/// A compact needs-attention inbox shown from the sidebar bell. Reuses the same
/// alert rendering as the sidebar; a fixed frame keeps it popover-sized.
struct AlertsInboxPopover: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge").foregroundStyle(.red)
                Text("Needs Attention").font(.headline)
                Spacer()
                Text("\(store.activeAlerts.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if store.activeAlerts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.largeTitle).foregroundStyle(.green)
                    Text("All clear").font(.subheadline.weight(.semibold))
                    Text("Nothing needs your attention right now.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    NeedsAttentionBlock(alerts: store.activeAlerts, maxItems: 20, onTap: nil)
                }
            }
        }
        .padding(14)
        .frame(width: 380, height: 460)
    }
}

// MARK: - Section scaffold (owns loading / empty / error states)

/// Shared container every section renders through: consistent header, spacing,
/// scrolling, backdrop, and the four global states (loading / error / no-data /
/// no-providers). The section's own content closure only runs once a snapshot
/// with at least one provider is available.
struct SectionScaffold<Content: View>: View {
    let section: MainSection
    @EnvironmentObject var store: SnapshotStore
    @ViewBuilder var content: (UsageSnapshot) -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: section.title, summary: section.summary)
                stateBody
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackdrop().ignoresSafeArea())
    }

    @ViewBuilder private var stateBody: some View {
        if let snapshot = store.snapshot {
            if snapshot.providers.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "No providers detected",
                    message: "StackPulse didn't find any supported AI tools on this Mac yet."
                )
            } else {
                content(snapshot)
            }
        } else if store.isLoading {
            LoadingStateView()
        } else {
            ErrorStateView(message: store.lastError ?? "No data yet.") {
                store.refresh()
            }
        }
    }
}

// MARK: - Shared header / meta

struct SectionHeader: View {
    let title: String
    let summary: String
    @EnvironmentObject var store: SnapshotStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { store.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isLoading && !reduceMotion ? 360 : 0))
                        .animation(store.isLoading && !reduceMotion
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default, value: store.isLoading)
                }
                .controlSize(.large)
                .help("Refresh now")
                .disabled(store.isLoading)
            }
            SnapshotMetaBar()
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "Updated · UTC bucket · loading" line shared by every section header.
struct SnapshotMetaBar: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        HStack(spacing: 8) {
            Label("Updated \(Format.relative(store.lastUpdated))", systemImage: "clock.arrow.circlepath")
            if let snapshot = store.snapshot {
                Text("·").foregroundStyle(.tertiary)
                Label("UTC \(snapshot.bucket_date_utc)", systemImage: "calendar")
            }
            if store.isLoading {
                Text("·").foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("refreshing")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Shared state views

struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading your local session logs…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .glassCard(padding: 24)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .glassCard(padding: 24)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .glassCard(padding: 24)
    }
}

/// Card shown for a provider that isn't installed on this Mac.
struct NotDetectedCard: View {
    let provider: ProviderUsage

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: SPStatus.healthColor(provider.health))
                .accessibilityLabel(SPStatus.healthLabel(provider.health))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.display_name).font(.subheadline.weight(.semibold))
                Text("Not detected on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: "Not installed", systemImage: "questionmark.circle", tint: .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Shared metric tiles

/// A single labelled statistic, optionally with a caption and an accent tint.
struct StatTile: View {
    let label: String
    let value: String
    var caption: String? = nil
    var systemImage: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Footnote clarifying that costs are list-price estimates, never billed amounts.
struct EstimateFootnote: View {
    var body: some View {
        Label(
            "Costs are estimated list-price equivalents from a local price table — not the amount billed to you (subscriptions bill a flat fee).",
            systemImage: "info.circle"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Window backdrop

/// A subtle scheme-aware backdrop giving the glass cards something to float on:
/// a vertical base gradient with two soft ambient color washes (cool violet +
/// blue in dark, pearl-white + faint blue in light) for depth. Collapses to a
/// flat surface under Reduce Transparency. Shared by the popover, main window,
/// and edge sidebar so every panel reads as the same material.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            (scheme == .dark ? Color(white: 0.11) : Color(white: 0.95))
        } else {
            ZStack {
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color(white: 0.13), Color(white: 0.085)]
                        : [Color(white: 0.985), Color(white: 0.93)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Top-leading ambient wash (violet in dark, pearl in light).
                RadialGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.42, green: 0.36, blue: 0.85).opacity(0.20), .clear]
                        : [Color(red: 0.55, green: 0.55, blue: 0.95).opacity(0.10), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 520
                )
                // Bottom-trailing ambient wash (blue).
                RadialGradient(
                    colors: scheme == .dark
                        ? [Color(red: 0.20, green: 0.48, blue: 0.90).opacity(0.16), .clear]
                        : [Color(red: 0.45, green: 0.62, blue: 0.95).opacity(0.08), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 560
                )
            }
        }
    }
}

// MARK: - Aggregation helpers (view layer)

extension UsageSnapshot {
    /// Providers actually present on this Mac.
    var installedProviders: [ProviderUsage] {
        providers.filter(\.installed)
    }

    /// Sum of 30-day estimated cost across providers (nil if none have pricing).
    var total30Cost: Double? {
        let values = providers.compactMap { $0.last30?.estimated_cost_usd }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Sum of today's estimated cost across providers.
    var totalTodayCost: Double? {
        let values = providers.compactMap { $0.today?.estimated_cost_usd }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Total turns (records) over the last 30 days across providers.
    var total30Turns: UInt64 {
        providers.compactMap { $0.last30?.records }.reduce(0, +)
    }

    /// Combined 30-day cache-hit rate across providers, or nil if no cache use.
    var aggregate30CacheHitRate: Double? {
        var read: UInt64 = 0
        var creation: UInt64 = 0
        for provider in providers {
            if let tokens = provider.last30?.tokens {
                read += tokens.cache_read_tokens
                creation += tokens.cache_creation_tokens
            }
        }
        let denom = Double(read + creation)
        return denom == 0 ? nil : Double(read) / denom
    }

    /// Total 30-day token volume across providers.
    var total30Tokens: UInt64 {
        providers.compactMap { $0.last30?.tokens.grandTotal }.reduce(0, +)
    }

    /// Measured 30-day cache savings summed across providers (nil if none report it).
    var totalCacheSavings30d: Double? {
        let values = providers.compactMap { $0.analytics?.cache_savings_usd }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Combined estimated spend per active day: the sum of each provider's
    /// per-active-day burn rate (nil if no provider reports one).
    var totalBurnRate30d: Double? {
        let values = providers.compactMap { $0.analytics?.burn_rate_usd_per_day }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

extension ProviderUsage {
    /// The live limit closest to its cap, if any.
    var hottestLimit: LimitWindow? {
        limits.max(by: { $0.used_percent < $1.used_percent })
    }

    /// Spend windows in canonical display order, skipping any the core omitted.
    var orderedWindows: [SpendWindow] {
        ["today", "yesterday", "last_30_days"].compactMap { window($0) }
    }
}
