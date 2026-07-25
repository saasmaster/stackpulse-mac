import SwiftUI

/// The menu-bar popover: the Phase-0/1 "immediate status" surface.
struct PopoverView: View {
    /// Invoked to open the full main window (wired to `AppDelegate`).
    var onOpenMainWindow: (() -> Void)? = nil
    /// Invoked to show/hide the edge sidebar (wired to `AppDelegate`).
    var onToggleSidebar: (() -> Void)? = nil
    /// Invoked to open the Command Center monitoring window (wired to `AppDelegate`).
    var onOpenCommandCenter: (() -> Void)? = nil
    /// Invoked to open the main window on its Settings section (wired to `AppDelegate`).
    var onOpenSettings: (() -> Void)? = nil

    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        // A DEFINITE height — a ScrollView inside an NSPopover reports no natural
        // height, so `maxHeight` alone leaves the popover collapsed. A fixed
        // height makes the popover tall and lets `content` scroll inside it.
        .frame(width: 360, height: 760)
        .background(backdrop)
        .preferredColorScheme(theme.colorScheme)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("StackPulse").font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(subtitleTooltip)
            }
            Spacer()
            if onToggleSidebar != nil {
                Button(action: { onToggleSidebar?() }) {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("Toggle edge sidebar (⌥⌘S)")
                .accessibilityLabel("Toggle edge sidebar")
            }
            if onOpenMainWindow != nil {
                Button(action: {
                    // "Open" lands on the Home dashboard (the useful info),
                    // not wherever the window was last left (e.g. Settings).
                    store.pendingSection = .home
                    onOpenMainWindow?()
                }) {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Open StackPulse — dashboard")
                .accessibilityLabel("Open StackPulse dashboard")
            }
            if onOpenCommandCenter != nil {
                Button(action: { onOpenCommandCenter?() }) {
                    CommandCenterIcon()
                }
                .buttonStyle(.borderless)
                .help("Open Command Center (⌘⇧C)")
                .accessibilityLabel("Open Command Center")
            }
            RefreshButton(isLoading: store.isLoading) { store.refresh() }
                .buttonStyle(.borderless)
            // Settings sits last, at the right edge: it is the least-used control
            // in this row.
            if onOpenSettings != nil {
                Button(action: { onOpenSettings?() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Open Settings (⌘,)")
                .accessibilityLabel("Open Settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// One short line. The UTC bucket date used to hang off this and wrapped the
    /// header onto a second line in a 360pt popover — it's the accounting day the
    /// numbers belong to, which matters when reading them but not at a glance, so
    /// it moved to the header's tooltip.
    private var subtitle: String {
        if store.isLoading && store.snapshot == nil { return "Scanning local sessions…" }
        return "Updated \(Format.relative(store.lastUpdated))"
    }

    /// The detail the subtitle no longer spends a line on.
    private var subtitleTooltip: String {
        guard let s = store.snapshot else { return "" }
        return "Usage is bucketed by UTC day — currently \(s.bucket_date_utc)"
    }

    // MARK: Content states

    @ViewBuilder private var content: some View {
        if let snapshot = store.snapshot {
            // See `warrantsOwnCard`: usage data, a BYOK balance, or simply being
            // installed. The last one matters — a provider the user is signed into
            // but which reports nothing locally used to collapse in with the ones
            // they don't even have.
            let active = snapshot.providers.filter(\.warrantsOwnCard)
            let others = snapshot.providers.filter { !$0.warrantsOwnCard }
            ScrollView {
                VStack(spacing: 10) {
                    DemoBanner()
                    ActiveNowBlock(missions: store.activeMissions, maxItems: 3) {
                        // Jump the main window straight to the Missions section.
                        store.pendingSection = .missions
                        onOpenMainWindow?()
                    }
                    NeedsAttentionBlock(alerts: store.activeAlerts, maxItems: 3,
                                        onTap: onOpenMainWindow)
                    // Full cards for providers with real usage; the rest (detected
                    // but unscanned, or not detected) collapse into one compact
                    // card so all ten stay visible at a glance.
                    ForEach(active) { provider in
                        ProviderCard(provider: provider)
                            .environmentObject(store)
                    }
                    if !others.isEmpty {
                        OtherProvidersCard(providers: others, onOpenMainWindow: onOpenMainWindow)
                            .environmentObject(store)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
        } else if store.isLoading {
            loadingState
        } else {
            errorState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading your Claude & Codex sessions…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var errorState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2).foregroundStyle(.orange)
            Text(store.lastError ?? "No data yet").font(.callout)
            Button("Try again") { store.refresh() }.buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            if let note = store.snapshot?.pricing_note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if onOpenMainWindow != nil {
                Button(action: { onOpenMainWindow?() }) {
                    Label("Open StackPulse", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
            }
            HStack(spacing: 8) {
                if let s = store.snapshot {
                    Text("core \(s.core_version) · protocol \(s.protocol_version.text)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    store.keepAwake.toggle()
                } label: {
                    Label(store.keepAwake ? "Awake" : "Keep awake",
                          systemImage: store.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.glass(tint: store.keepAwake ? .yellow : .secondary))
                .help(store.keepAwake
                    ? "Keeping this Mac awake for monitoring — click to stop"
                    : "Prevent system sleep while monitoring")
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var backdrop: some View {
        // The popover already vibrancy-blurs; layer the shared ambient wash for
        // depth so the glass cards have something to float on.
        WindowBackdrop().ignoresSafeArea()
    }
}

/// A compact "Active now" block for the top of the popover: a live header, then
/// up to `maxItems` active sessions as "project — last activity", with a "+N more"
/// overflow. Tapping anywhere opens the main window's Missions section. Renders
/// nothing when there are no active sessions, so it can be dropped in
/// unconditionally.
struct ActiveNowBlock: View {
    let missions: [Mission]
    var maxItems: Int = 3
    var onTap: (() -> Void)? = nil

    private var shown: [Mission] { Array(missions.prefix(maxItems)) }
    private var overflow: Int { max(0, missions.count - maxItems) }

    var body: some View {
        if !missions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    MissionPulseDot(status: .active)
                    Text("Active now")
                        .font(.subheadline.weight(.semibold))
                    Chip(text: "\(missions.count)", tint: .green)
                    Spacer()
                    if onTap != nil {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { mission in
                        HStack(spacing: 8) {
                            StatusDot(color: .green, size: 7)
                                .accessibilityHidden(true)
                            Text(mission.projectLabel)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text("—").font(.caption2).foregroundStyle(.tertiary)
                            Text(mission.last_activity ?? "working")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(mission.projectLabel): \(mission.last_activity ?? "working")")
                    }
                }

                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: 16, tint: .green, padding: 12)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .help(onTap == nil ? "" : "Open the Missions section")
            // See NeedsAttentionBlock: traits + action keep the per-mission rows
            // separately readable, which a wrapping Button would collapse.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Active now: \(missions.count) AI coding session\(missions.count == 1 ? "" : "s")")
            .accessibilityAddTraits(onTap == nil ? [] : .isButton)
            .accessibilityAction { onTap?() }
        }
    }
}

/// One provider's card: identity, health, spend windows, limits, cache, model.
struct ProviderCard: View {
    let provider: ProviderUsage
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        // 6, not 8: at 360pt wide this card stacks 4-6 rows, so every point of
        // inter-row spacing is multiplied per provider — and the popover's job is
        // to show several providers at once, not one beautifully.
        VStack(alignment: .leading, spacing: 6) {
            identityRow
            if let balance = provider.balance {
                ProviderBalanceLabel(balance: balance)
            }
            if provider.installed {
                // Providers the core prices locally (Claude/Codex) get the spend
                // row. Activity-only providers (Antigravity) get a session/model
                // row: a spend cell would print "0 tok", and a zero read as
                // measured is a fabrication — the count was never published here.
                // The server-side reason arrives with `provider.notes` below, so
                // no `NoLocalSpendNote` here.
                if provider.hasLocalSpend {
                    spendRow
                } else if provider.hasLocalActivity {
                    ProviderActivityRow(provider: provider)
                }
                if !provider.limits.isEmpty { limitsSection }
                liveLimitsNote
                if provider.hasLocalSpend, let top = provider.models.first { topModelRow(top) }
            } else if provider.balance == nil {
                Text("Not detected on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Clamped, not shortened. These notes carry the honest "why" (server-side
            // metering, unpriced models) and must not be edited down to a slogan —
            // but at 360pt a two-paragraph note ran five lines and pushed the next
            // provider off screen. Two lines here, the whole text on hover.
            ForEach(provider.notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var identityRow: some View {
        HStack(spacing: 8) {
            StatusDot(color: SPStatus.healthColor(provider.health))
                .accessibilityLabel(SPStatus.healthLabel(provider.health))
            Text(provider.display_name).font(.subheadline.weight(.semibold))
            if let v = provider.detected_version {
                Text("v\(v)").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            if let plan = provider.plan_hint {
                Chip(text: plan.capitalized, systemImage: "creditcard", tint: .cyan)
            }
            if provider.balance != nil {
                // A stored API key / balance reads as Connected (supersedes the
                // core's file-based auth chip, which is "No auth" for BYOK providers).
                Chip(text: "Connected", systemImage: "checkmark.seal.fill", tint: .green)
            } else {
                Chip(text: store.isAuthenticated(provider) ? "Auth" : "No auth",
                     systemImage: store.isAuthenticated(provider) ? "checkmark.seal" : "seal",
                     tint: store.isAuthenticated(provider) ? .green : .secondary)
            }
        }
    }

    /// Spend + efficiency in TWO lines instead of five.
    ///
    /// This is a glance surface, and the old block spent ~80pt per provider on a
    /// two-column money grid plus a separate cache/burn row — so barely one
    /// provider fit above the fold, which defeats the point of a menu-bar popover.
    /// Nothing was dropped: every figure that was here is still here. "Today" keeps
    /// the headline size because it is the number you act on; the 30-day total and
    /// the volume/efficiency figures are context and read as context.
    private var spendRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.usd(provider.today?.estimated_cost_usd))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("today")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(Format.usd(provider.last30?.estimated_cost_usd))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("30d")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if !secondaryFigures.isEmpty {
                Text(secondaryFigures.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Volume, turns, measured cache savings and burn rate — one line, only the
    /// parts that exist. Kept separate from the money line so a provider with no
    /// analytics simply loses the line instead of rendering empty separators.
    private var secondaryFigures: [String] {
        var parts: [String] = []
        if let t = provider.today {
            parts.append("\(Format.tokens(t.tokens.grandTotal)) tok")
            parts.append("\(t.records) turns")
        }
        if let saved = provider.analytics?.cache_savings_usd {
            parts.append("\(Format.usd(saved)) saved")
        }
        if let burn = provider.analytics?.burn_rate_usd_per_day {
            parts.append("\(Format.usd(burn))/day")
        }
        return parts
    }

    /// For Claude only: explains the live-limits state when there's no live
    /// limit to show yet (access needed, signed out, or still fetching), so the
    /// card is never a silent blank. A quiet hint when it's simply loading.
    /// Why a card that should carry live numbers is empty.
    ///
    /// This used to be Claude-only, while `SnapshotStore` recorded an error for
    /// **every** live provider — so eight clients could fail and say nothing at all.
    /// A card that is blank for an unstated reason is indistinguishable from one the
    /// app forgot about, which is precisely how "MiniMax shows nothing" looked from
    /// the outside. Claude keeps its extra affordance (a retry that re-triggers the
    /// Keychain prompt); everyone else gets the reason, which is the part that was
    /// missing.
    @ViewBuilder private var liveLimitsNote: some View {
        if provider.provider != "claude", store.liveLimitsEnabled, provider.limits.isEmpty,
           let err = store.liveProviderErrors[provider.provider] {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").imageScale(.small)
                Text(err).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.orange)
        }
        if provider.provider == "claude", store.liveLimitsEnabled, provider.limits.isEmpty {
            if let err = store.liveLimitsError {
                Button { store.refresh() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield").imageScale(.small)
                        Text(err).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Click to retry — macOS will prompt to allow Keychain access")
            } else {
                Text("Fetching Claude's live session / weekly limits…")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var limitsSection: some View {
        VStack(spacing: 5) {
            ForEach(provider.limits) { limit in
                VStack(spacing: 2) {
                    HStack {
                        Text(limitLabel(limit.label))
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.limitUsed(limit.used_percent))
                            .font(.caption2.weight(.medium).monospacedDigit())
                        if let countdown = Format.resetCountdown(limit.resets_at_unix) {
                            Text("· \(countdown)")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    // Bar shows what's LEFT (empties as you spend); tint still keys
                    // off used, so it reddens as the window runs out.
                    MeterBar(fraction: Format.limitFraction(limit.used_percent),
                             tint: SPStatus.limitColor(limit.used_percent),
                             glowsWhenHigh: true)
                    // "at this pace, ~X to the limit" — only for a Claude live
                    // reading (the only provider whose % we sample over time), and
                    // only when it's fresh (a forecast off a stale % is two guesses
                    // stacked; LimitAgeNote below explains the staleness instead).
                    if provider.provider == "claude",
                       limit.provenance == AnthropicUsageClient.liveProvenance {
                        LimitForecastNote(forecast: store.limitForecast(for: limit),
                                          isStale: limit.isStale(staleAfter: LimitWindow.liveStaleAfter))
                    }
                }
            }
            // When Claude's limits are the last-known cached value (the saved
            // token expired or a fetch failed), label their age honestly rather
            // than implying they're live. Shared with Home/Overview, which used to
            // render the same cached number with no age at all.
            // Every provider's reading can be stale, not just Claude's — Codex's
            // come from its logs and were 18.5h old on a real machine.
            if let hottest = provider.hottestLimit {
                LimitAgeNote(limit: hottest)
            }
            if provider.provider == "claude" {
                LiveLimitsStatusNote(capturedAt: store.liveLimitsCapturedAt,
                                     isStale: store.liveLimitsAreStale,
                                     error: store.liveLimitsError,
                                     caveat: store.liveLimitsCaveat,
                                     onRenewLogin: store.liveLimitsRecovery == .renewLoginInTerminal
                                        ? { store.renewClaudeLogin() } : nil)
            }
        }
    }

    private func topModelRow(_ model: ModelUsage) -> some View {
        HStack {
            Image(systemName: "cpu").imageScale(.small).foregroundStyle(.secondary)
            Text(model.model).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Format.usd(model.estimated_cost_usd))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }


    private func limitLabel(_ raw: String) -> String {
        Format.limitLabel(raw)
    }
}

/// Compact card listing providers that have no usage data yet — detected but
/// unscanned, or not installed — so all ten stay visible without ten tall cards.
struct OtherProvidersCard: View {
    let providers: [ProviderUsage]
    var onOpenMainWindow: (() -> Void)?
    @EnvironmentObject var store: SnapshotStore

    private var detectedCount: Int { providers.filter(\.installed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Other providers").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(detectedCount) detected · \(providers.count - detectedCount) not found")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            // Wrapped grid so nine providers take ~3 rows, not nine.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(providers) { p in
                    HStack(spacing: 5) {
                        // The dot's label is also what carries "detected" here:
                        // the name's .primary/.secondary color is the only visual
                        // cue for `installed`, and the core guarantees an
                        // undetected provider reports `not_detected` health
                        // (providers/detection.rs) — so the health label says it.
                        StatusDot(color: SPStatus.healthColor(p.health))
                            .accessibilityLabel(SPStatus.healthLabel(p.health))
                        Text(p.display_name)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(p.installed ? .primary : .secondary)
                        if store.isAuthenticated(p) {
                            Image(systemName: "checkmark.seal.fill")
                                .imageScale(.small).foregroundStyle(.green)
                                .accessibilityLabel("Authenticated")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if let onOpenMainWindow {
                Button(action: onOpenMainWindow) {
                    Label("View all integrations", systemImage: "puzzlepiece.extension")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
