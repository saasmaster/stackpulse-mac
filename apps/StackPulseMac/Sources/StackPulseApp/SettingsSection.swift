import SwiftUI

/// Settings / About: versions, refresh cadence, cost methodology, UTC bucketing,
/// and accessibility notes. Real, read-only content only — the sole control is a
/// working "Refresh now" button wired to the store.
struct SettingsSection: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager

    /// Mirrors the first-run flag so the welcome tour can be replayed on demand.
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    /// The macOS app's own version (distinct from the Rust core version).
    ///
    /// Read from the bundle rather than hardcoded. When this was its own literal,
    /// it drifted from `Info.plist` — Settings said 0.25.0 while macOS (Get Info,
    /// the About panel, crash reports) said **0.1.0**, because the release rule
    /// only ever bumped the one a human looks at. One source of truth now; the
    /// fallback only applies when running the binary outside the .app bundle
    /// (e.g. `--selftest-parsers`), where there is no Info.plist to read.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown (not running from the app bundle)"
    }

    var body: some View {
        SectionScaffold(section: .settings) { snapshot in
            VStack(alignment: .leading, spacing: 16) {
                // Preferences & options — Settings holds only controls, not the
                // live data that belongs in the dashboards.
                appearanceCard
                refreshCard(snapshot)
                notificationsCard
                sidebarCard
                budgetCard
                liveLimitsCard
                startupCard
                demoCard
                powerCard
                ProviderConnectionsCard()
                SecurityPrivacyCard()

                // Tools
                commandCenterCard
                welcomeCard
                exportCard(snapshot)

                // About & reference (not settings, but spec-required here).
                aboutHeader
                versionsCard(snapshot)
                costCard(snapshot)
                accessibilityCard
            }
        }
    }

    /// Spend guardrails. Deliberately plain about what this is and isn't: the
    /// numbers are local list-price estimates, and StackPulse only warns — it does
    /// not control your agents and cannot stop a run.
    private var budgetCard: some View {
        SettingsCard(title: "Spend budget", systemImage: "dollarsign.circle") {
            Text("Get a needs-attention alert when your estimated spend approaches a limit you set. Leave a field empty for no budget.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                BudgetField(label: "Daily", value: $store.dailyBudgetUSD)
                BudgetField(label: "30-day", value: $store.monthlyBudgetUSD)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Warn at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $store.budgetWarnPercent, in: 50...95, step: 5)
                    .frame(maxWidth: 200)
                Text("\(Int(store.budgetWarnPercent))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(width: 34, alignment: .leading)
                Text("· 100% always raises a critical alert")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)

            Label("These are local estimates, not a bill — and StackPulse can only warn you; it can't stop a running agent.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// Replay the first-run welcome tour. Clearing the flag makes the main window
    /// present it again on its next appearance (reopen the window to see it).
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Welcome tour").font(.headline)
                Spacer()
                Button {
                    onboardingCompleted = false
                } label: {
                    Label("Show again", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.glass(tint: .accentColor))
                .disabled(!onboardingCompleted)
                .help("Show the first-run walkthrough again next time the main window opens")
            }
            Text(onboardingCompleted
                 ? "Replay the short walkthrough of what StackPulse does and where things live."
                 : "The walkthrough will show the next time the main window opens.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    /// A quiet divider separating the settings/options above from the static
    /// reference/about cards below (versions, cost methodology, accessibility).
    private var aboutHeader: some View {
        HStack(spacing: 8) {
            Text("ABOUT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.top, 6)
    }

    // MARK: Appearance (hero control)

    /// The theme switcher — the hero control of Settings. The glossy sliding pill
    /// drives the whole app's appearance (popover, window, edge sidebar) and
    /// persists across launches.
    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "paintpalette")
                .font(.headline)
            GlassSegmentedControl(segments: ThemeManager.allSegments, selection: $theme.pref)
            Text("Light, Dark, or Auto (follows macOS). Applies everywhere — the menu-bar popover, this window, and the edge sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 20, prominence: .elevated, padding: 18)
    }

    // MARK: Versions

    private func versionsCard(_ snapshot: UsageSnapshot) -> some View {
        SettingsCard(title: "Versions", systemImage: "info.circle") {
            InfoRow(label: "App", value: appVersion)
            InfoRow(label: "Core", value: snapshot.core_version)
            InfoRow(label: "Protocol", value: snapshot.protocol_version.text)
        }
    }

    // MARK: Refresh

    private func refreshCard(_ snapshot: UsageSnapshot) -> some View {
        SettingsCard(title: "Refresh", systemImage: "arrow.clockwise") {
            Text("How often StackPulse rescans your local sessions. Manual runs no timer — you refresh on demand.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GlassSegmentedControl(segments: RefreshMode.allSegments, selection: $store.refreshMode)

            Label(
                "Spend windows are bucketed by UTC calendar day, so \"today\" follows UTC — not your local midnight.",
                systemImage: "globe"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)

            HStack {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
                .disabled(store.isLoading)
                if store.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: Data & export

    /// Local-first data export: the current snapshot as CSV or JSON, or a quick
    /// human-readable summary copied to the clipboard. Everything is written to a
    /// file the user picks (or the pasteboard) — nothing leaves the Mac.
    private func exportCard(_ snapshot: UsageSnapshot) -> some View {
        SettingsCard(title: "Data & export", systemImage: "square.and.arrow.up") {
            Text("Export your usage as CSV or JSON, or copy a quick summary. Everything stays on your Mac — nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Exporter.save(text: Exporter.snapshotCSV(snapshot),
                                  suggestedName: "stackpulse-usage.csv")
                } label: {
                    Label("Export snapshot (CSV)", systemImage: "tablecells")
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))

                Button {
                    Exporter.save(text: Exporter.snapshotJSON(snapshot),
                                  suggestedName: "stackpulse-usage.json")
                } label: {
                    Label("Export snapshot (JSON)", systemImage: "curlybraces")
                }
                .buttonStyle(.glass(tint: .accentColor))

                Button {
                    Exporter.copyToClipboard(Exporter.textSummary(snapshot))
                } label: {
                    Label("Copy summary", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.glass(tint: .secondary))
                Spacer()
            }
            .padding(.top, 2)

            Label("CSV exports the current per-provider snapshot; Trends can export your full day-by-day history.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // MARK: Command Center

    /// Points at the large second-display monitoring window. Opening it is routed
    /// through a notification the `AppDelegate` observes, so Settings needs no
    /// direct reference to the window controller.
    private var commandCenterCard: some View {
        SettingsCard(title: "Command Center", systemImage: "rectangle.on.rectangle.angled") {
            Text("A large, separate dashboard window built for a second display — big per-provider usage cards, live limits, top models, and a needs-attention view. Switch between AI-usage and mission-control layouts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .stackPulseOpenCommandCenter, object: nil)
                } label: {
                    Label("Open Command Center", systemImage: "rectangle.on.rectangle.angled")
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
                Text("⌘⇧C")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    // MARK: Edge sidebar

    /// The always-available edge sidebar: what it is, the shortcut, and which
    /// screen edge it pins to (also flippable live from the sidebar's own toggle).
    private var sidebarCard: some View {
        SettingsCard(title: "Edge sidebar", systemImage: "sidebar.right") {
            Text("An always-available strip pinned to a screen edge (⌥⌘S) — today's totals, live sessions, needs-attention, and rich per-provider detail. Rides across Spaces and full-screen apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Screen edge")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                GlassSegmentedControl(segments: Self.sidebarEdgeSegments, selection: $store.sidebarOnLeft)
                Text("You can also flip it from the ⇄ button in the sidebar's header.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
    }

    /// Left/right pill for the edge sidebar (`sidebarOnLeft` is `false` = right).
    private static let sidebarEdgeSegments: [GlassSegment<Bool>] = [
        GlassSegment(value: false, systemImage: "arrow.right.to.line", label: "Right"),
        GlassSegment(value: true, systemImage: "arrow.left.to.line", label: "Left"),
    ]

    // MARK: Notifications

    /// Proactive alerting. When on, a new needs-attention alert (a usage limit
    /// nearing its cap, a spend spike, an integration issue) also raises a macOS
    /// notification, with a severity threshold and optional quiet hours. Purely
    /// local — it only surfaces alerts already derived from your own data.
    private var notificationsCard: some View {
        SettingsCard(title: "Notifications", systemImage: "bell.badge") {
            Toggle(isOn: $store.notificationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify me when something needs attention")
                        .font(.callout)
                    Text("Raises a macOS notification when a new alert appears — a usage limit nearing its cap, a spend spike, or an integration issue. Alerts always show in-app too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if store.notificationsEnabled {
                if !store.notificationsAuthorized {
                    Label(
                        "Notifications are turned off for StackPulse in System Settings → Notifications. Enable them there to receive alerts.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notify me about")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    GlassSegmentedControl(segments: Self.severitySegments, selection: $store.notifyMinSeverity)
                    Text("“Warnings” includes critical; “Critical” is the loudest alerts only.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)

                Toggle(isOn: $store.quietHoursEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quiet hours")
                            .font(.callout)
                        Text("Mute banners during these hours. Alerts still appear in the app and menu bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if store.quietHoursEnabled {
                    HStack(spacing: 14) {
                        HourPicker(label: "From", hour: $store.quietStartHour)
                        HourPicker(label: "To", hour: $store.quietEndHour)
                        Spacer()
                    }
                    .padding(.top, 2)
                }

                HStack {
                    Button {
                        store.sendTestNotification()
                    } label: {
                        Label("Send a test notification", systemImage: "bell.and.waves.left.and.right")
                    }
                    .buttonStyle(.glass(tint: .accentColor))
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }

    /// The notification severity threshold, shown as a three-way pill (minimum
    /// severity that triggers a banner).
    private static let severitySegments: [GlassSegment<AlertSeverity>] = [
        GlassSegment(value: .info, systemImage: "bell", label: "All"),
        GlassSegment(value: .warning, systemImage: "exclamationmark.triangle", label: "Warnings"),
        GlassSegment(value: .critical, systemImage: "exclamationmark.octagon", label: "Critical"),
    ]

    // MARK: Live limits

    /// Opt-in network card. Fetches Claude's real session/weekly limits from
    /// Anthropic using the user's own local Claude Code login. When off, the app
    /// makes no network requests and reads no token.
    private var liveLimitsCard: some View {
        SettingsCard(title: "Live limits", systemImage: "antenna.radiowaves.left.and.right") {
            Toggle(isOn: $store.liveLimitsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fetch Claude's live usage limits")
                        .font(.callout)
                    Text("Fetches Claude's session/weekly limits from Anthropic using your local Claude Code login. When off, StackPulse is fully offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if store.liveLimitsEnabled {
                Label(
                    "Uses only your own Claude Code credentials and contacts only Anthropic's API (api.anthropic.com) over HTTPS. Your token is never stored or logged.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Power

    // MARK: Startup

    /// Launch-at-login. The OS owns the state, so this reads it live rather than
    /// mirroring it into a persisted bool that would drift the moment the user
    /// flips the login item in System Settings.
    private var startupCard: some View {
        StartupCard()
    }

    /// Sample-data mode — off by default. A first-run visitor with no logs can flip
    /// it on to see the product; a prominent banner marks every surface while it's on.
    private var demoCard: some View {
        SettingsCard(title: "Sample data", systemImage: "wand.and.stars") {
            Toggle(isOn: $store.demoMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show sample data instead of your own")
                        .font(.callout)
                    Text("Fills StackPulse with fabricated activity so you can see how it looks. Every surface shows a \u{201C}Sample data\u{201D} banner while this is on, and no scanning or network happens. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if store.demoMode {
                Label("Sample data is on — turn it off to see your own machine.",
                      systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var powerCard: some View {
        SettingsCard(title: "Power", systemImage: "bolt.fill") {
            Toggle(isOn: $store.keepAwake) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep this Mac awake while monitoring")
                        .font(.callout)
                    Text("Holds a local sleep assertion so background scans keep running. The display can still dim; no permission needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if store.keepAwake {
                Label("Active — the system won't idle-sleep until you turn this off or quit.",
                      systemImage: "cup.and.saucer.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    // MARK: Cost methodology

    private func costCard(_ snapshot: UsageSnapshot) -> some View {
        SettingsCard(title: "Cost estimates", systemImage: "dollarsign.circle") {
            Text(snapshot.pricing_note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                "For subscription plans these figures are the equivalent metered list-price value of your usage — not the flat fee you are actually billed.",
                systemImage: "exclamationmark.bubble"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Accessibility

    private var accessibilityCard: some View {
        SettingsCard(title: "Accessibility", systemImage: "figure.wave") {
            Label("Respects Reduce Transparency — glass surfaces fall back to solid fills.",
                  systemImage: "circle.lefthalf.filled")
            Label("Respects Reduce Motion — the refresh indicator stops spinning.",
                  systemImage: "hare")
            Label("Status is never color-only — every health dot and meter carries a text label.",
                  systemImage: "eye")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Startup (launch at login)

/// The launch-at-login control. Its own view so it can hold the live OS status in
/// `@State` and re-read it on appear — the login item can be changed from System
/// Settings behind the app's back, and the switch must reflect that, not a stale
/// remembered value.
private struct StartupCard: View {
    @State private var enabled = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var failed = false

    var body: some View {
        SettingsCard(title: "Startup", systemImage: "power") {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open StackPulse at login")
                        .font(.callout)
                    Text("A menu-bar monitor is only useful while it's running. macOS manages this login item; you can also change it in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if failed {
                Label("macOS wouldn't change the login item. If you're running StackPulse from the Desktop, move it to Applications and try again.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            } else if needsApproval {
                Label(LaunchAtLogin.statusDetail, systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
    }

    private func setEnabled(_ on: Bool) {
        let ok = LaunchAtLogin.setEnabled(on)
        failed = !ok
        refresh()
    }

    /// Re-read the OS's own truth. Never assume the toggle took — `register()` can
    /// land in `requiresApproval`, which is neither on nor an error.
    private func refresh() {
        enabled = LaunchAtLogin.isEnabled
        needsApproval = LaunchAtLogin.needsApproval
    }
}

// MARK: - Building blocks

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }
}

/// A compact hour-of-day picker (`00:00`–`23:00`) for the quiet-hours range.
private struct HourPicker: View {
    let label: String
    @Binding var hour: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(label, selection: $hour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d:00", h)).tag(h)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 92)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
        }
    }
}

// MARK: - Provider connections (BYOK API keys)

/// Lists the BYOK-capable providers so the user can connect an API key and see a
/// real credit balance. Keys are stored in the Keychain and never rendered back.
private struct ProviderConnectionsCard: View {
    var body: some View {
        SettingsCard(title: "Provider connections", systemImage: "key.horizontal") {
            Text("Add an API key so a provider shows its real credit balance. OpenRouter and LiteLLM report a live balance today; the rest save your key so they're ready when balance support lands.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(APIKeyProviders.all) { info in
                ProviderConnectionRow(info: info)
                if info.id != APIKeyProviders.all.last?.id {
                    Divider().opacity(0.35)
                }
            }

            Label("Keys are stored in your Mac's Keychain and sent only to that provider's API.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

/// One provider's connection row: a masked key field (plus a base-URL field for
/// LiteLLM), Save / Clear, and a live status line. The actual key is never shown
/// back — a saved key renders as a `••••` placeholder and the field is cleared
/// after saving.
private struct ProviderConnectionRow: View {
    let info: APIKeyProviderInfo
    @EnvironmentObject var store: SnapshotStore

    @State private var keyInput = ""
    @State private var baseURLInput = ""

    private var isConnected: Bool { store.apiKeyProviderIDs.contains(info.id) }
    private var trimmedKey: String { keyInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(info.displayName)
                    .font(.callout.weight(.semibold))
                if isConnected {
                    Chip(text: "Connected", systemImage: "checkmark.seal.fill", tint: .green)
                }
                Spacer()
                if !info.hasLiveBalance {
                    Text(APIKeyProviders.noBalanceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("StackPulse can store and use this key, but \(info.displayName) exposes no balance it can read.")
                }
            }

            SecureField(
                isConnected ? "•••••••• saved — enter a new key to replace" : info.placeholder,
                text: $keyInput
            )
            .textFieldStyle(.roundedBorder)
            .font(.callout)

            if info.needsBaseURL {
                TextField("Base URL (e.g. https://your-litellm-host)", text: $baseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .textContentType(.URL)
            }

            HStack(spacing: 8) {
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
                .disabled(saveDisabled)

                if isConnected {
                    Button {
                        clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.glass(tint: .secondary))
                }
                Spacer()
            }

            statusLine
        }
        .padding(.vertical, 4)
        .onAppear {
            // Prefill the (non-secret) base URL; never prefill the key.
            if info.needsBaseURL, baseURLInput.isEmpty {
                baseURLInput = store.baseURL(for: info.id) ?? ""
            }
        }
    }

    /// Save is enabled when there's a new key to store, or (for LiteLLM) a
    /// base-URL-only change on an already-connected provider.
    private var saveDisabled: Bool {
        if trimmedKey.isEmpty {
            return !(info.needsBaseURL && isConnected)
        }
        return false
    }

    private func save() {
        if trimmedKey.isEmpty, info.needsBaseURL, isConnected {
            store.saveBaseURL(baseURLInput, for: info.id)
        } else {
            store.saveAPIKey(keyInput, for: info.id,
                             baseURL: info.needsBaseURL ? baseURLInput : nil)
        }
        keyInput = ""   // never keep the key in the field
    }

    private func clear() {
        store.clearAPIKey(for: info.id)
        keyInput = ""
        baseURLInput = ""
    }

    @ViewBuilder private var statusLine: some View {
        if let balance = store.balances[info.id] {
            ProviderBalanceLabel(balance: balance)
        } else if let err = store.balanceError[info.id] {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
        } else if isConnected {
            Label("Key saved.", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - Security & privacy

/// One outbound network path StackPulse can open, with the state that decides
/// whether it is currently open at all.
private struct NetPath: Identifiable {
    let id: String
    let title: String
    /// Where the traffic actually goes. Only rendered when `isOn`.
    let destination: String
    let detail: String
    let isOn: Bool
}

/// Diagnostics for the app's trust boundary: what it can touch, what it actually
/// sends, and where.
///
/// Every "live" row reads the SAME state its feature reads, so the panel cannot
/// drift into reassurance the code doesn't back. A hardcoded "offline" here would
/// be worse than showing nothing — this card is only worth its space if a reader
/// can trust it against the running app. Claims that are compiled-in rather than
/// toggled live in ``policyGroup``, labeled as policy so they are never mistaken
/// for a reading.
///
/// No secret is rendered — presence/absence only, not even truncated. The token
/// and key boundaries are documented on `AnthropicUsageClient` / `APIKeyStore`;
/// this card reports on them and must never widen them.
private struct SecurityPrivacyCard: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SettingsCard(title: "Security & privacy", systemImage: "lock.shield") {
            Text("What StackPulse can reach, what it actually sends, and where — read from this Mac's live settings, not a fixed list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            postureRow
            networkGroup
            credentialsGroup
            foldersGroup
            policyGroup
        }
    }

    // MARK: Posture

    private var postureRow: some View {
        HStack(spacing: 8) {
            if enabledPaths.isEmpty {
                Chip(text: "Offline — no outbound path is enabled",
                     systemImage: "wifi.slash", tint: .green)
            } else {
                Chip(text: "\(enabledPaths.count) outbound path\(enabledPaths.count == 1 ? "" : "s") enabled",
                     systemImage: "antenna.radiowaves.left.and.right", tint: .orange)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Network

    private var networkGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.35)
            groupHeader("Network", systemImage: "network")
            Text("These are the only three outbound paths in the app. Each is opt-in and each is shown below as it is actually configured right now.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(networkPaths) { pathRow($0) }
        }
    }

    private func pathRow(_ path: NetPath) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(path.title)
                    .font(.callout.weight(.medium))
                Chip(text: path.isOn ? "On" : "Off",
                     systemImage: path.isOn ? "arrow.up.forward" : "slash.circle",
                     tint: path.isOn ? .orange : .secondary)
                Spacer(minLength: 0)
            }
            // The destination is named only when traffic can actually flow — an
            // endpoint listed beside an "Off" row reads as if it were in use.
            if path.isOn {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(path.destination)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(path.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    private var networkPaths: [NetPath] { [liveLimitsPath, byokPath, stackHealthPath] }

    private var enabledPaths: [NetPath] { networkPaths.filter(\.isOn) }

    /// Claude live limits. The destination is read from the client's own constant
    /// rather than retyped, so the row cannot name an endpoint the code doesn't use.
    private var liveLimitsPath: NetPath {
        NetPath(
            id: "live-limits",
            title: "Claude live limits",
            destination: AnthropicUsageClient.endpoint.absoluteString,
            detail: store.liveLimitsEnabled
                // "attempt", not "contacted": the store stamps this after every
                // try, including one that found no login and sent nothing.
                ? "On — StackPulse contacts Anthropic with your own Claude Code token to read your session and weekly limits. It is sent to that one endpoint and nowhere else. Fetched \(cadenceSentence), throttled and cached in between. Last attempt \(Format.relative(store.liveLimitsUpdatedAt))."
                : "Off — no token is read and no request is made.",
            isOn: store.liveLimitsEnabled
        )
    }

    /// BYOK balances. Only a provider with BOTH a saved key and a real balance
    /// endpoint is ever contacted; a key saved for a provider without one sits in
    /// the Keychain and goes nowhere, which is worth saying rather than implying.
    private var byokPath: NetPath {
        let contacted = byokContacted
        let stored = byokStoredOnly
        return NetPath(
            id: "byok",
            title: "Provider credit balances (BYOK)",
            destination: byokDestination,
            detail: contacted.isEmpty
                ? (stored.isEmpty
                   ? "Off — no API keys saved, so no provider is contacted."
                   : "Off — \(stored.count) key\(stored.count == 1 ? "" : "s") saved, but \(stored.count == 1 ? "that provider has" : "those providers have") no balance endpoint yet, so nothing is sent.")
                : "On — each key is sent only to its own provider's API, to read that account's credit balance. Last checked \(Format.relative(latestBalanceCheck)).",
            isOn: !contacted.isEmpty
        )
    }

    /// Stack Health enrichment. Reported as enabled whenever the toggle is on,
    /// even with no folders to scan: erring toward over-reporting network is the
    /// only safe direction for this card.
    private var stackHealthPath: NetPath {
        NetPath(
            id: "stack-health",
            title: "Stack Health update checks",
            destination: "registry.npmjs.org · crates.io · api.osv.dev",
            detail: store.stackCheckUpdates
                ? (store.approvedRoots.isEmpty
                   ? "On, but idle — no approved folders, so there are no dependencies to look up."
                   : "On — sends only dependency names and versions already on disk, to look up latest releases and security advisories. No credentials are attached.")
                : "Off — Stack Health shows the core's local, offline inventory only.",
            isOn: store.stackCheckUpdates
        )
    }

    private var byokContacted: [APIKeyProviderInfo] {
        APIKeyProviders.all.filter { store.apiKeyProviderIDs.contains($0.id) && $0.hasLiveBalance }
    }

    private var byokStoredOnly: [APIKeyProviderInfo] {
        APIKeyProviders.all.filter { store.apiKeyProviderIDs.contains($0.id) && !$0.hasLiveBalance }
    }

    /// Names each contacted provider. LiteLLM's destination is the user's own
    /// host, so it is shown verbatim from the stored (non-secret) base URL.
    private var byokDestination: String {
        let names = byokContacted.map { info -> String in
            if info.needsBaseURL, let base = store.baseURL(for: info.id), !base.isEmpty {
                return "\(info.displayName) (\(base))"
            }
            return "\(info.displayName)'s API"
        }
        return names.isEmpty ? "—" : names.joined(separator: " · ")
    }

    private var latestBalanceCheck: Date? {
        byokContacted.compactMap { store.balanceUpdatedAt[$0.id] }.max()
    }

    private var cadenceSentence: String {
        store.refreshMode == .manual
            ? "only when you refresh manually"
            : "on your \(store.refreshMode.label) refresh"
    }

    // MARK: Credentials

    private var credentialsGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.35)
            groupHeader("Credentials", systemImage: "key.horizontal")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Claude Code login")
                        .font(.callout.weight(.medium))
                    Chip(text: claudeLoginPresent ? "Detected" : "Not found",
                         systemImage: claudeLoginPresent ? "checkmark.seal.fill" : "circle.dashed",
                         tint: claudeLoginPresent ? .green : .secondary)
                    Spacer(minLength: 0)
                }
                Text(claudeLoginPresent
                     ? "Found by a presence-only Keychain query — it asks whether an item exists and requests no secret data, so it never prompts and cannot return your token."
                     : "The last scan found no Claude Code Keychain item. Detection is presence-only; no secret is requested.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Claude OAuth token read")
                        .font(.callout.weight(.medium))
                    Chip(text: store.liveLimitsEnabled ? "Enabled" : "Never",
                         systemImage: store.liveLimitsEnabled ? "exclamationmark.shield" : "lock.fill",
                         tint: store.liveLimitsEnabled ? .orange : .green)
                    Spacer(minLength: 0)
                }
                Text(store.liveLimitsEnabled
                     ? "This is the one place StackPulse reads a secret instead of checking for one. Your Claude Code token is read on demand, sent to the live-limits endpoint above, and dropped — never stored, never logged, never rewritten, and never shown here or anywhere else in the app."
                     : "Live limits are off, so the token is never read — only the presence check above runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The client's own user-facing note — it already covers "access
                // denied", "expired", and "rejected", and by contract carries no
                // token or response body.
                if store.liveLimitsEnabled, let note = store.liveLimitsError {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.liveLimitsRecovery == .renewLoginInTerminal {
                        Button { store.renewClaudeLogin() } label: {
                            Label("Renew login in Terminal", systemImage: "terminal")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.glass(tint: .orange))
                        .help("Runs `claude` in Terminal so it can refresh its saved login. StackPulse never changes your login itself.")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("BYOK API keys")
                        .font(.callout.weight(.medium))
                    Chip(text: store.apiKeyProviderIDs.isEmpty
                            ? "None saved"
                            : "\(store.apiKeyProviderIDs.count) saved",
                         systemImage: "key.fill",
                         tint: store.apiKeyProviderIDs.isEmpty ? .secondary : .blue)
                    Spacer(minLength: 0)
                }
                Text("Kept in StackPulse's own Keychain service (\(APIKeyStore.service)), never another app's — so reading one raises no access prompt. A key is loaded only for its own balance request and is never rendered back, not even truncated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !byokConnectedNames.isEmpty {
                    Text(byokConnectedNames)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Presence-only result the refresh path already computed off the main actor.
    /// Deliberately NOT probed here: the token-reading probe can block for seconds
    /// and prompt, so this card only ever reads a value someone else established.
    private var claudeLoginPresent: Bool { store.keychainAuthed.contains("claude") }

    private var byokConnectedNames: String {
        APIKeyProviders.all
            .filter { store.apiKeyProviderIDs.contains($0.id) }
            .map(\.displayName)
            .joined(separator: " · ")
    }

    // MARK: Folders

    private var foldersGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.35)
            groupHeader("Approved folders", systemImage: "folder.badge.person.crop")

            if store.approvedRoots.isEmpty {
                Text("None approved — project scanning is off. StackPulse reads only your AI tools' own session logs under their config directories.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Project scanning reads inside \(store.approvedRoots.count == 1 ? "this root" : "these \(store.approvedRoots.count) roots") and nowhere else. Remove one in Projects to revoke it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(store.approvedRoots, id: \.self) { root in
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(root)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Built-in policy (compiled in, not a live reading)

    private var policyGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.35)
            HStack(spacing: 6) {
                groupHeader("Built-in policy", systemImage: "text.book.closed")
                Chip(text: "Not a live reading", tint: .secondary)
                Spacer(minLength: 0)
            }
            Text("These hold regardless of every setting above — they're compiled in, not toggled.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            policyRow(
                "The Rust core never touches the network",
                "Every scan, parse, and cost estimate runs offline, in-process. The core has no HTTP client compiled into it at all (ADR-0005) — the paths above belong to the macOS app, never to the engine reading your logs."
            )
            policyRow("Nothing runs silently", confirmationPolicyText)
            policyRow(
                "Destructive git is reported, never run",
                "For checkpoints and worktrees the core only ever reports a restore or remove command as text for you to see. It never executes one — running it stays your explicit, confirmed choice."
            )
        }
    }

    private func policyRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "checkmark.shield")
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
        }
    }

    /// Derived by asking the real gate — the same `CommandSafety` predicate the run
    /// path calls — which classes it lets through. Hand-writing this sentence would
    /// let it claim a stricter policy than the code enforces.
    private var confirmationPolicyText: String {
        let classes = Self.safetyClasses
        let ungated = classes.filter { !CommandSafety.requiresConfirmation($0) }
            .map { CommandSafety.label($0) }
        let gated = classes.filter { CommandSafety.requiresConfirmation($0) }
            .map { CommandSafety.label($0) }
        return "Discovered commands are classified before they can run. \(ungated.joined(separator: ", ")) commands run without a prompt; \(gated.joined(separator: ", ")) commands are gated behind an explicit confirmation showing the exact command and its working directory. StackPulse never runs a command you didn't press a button for."
    }

    /// The safety classes `CommandSafety` distinguishes, in escalating order.
    private static let safetyClasses = [
        "read_only", "local_dev", "modifies_files", "installs_deps",
        "changes_database", "network", "destructive",
    ]

    private func groupHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Budget field

/// A USD budget entry. An **empty** field means "no budget" — distinct from `0`,
/// which would mean "every cent is over budget". Commits on Return/blur so a
/// half-typed number never briefly reads as a tiny budget and fires an alert.
private struct BudgetField: View {
    let label: String
    @Binding var value: Double?

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text("$").foregroundStyle(.secondary)
                TextField("none", text: $text)
                    .textFieldStyle(.plain)
                    .frame(width: 72)
                    .focused($focused)
                    .onSubmit(commit)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .liquidGlass(cornerRadius: 8, prominence: .low, padding: 0)
        }
        .onAppear { text = value.map { String(format: "%g", $0) } ?? "" }
        .onChange(of: focused) { if !focused { commit() } }
        .accessibilityLabel("\(label) spend budget in dollars, empty for none")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = nil
        } else if let parsed = Double(trimmed), parsed > 0 {
            value = parsed
            text = String(format: "%g", parsed)
        } else {
            // Reject garbage (and 0) by snapping back to the last good value.
            text = value.map { String(format: "%g", $0) } ?? ""
        }
    }
}
