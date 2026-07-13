import SwiftUI

/// Settings / About: versions, refresh cadence, cost methodology, UTC bucketing,
/// and accessibility notes. Real, read-only content only — the sole control is a
/// working "Refresh now" button wired to the store.
struct SettingsSection: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager

    /// The macOS app's own version (distinct from the Rust core version).
    private let appVersion = "0.5.0"

    var body: some View {
        SectionScaffold(section: .settings) { snapshot in
            VStack(alignment: .leading, spacing: 16) {
                appearanceCard
                versionsCard(snapshot)
                refreshCard(snapshot)
                exportCard(snapshot)
                commandCenterCard
                sidebarCard
                notificationsCard
                liveLimitsCard
                ProviderConnectionsCard()
                powerCard
                costCard(snapshot)
                accessibilityCard
            }
        }
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

            InfoRow(label: "Cadence", value: store.refreshMode.summary)
            InfoRow(label: "Last updated", value: Format.relative(store.lastUpdated))
            InfoRow(label: "UTC bucket", value: snapshot.bucket_date_utc)
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
                InfoRow(label: "Last checked", value: Format.relative(store.liveLimitsUpdatedAt))

                if let error = store.liveLimitsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                    Text("balance coming soon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
