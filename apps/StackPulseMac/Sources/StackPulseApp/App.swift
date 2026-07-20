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
            let cursor = CursorUsageClient._selftest()
            let codexLive = CodexLiveUsageClient._selftest()
            let copilot = CopilotUsageClient._selftest()
            let antigravity = AntigravityQuotaClient._selftest()
            let zai = ZaiUsageClient._selftest()
            let grok = GrokUsageClient._selftest()
            let devin = DevinUsageClient._selftest()
            let marks = ProviderIconShape._selftest()
            let claudeAuth = ClaudeAuthStore._selftest()
            print("anthropic-usage parser: \(live ? "PASS" : "FAIL")")
            print("provider-balance parser: \(balances ? "PASS" : "FAIL")")
            print("cursor-usage parser: \(cursor ? "PASS" : "FAIL")")
            print("codex-live-usage parser: \(codexLive ? "PASS" : "FAIL")")
            print("copilot-usage parser: \(copilot ? "PASS" : "FAIL")")
            print("antigravity-quota parser: \(antigravity ? "PASS" : "FAIL")")
            print("zai-usage parser: \(zai ? "PASS" : "FAIL")")
            print("grok-usage parser: \(grok ? "PASS" : "FAIL")")
            print("devin-usage parser: \(devin ? "PASS" : "FAIL")")
            print("provider brand marks: \(marks ? "PASS" : "FAIL")")
            print("claude auth store: \(claudeAuth ? "PASS" : "FAIL")")
            print("notification-gate logic: \(notify ? "PASS" : "FAIL")")
            print("stack-health semver logic: \(stack ? "PASS" : "FAIL")")
            print("live-limits staleness policy: \(stale ? "PASS" : "FAIL")")
            exit(live && balances && cursor && codexLive && copilot && antigravity
                 && zai && grok && devin && marks && claudeAuth && notify && stack && stale ? 0 : 1)
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
                // Deliberately does NOT probe the Keychain separately first: the
                // fetch below performs exactly one credential read, and a second
                // one here would risk the double "allow access" prompt this file's
                // design is built to avoid.
                print("desktop: \(ClaudeDesktopAuthStore.describeForDiagnostics())")
                let outcome = await AnthropicUsageClient.fetchClaudeLimits(claudeVersion: nil)
                // WHICH login these percentages belong to, and whether the token
                // had to be renewed to get them. "creds: ok" alone can't say.
                print("auth: \(ClaudeAuthStore.describeForDiagnostics())")
                if let caveat = outcome.caveat { print("caveat: \(caveat)") }
                print("limits: \(outcome.limits.count)  error: \(outcome.error ?? "none")")
                for l in outcome.limits {
                    // Reset time matters as much as the percentage: a suspiciously
                    // low utilization is either a real fresh window or a wrong
                    // reading, and only the reset instant tells them apart.
                    let resets = l.resets_at_unix.map {
                        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval($0)))
                    } ?? "nil"
                    print(String(format: "  %@: used %.2f%% · resets %@", l.label, l.used_percent, resets))
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
    private var commandCenter: CommandCenterController?
    private var edgeSidebar: EdgeSidebarController?
    private var sidebarMenuItem: NSMenuItem?
    private var keepAwakeMenuItem: NSMenuItem?
    private var commandCenterObserver: (any NSObjectProtocol)?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Earlier builds copied the Claude credential to a plaintext file. Clear
        // that before anything else runs — it holds a live refresh token, and it
        // only stops being a liability once it's gone. Off the main thread: it
        // shells out to `security`. Content is re-homed into the Keychain first.
        Task.detached(priority: .utility) { ClaudeAuthStore.migrateLegacyPlaintextBackup() }

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
        store.notifications.onOpen = { [weak self] in
            self?.showSection(.alerts)
        }

        store.start()

        // Optional: open straight to the main window (Dock launch / testing).
        if CommandLine.arguments.contains("--open-window") {
            openMainWindow()
        }
        // Optional: open straight to the main window's Settings section (testing).
        if CommandLine.arguments.contains("--open-settings") {
            openSettings()
        }
        // Optional: open the main window on a named section (for scripted
        // screenshot capture), e.g. `--section usage`. Ignored for unknown names.
        if let i = CommandLine.arguments.firstIndex(of: "--section"),
           i + 1 < CommandLine.arguments.count,
           let section = MainSection(rawValue: CommandLine.arguments[i + 1]) {
            showSection(section)
        }
        // Optional (scripted screenshot capture): show the edge sidebar / open the
        // menu-bar popover on launch. A tiny delay lets the status item lay out
        // first so the popover anchors to it.
        if CommandLine.arguments.contains("--show-sidebar") {
            toggleSidebar()
        }
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    /// Menu-bar app: never quit just because the window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Main window

    /// Open (or focus) the main window on a specific section. The target is set
    /// before the window opens so both paths route: a window opening for the
    /// first time reads it on appear, a live one observes the change.
    func showSection(_ section: MainSection) {
        store.pendingSection = section
        openMainWindow()
    }

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

    // MARK: Settings

    /// Settings is a section of the main window, not a window of its own — one
    /// window holds the configuration and the data it configures. Menu / ⌘, target.
    @objc func openSettings() {
        showSection(.settings)
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

    /// The menu-bar item: the per-provider strip (brand mark + stacked readings)
    /// as a template image, plus a title carrying a green "▶N" active-sessions
    /// indicator and a coloured "⚠︎N" badge (tinted by the highest active severity
    /// — critical red, warning orange, info blue). Those two stay text precisely
    /// because their colour carries meaning a template image would flatten.
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

        // The per-provider readout (brand mark + stacked percentages) is drawn as a
        // template IMAGE, not text: two percentages have to stack on two tight
        // lines to fit, which an attributed string can't do. The title keeps only
        // the coloured badges, whose meaning is carried by their colour.
        let strip = MenuBarStripRenderer.image(for: store.menuBarItems)
        button.image = strip ?? Self.menuBarImage()
        button.image?.isTemplate = true

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

