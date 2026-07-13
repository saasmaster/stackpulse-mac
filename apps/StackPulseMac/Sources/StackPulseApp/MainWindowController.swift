import AppKit
import SwiftUI

/// Retained controller for the main application window.
///
/// The app is a menu-bar accessory, so this window is created lazily the first
/// time the user asks to open it and then reused. It never quits the app when
/// closed — `AppDelegate` flips the activation policy back to `.accessory` via
/// the `onClose` callback so the status item lives on.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let store: SnapshotStore
    private let theme: ThemeManager
    private let onClose: () -> Void

    init(store: SnapshotStore, theme: ThemeManager, onClose: @escaping () -> Void) {
        self.store = store
        self.theme = theme
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "StackPulse"
        window.isReleasedWhenClosed = false          // reusable across opens
        window.minSize = NSSize(width: 720, height: 480)
        window.tabbingMode = .disallowed

        let host = NSHostingController(
            rootView: MainWindowView()
                .environmentObject(store)
                .environmentObject(theme)
        )
        window.contentViewController = host

        // Restore the remembered frame if we have one; otherwise center.
        if !window.setFrameUsingName("StackPulseMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("StackPulseMainWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Refresh, bring the app forward, and show/focus the window.
    func show() {
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
