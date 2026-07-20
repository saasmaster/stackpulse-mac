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
            // These are icon-only, so each needs an explicit label — the `.help`
            // beside it is AX *help* (supplemental, hint-gated), not a name.
            // ``RefreshButton`` carries its own label and disabled state.
            Button(action: { store.sidebarOnLeft.toggle() }) {
                Image(systemName: store.sidebarOnLeft ? "arrow.right.to.line" : "arrow.left.to.line")
            }
            .buttonStyle(.borderless)
            .help(store.sidebarOnLeft ? "Move sidebar to the right edge" : "Move sidebar to the left edge")
            .accessibilityLabel(store.sidebarOnLeft ? "Move sidebar to the right edge" : "Move sidebar to the left edge")
            RefreshButton(isLoading: store.isLoading) { store.refresh() }
                .buttonStyle(.borderless)
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

    /// Fixed head (totals + tab picker), a scrolling body that owns every
    /// remaining point of the panel, then fixed feet (quick nav + meta).
    ///
    /// The panel is as tall as the screen's visible frame (see
    /// ``EdgeSidebarController``), so the old single-ScrollView layout — totals,
    /// tabs, list *and* quick nav all scrolling together, top-aligned — left a
    /// few hundred points of dead glass under the content and floated the nav in
    /// the middle of nowhere. Pinning the chrome lets the list-y tab body take the
    /// height instead: the totals stay readable while you scroll providers, and
    /// the nav never scrolls away.
    @ViewBuilder private var content: some View {
        if let snapshot = store.snapshot {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    summaryStrip(snapshot)
                    tabBar
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch tab {
                        case .cards: cardsTab(snapshot)
                        case .activity: activityTab
                        case .apps: appsTab
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: .infinity)

                Divider().opacity(0.5)
                quickNav
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider().opacity(0.5)
                footer
            }
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

    /// A compact three-cell totals strip: today's spend + volume across all
    /// providers, the same for the 30-day window, and a live status (active
    /// sessions / items needing attention).
    ///
    /// The 30-day cell is the third cell because the two-cell strip left the two
    /// values swimming in ~138pt each — width the panel could spend on a fact it
    /// already has. Both money cells are summed exactly as the Today cell always
    /// was, and both keep its guard: a window nothing reported a cost for reads
    /// "—", never a confident `$0.00`.
    private func summaryStrip(_ snapshot: UsageSnapshot) -> some View {
        let todayCost = snapshot.providers.compactMap { $0.today?.estimated_cost_usd }.reduce(0, +)
        let todayTokens = snapshot.providers.compactMap { $0.today?.tokens.grandTotal }.reduce(0, +)
        let cost30 = snapshot.providers.compactMap { $0.last30?.estimated_cost_usd }.reduce(0, +)
        let tokens30 = snapshot.providers.compactMap { $0.last30?.tokens.grandTotal }.reduce(0, +)
        let active = store.activeMissionCount
        let alerts = store.activeAlerts.count
        return HStack(spacing: 0) {
            sidebarStat(
                "Today (est.)",
                Format.usd(todayCost == 0 ? nil : todayCost),
                "\(Format.tokens(todayTokens)) tokens"
            )
            Divider().frame(height: 34)
            sidebarStat(
                "30d (est.)",
                Format.usd(cost30 == 0 ? nil : cost30),
                "\(Format.tokens(tokens30)) tokens",
                leadingPad: 8
            )
            Divider().frame(height: 34)
            sidebarStat(
                "Live",
                active > 0 ? "▶ \(active)" : "—",
                alerts > 0 ? "\(alerts) to check" : "all clear",
                accent: active > 0 ? .green : .secondary,
                leadingPad: 8
            )
        }
        .glassCard(padding: 10)
        // The strip is the only place the sidebar shows money, and it showed it
        // with nothing saying it was an estimate. "(est.)" is in the cell label
        // itself — so it survives VoiceOver, which a tooltip would not — and the
        // core's full sentence (local price table, list prices, verify against
        // billing) is one hover away rather than three permanently pinned lines
        // of footnote in a 320pt glanceable panel.
        .help(snapshot.pricing_note)
    }

    private func sidebarStat(_ label: String, _ value: String, _ sub: String,
                             accent: Color = .primary,
                             leadingPad: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(accent)
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, leadingPad)
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
    }

    // MARK: Tabs

    /// Cards: the rich condensed per-provider list (the default).
    ///
    /// Only providers with something concrete to say earn a card. A provider the
    /// core merely *detected* has no usage, no limit and no balance, so its card
    /// was a ~37pt slab carrying a dot and a name — and there are several of them
    /// on a real Mac. Those collapse into one wrapped grid instead, which is both
    /// shorter and denser. Scope is unchanged: installed providers only, exactly
    /// as before (the popover, which shows undetected ones too, owns that view).
    @ViewBuilder private func cardsTab(_ snapshot: UsageSnapshot) -> some View {
        let installed = snapshot.installedProviders
        let detailed = installed.filter(\.sidebarHasDetail)
        let quiet = installed.filter { !$0.sidebarHasDetail }
        if installed.isEmpty {
            Text("No providers detected on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } else {
            ForEach(detailed) { provider in
                SidebarProviderRow(provider: provider)
            }
            if !quiet.isEmpty {
                SidebarQuietProvidersCard(providers: quiet)
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
                .accessibilityLabel("Clear app filter")
            }
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(favoritesOnly ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(favoritesOnly ? "Showing favorites only" : "Show favorites only")
            .accessibilityLabel("Favorites only")
            .accessibilityValue(favoritesOnly ? "On" : "Off")
            .accessibilityAddTraits(favoritesOnly ? .isSelected : [])
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
        // 18 here on top of glassCard's own 12 gave the empty state 30pt of
        // padding a side — 60pt of nothing wrapped around ~70pt of content, the
        // tallest thing on the tab when the tab has the least to say.
        .padding(.vertical, 10)
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

private extension ProviderUsage {
    /// True when this provider has anything concrete to put in a sidebar card:
    /// measured tokens or cost, observed sessions, a live limit, or a connected
    /// balance. False ⇒ the core detected it and knows nothing else about it, so
    /// a full card would be a name and a dot in 37pt of glass.
    ///
    /// Deliberately wider than ``ProviderUsage/hasLocalSpend``: that one picks
    /// *which* line to draw (spend vs sessions), this one asks whether there is a
    /// line to draw at all. `hasLocalActivity` is what keeps an activity-only
    /// provider out of the "nothing measured yet" grid — its sessions are measured.
    var sidebarHasDetail: Bool {
        hasLocalSpend
            || hasLocalActivity
            || !limits.isEmpty
            || balance != nil
    }
}

/// The installed-but-quiet providers in one wrapped grid: detected on this Mac,
/// with no usage, no limit and no balance to report. Same idea as the popover's
/// `OtherProvidersCard`, but scoped to what the sidebar shows (installed only),
/// so it never has to quote a "not found" count it wasn't given the data for.
private struct SidebarQuietProvidersCard: View {
    let providers: [ProviderUsage]
    @EnvironmentObject private var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("Detected · nothing measured yet")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(providers.count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(providers) { p in
                    HStack(spacing: 5) {
                        // Health carries "detected" in words, not just in the
                        // dot's colour — same contract as the popover's grid.
                        StatusDot(color: SPStatus.healthColor(p.health), size: 7)
                            .accessibilityLabel(SPStatus.healthLabel(p.health))
                        Text(p.display_name)
                            .font(.caption2)
                            .lineLimit(1)
                        if store.isAuthenticated(p) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                                .accessibilityLabel("Authenticated")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 10)
    }
}

/// One rich condensed provider row for the edge sidebar: health dot, name, spend
/// (omitted entirely when none was measured locally), a metrics line (tokens ·
/// turns · cache, or the compact session count for activity-only providers like
/// Antigravity), and the hottest live limit as a meter.
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
                if provider.hasLocalSpend {
                    Text("\(Format.usd(provider.today?.estimated_cost_usd)) / \(Format.usd(provider.last30?.estimated_cost_usd))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // A connected BYOK provider's real credit balance — already fetched
            // and sitting in the snapshot, previously visible only in the popover.
            if let balance = provider.balance {
                ProviderBalanceLabel(balance: balance)
            }

            metricsLine

            // Both windows, not just the hottest: session (5h) and weekly answer
            // different questions, and this panel is the at-a-glance surface.
            if !provider.limits.isEmpty {
                VStack(spacing: 4) {
                    ForEach(provider.limits) { limit in
                        VStack(spacing: 2) {
                            HStack {
                                Text(limitLabel(limit.label))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Format.limitUsed(limit.used_percent))
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                if let countdown = Format.resetCountdown(limit.resets_at_unix) {
                                    Text("· \(countdown)")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            MeterBar(fraction: Format.limitFraction(limit.used_percent),
                                     tint: SPStatus.limitColor(limit.used_percent),
                                     height: 5,
                                     glowsWhenHigh: true)
                        }
                    }
                    // This panel is open all day, which is exactly how a reading
                    // taken hours ago goes on reading as "right now". The popover
                    // has labelled its limits' age since protocol 1.20.0; this row
                    // rendered the same percentage bare. Draws nothing when the
                    // reading is fresh, so it costs no height in the normal case.
                    if let hottest = provider.hottestLimit {
                        LimitAgeNote(limit: hottest)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 10)
    }

    /// The at-a-glance metrics: tokens · turns · cache for measured providers, or
    /// the shared activity row for activity-only ones (server-side cost, e.g.
    /// Antigravity). `compact` drops the model chip — this panel is 320pt wide.
    @ViewBuilder private var metricsLine: some View {
        if provider.hasLocalSpend {
            HStack(spacing: 10) {
                if let t = provider.today?.tokens.grandTotal, t > 0 {
                    metric("bolt.fill", "\(Format.tokens(t)) today")
                }
                if let turns = provider.today?.records, turns > 0 {
                    metric("arrow.triangle.2.circlepath", "\(turns) turns")
                }
                Spacer(minLength: 0)
            }
        } else if provider.isActivityOnly {
            ProviderActivityRow(provider: provider, compact: true)
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
        Format.limitLabel(raw)
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
