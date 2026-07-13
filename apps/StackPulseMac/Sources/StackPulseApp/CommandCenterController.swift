import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted from anywhere in the UI to open/focus the Command Center window;
    /// observed by `AppDelegate`.
    static let stackPulseOpenCommandCenter = Notification.Name("stackPulseOpenCommandCenter")
}

/// Retained controller for the large, separate Command Center monitoring window —
/// designed to live on a second display. Like the main window it is created
/// lazily, reused across opens, and never quits the app when closed. It shares the
/// single ``SnapshotStore`` and ``ThemeManager`` so it always mirrors live data.
@MainActor
final class CommandCenterController: NSWindowController, NSWindowDelegate {
    private let store: SnapshotStore
    private let theme: ThemeManager
    private let onClose: () -> Void

    /// Whether the window is currently on screen.
    var isVisible: Bool { window?.isVisible ?? false }

    init(store: SnapshotStore, theme: ThemeManager, onClose: @escaping () -> Void) {
        self.store = store
        self.theme = theme
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "StackPulse — Command Center"
        window.isReleasedWhenClosed = false          // reusable across opens
        window.minSize = NSSize(width: 900, height: 560)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]   // allow native full screen

        super.init(window: window)

        let host = NSHostingController(
            rootView: CommandCenterView(
                onMoveToScreen: { [weak self] index in self?.move(toScreenAt: index) },
                onToggleFullScreen: { [weak self] in self?.toggleFullScreen() }
            )
            .environmentObject(store)
            .environmentObject(theme)
        )
        window.contentViewController = host

        // Default to a generous frame if we have no remembered one.
        if !window.setFrameUsingName("StackPulseCommandCenter") {
            window.center()
        }
        window.setFrameAutosaveName("StackPulseCommandCenter")
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

    /// Menu toggle: hide when it's the focused visible window, otherwise show.
    func toggle() {
        if isVisible, window?.isKeyWindow == true {
            window?.performClose(nil)
        } else {
            show()
        }
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Move the window onto the screen at `index` in `NSScreen.screens`, filling
    /// that screen's visible frame.
    private func move(toScreenAt index: Int) {
        let screens = NSScreen.screens
        guard screens.indices.contains(index), let window else { return }
        window.setFrame(screens[index].visibleFrame, display: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
