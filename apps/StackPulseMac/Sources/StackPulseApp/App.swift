import AppKit
import Combine
import SwiftUI
@preconcurrency import UserNotifications

/// Entry point.
///
/// `--dump` prints the raw snapshot JSON and exits (headless verification, no
/// GUI); `--version` prints the core version. Otherwise we run as a menu-bar
/// accessory app (no Dock icon).
@main
enum StackPulseMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") {
            print(CoreBridge.handle(#"{"op":"get_usage_snapshot"}"#))
            return
        }
        if args.contains("--version") {
            print("StackPulse core \(CoreBridge.coreVersion())")
            return
        }
        // Headless parser self-tests (pure, offline — no Keychain, no network).
        // Exercises the live-limits parser and the BYOK balance parsers against
        // their embedded fixtures. Exits non-zero if any assertion fails.
        if args.contains("--selftest-parsers") {
            let live = AnthropicUsageClient._selftest()
            let balances = ProviderBalanceClient._selftest()
            let notify = NotificationManager._selftest()
            let stack = StackHealthClient._selftest()
            let stale = SnapshotStore._selftestStaleness()
            print("anthropic-usage parser: \(live ? "PASS" : "FAIL")")
            print("provider-balance parser: \(balances ? "PASS" : "FAIL")")
            print("notification-gate logic: \(notify ? "PASS" : "FAIL")")
            print("stack-health semver logic: \(stack ? "PASS" : "FAIL")")
            print("live-limits staleness policy: \(stale ? "PASS" : "FAIL")")
            exit(live && balances && notify && stack && stale ? 0 : 1)
        }
        // Hidden diagnostic: exercise the live-limits path (Keychain read + fetch)
        // and print the outcome — the credential *state* and the limit
        // percentages only, never the token or raw response. Used to tell an
        // access-denied Keychain from a code bug.
        if args.contains("--selftest-live") {
            let sem = DispatchSemaphore(value: 0)
            // `Task.detached`, NOT `Task`: this runs in a main-actor context, so a
            // plain `Task` inherits the main actor and can never start while
            // `sem.wait()` below is blocking that same thread. This diagnostic
            // deadlocked on every invocation — printing nothing, forever — which is
            // precisely why a 70-hour live-limits failure went undiagnosed.
            Task.detached {
                switch KeychainProbe.readClaudeCredentialsResult() {
                case .notFound: print("creds: notFound")
                case .accessDenied: print("creds: accessDenied (Keychain read blocked)")
                case .parseFailed: print("creds: parseFailed")
                case .ok: print("creds: ok (token read)")
                }
                let outcome = await AnthropicUsageClient.fetchClaudeLimits(claudeVersion: nil)
                print("limits: \(outcome.limits.count)  error: \(outcome.error ?? "none")")
                for l in outcome.limits {
                    print(String(format: "  %@: %.0f%%", l.label, l.used_percent))
                }
                sem.signal()
            }
            // Bounded: a Keychain prompt can sit unanswered, and a diagnostic that
            // hangs forever is the thing being fixed here.
            if sem.wait(timeout: .now() + 60) == .timedOut {
                print("timed out after 60s — a Keychain prompt is probably unanswered")
            }
            return
        }
        // Hidden diagnostic: prove the notification pipeline end-to-end. Requests
        // authorization (prompts once if never asked), posts one banner, then reads
        // it back from Notification Center as a programmatic delivery proof. Only
        // meaningful inside the packaged `.app` (a bare executable has no bundle id,
        // so the system won't deliver). Prints state only — never any user data.
        if args.contains("--selftest-notify") {
            Task {
                let center = UNUserNotificationCenter.current()
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                print("notify authorization granted: \(granted)")
                let content = UNMutableNotificationContent()
                content.title = "StackPulse notification test"
                content.body = "If you can see this banner, notifications are working."
                content.sound = .default
                let req = UNNotificationRequest(identifier: "selftest:notify", content: content, trigger: nil)
                try? await center.add(req)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let delivered = await center.deliveredNotifications().map { $0.request.identifier }
                print("delivered notifications: \(delivered.count) \(delivered)")
                CFRunLoopStop(CFRunLoopGetMain())
            }
            // Pump the main run loop so the UserNotifications XPC callbacks are
            // actually serviced (a bare semaphore wait would starve them).
            CFRunLoopRunInMode(.defaultMode, 15, false)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// The single source of truth shared by the popover, main window, and sidebar.
    private let store = SnapshotStore()
    /// The single appearance controller injected into every hosting view so the
    /// theme switch drives the whole app (popover, window, edge sidebar).
    private let theme = ThemeManager()
    private var mainWindowController: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var commandCenter: CommandCenterController?
    private var edgeSidebar: EdgeSidebarController?
    private var sidebarMenuItem: NSMenuItem?
    private var keepAwakeMenuItem: NSMenuItem?
    private var commandCenterObserver: (any NSObjectProtocol)?
    private var settingsObserver: (any NSObjectProtocol)?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                onOpenMainWindow: { [weak self] in self?.openMainWindow() },
                onToggleSidebar: { [weak self] in self?.toggleSidebar() },
                onOpenCommandCenter: { [weak self] in self?.showCommandCenter() },
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
            .environmentObject(store)
            .environmentObject(theme)
        )

        // Any surface can request the Command Center via this notification.
        commandCenterObserver = NotificationCenter.default.addObserver(
            forName: .stackPulseOpenCommandCenter, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showCommandCenter() }
        }

        // Any surface (main-window footer gear, etc.) can request Settings.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .stackPulseOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        // Reflect snapshot / loading / alert changes in the menu-bar button.
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonTitle() }
            .store(in: &cancellables)
        store.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonTitle() }
            .store(in: &cancellables)
        store.$acknowledgedAlertIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButtonTitle() }
            .store(in: &cancellables)
        store.$keepAwake
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateKeepAwakeMenuState() }
            .store(in: &cancellables)

        // A click on a delivered notification opens the app on needs-attention.
        // Set the target section first, then open — matching the popover's
        // navigation pattern so both the first-open and already-open paths route.
        store.notifications.onOpen = { [weak self] in
            guard let self else { return }
            self.store.pendingSection = .alerts
            self.openMainWindow()
        }

        store.start()

        // Optional: open straight to the main window (Dock launch / testing).
        if CommandLine.arguments.contains("--open-window") {
            openMainWindow()
        }
        // Optional: open straight to the Settings window (testing).
        if CommandLine.arguments.contains("--open-settings") {
            openSettings()
        }
    }

    /// Menu-bar app: never quit just because the window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Main window

    /// Open (or re-focus) the main application window. Flips the activation
    /// policy to `.regular` so the window can take focus and gets a real menu
    /// bar; `mainWindowDidClose()` restores accessory mode.
    @objc func openMainWindow() {
        popover.performClose(nil)

        if mainWindowController == nil {
            mainWindowController = MainWindowController(store: store, theme: theme) { [weak self] in
                self?.mainWindowDidClose()
            }
        }
        NSApp.setActivationPolicy(.regular)
        mainWindowController?.show()
    }

    private func mainWindowDidClose() {
        // Back to a pure menu-bar accessory — but only if no other real window
        // (the Command Center) is still on screen.
        if !(commandCenter?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Settings window

    /// Open (or focus) the dedicated Settings window — configuration lives here,
    /// separate from the dashboards in the main window. Menu / ⌘, target.
    @objc func openSettings() {
        showSettings(tab: nil)
    }

    /// Open Settings on a specific tab (e.g. Integrations).
    func showSettings(tab: SettingsTab?) {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, theme: theme) { [weak self] in
                self?.settingsWindowDidClose()
            }
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.show(tab: tab)
    }

    private func settingsWindowDidClose() {
        // Return to accessory only if no other real window is still open.
        let mainOpen = mainWindowController?.window?.isVisible ?? false
        let ccOpen = commandCenter?.isVisible ?? false
        if !mainOpen && !ccOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Command Center window

    /// Show/focus the large monitoring window (used by the popover button, the
    /// Settings button, and the open-command-center notification).
    private func showCommandCenter() {
        popover.performClose(nil)
        ensureCommandCenter()
        NSApp.setActivationPolicy(.regular)
        commandCenter?.show()
    }

    /// Menu toggle: show when hidden/unfocused, hide when it's the focused window.
    @objc func toggleCommandCenter() {
        popover.performClose(nil)
        ensureCommandCenter()
        NSApp.setActivationPolicy(.regular)
        commandCenter?.toggle()
    }

    private func ensureCommandCenter() {
        if commandCenter == nil {
            commandCenter = CommandCenterController(store: store, theme: theme) { [weak self] in
                self?.commandCenterDidClose()
            }
        }
    }

    private func commandCenterDidClose() {
        // Return to accessory only if the main window isn't still open.
        if !(mainWindowController?.window?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarImage()
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.action = #selector(togglePopover)
        button.target = self
        updateButtonTitle()
    }

    /// The menu-bar title: an optional green "▶N" active-sessions indicator, the
    /// existing limit%/tokens text, then a colored "⚠︎N" badge when there are
    /// unacknowledged alerts (tinted by the highest active severity — critical
    /// red, warning orange, info blue).
    private func updateButtonTitle() {
        guard let button = statusItem.button else { return }
        if store.snapshot == nil && store.isLoading {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let title = NSMutableAttributedString()

        // Leading "▶N" when AI coding sessions are active (green, prominent).
        let activeMissions = store.activeMissionCount
        if activeMissions > 0 {
            title.append(NSAttributedString(
                string: "▶\(activeMissions) ",
                attributes: [
                    .foregroundColor: NSColor.systemGreen,
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                ]
            ))
        }

        title.append(NSAttributedString(
            string: " " + store.menuBarText,
            attributes: [.foregroundColor: NSColor.labelColor]
        ))

        let active = store.activeAlerts
        if !active.isEmpty, let severity = store.highestActiveSeverity {
            let badge = NSAttributedString(
                string: "  ⚠︎\(active.count)",
                attributes: [
                    .foregroundColor: Self.nsColor(for: severity),
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                ]
            )
            title.append(badge)
        }

        button.attributedTitle = title

        // Tooltip combines active sessions + needs-attention, whichever apply.
        var tips: [String] = []
        if activeMissions > 0 {
            tips.append("\(activeMissions) active AI coding session\(activeMissions == 1 ? "" : "s")")
        }
        if !active.isEmpty {
            tips.append("\(active.count) item\(active.count == 1 ? "" : "s") need attention")
        }
        button.toolTip = tips.isEmpty ? nil : tips.joined(separator: " · ")
    }

    private static func nsColor(for severity: AlertSeverity) -> NSColor {
        switch severity {
        case .critical: return .systemRed
        case .warning: return .systemOrange
        case .info: return .systemBlue
        }
    }

    // MARK: Edge sidebar

    @objc func toggleSidebar() {
        popover.performClose(nil)
        if edgeSidebar == nil {
            edgeSidebar = EdgeSidebarController(store: store, theme: theme) { [weak self] in
                self?.openMainWindow()
            }
        }
        edgeSidebar?.toggle()
        updateSidebarMenuState()
    }

    private func updateSidebarMenuState() {
        let shown = edgeSidebar?.isVisible ?? false
        sidebarMenuItem?.state = shown ? .on : .off
        sidebarMenuItem?.title = shown ? "Hide Sidebar" : "Show Sidebar"
    }

    // MARK: Keep awake

    @objc func toggleKeepAwake() {
        store.keepAwake.toggle()
    }

    private func updateKeepAwakeMenuState() {
        keepAwakeMenuItem?.state = store.keepAwake ? .on : .off
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Main menu

    /// Build an application main menu so the window (in `.regular` mode) has an
    /// "Open StackPulse Window" item plus standard app / edit / window commands.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // Application menu.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About StackPulse",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open StackPulse Window",
                                  action: #selector(openMainWindow),
                                  keyEquivalent: "0")
        openItem.target = self
        appMenu.addItem(openItem)
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide StackPulse",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit StackPulse",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu (enables copy / paste / select-all for selectable text).
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu (sidebar + keep-awake toggles).
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let sidebarItem = NSMenuItem(title: "Show Sidebar",
                                     action: #selector(toggleSidebar),
                                     keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.option, .command]
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)
        sidebarMenuItem = sidebarItem

        let commandCenterItem = NSMenuItem(title: "Command Center",
                                           action: #selector(toggleCommandCenter),
                                           keyEquivalent: "c")
        commandCenterItem.keyEquivalentModifierMask = [.shift, .command]
        commandCenterItem.target = self
        viewMenu.addItem(commandCenterItem)

        let keepAwakeItem = NSMenuItem(title: "Keep Awake",
                                       action: #selector(toggleKeepAwake),
                                       keyEquivalent: "")
        keepAwakeItem.target = self
        keepAwakeItem.state = store.keepAwake ? .on : .off
        viewMenu.addItem(keepAwakeItem)
        keepAwakeMenuItem = keepAwakeItem

        // Window menu.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// Prefer a gauge glyph; fall back gracefully across macOS symbol sets.
    private static func menuBarImage() -> NSImage? {
        let candidates = [
            "gauge.with.dots.needle.67percent",
            "gauge.medium",
            "gauge",
            "bolt.horizontal.fill",
        ]
        for name in candidates {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "StackPulse") {
                return img
            }
        }
        return nil
    }
}
