import AppKit
import SwiftUI

/// Retained controller for the dedicated **Settings** window.
///
/// Settings live in their own window (like a standard macOS preferences window),
/// separate from the dashboards in the main window — configuration on one side,
/// data on the other. Created lazily, reused, and never quits the app when closed.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SnapshotStore
    private let theme: ThemeManager
    private let onClose: () -> Void

    init(store: SnapshotStore, theme: ThemeManager, onClose: @escaping () -> Void) {
        self.store = store
        self.theme = theme
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "StackPulse Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 460)
        window.tabbingMode = .disallowed

        let host = NSHostingController(
            rootView: SettingsWindowView()
                .environmentObject(store)
                .environmentObject(theme)
        )
        window.contentViewController = host

        if !window.setFrameUsingName("StackPulseSettingsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("StackPulseSettingsWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Bring the app forward and show/focus the Settings window, optionally
    /// selecting a specific tab (the view observes the notification).
    func show(tab: SettingsTab? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let tab {
            NotificationCenter.default.post(name: .stackPulseSelectSettingsTab, object: tab)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// The tabs of the Settings window.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case settings
    case integrations

    var id: String { rawValue }
    var title: String { self == .settings ? "Settings" : "Integrations" }
    var systemImage: String { self == .settings ? "gearshape" : "puzzlepiece.extension" }
}

extension Notification.Name {
    /// Any surface can request the Settings window via this notification.
    static let stackPulseOpenSettings = Notification.Name("stackPulseOpenSettings")
    /// Posted by the controller to switch the Settings window's tab.
    static let stackPulseSelectSettingsTab = Notification.Name("stackPulseSelectSettingsTab")
}
