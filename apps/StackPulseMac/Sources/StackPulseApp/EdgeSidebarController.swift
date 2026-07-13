import AppKit
import Combine
import SwiftUI

/// Owns the always-available edge sidebar: a non-activating floating `NSPanel`
/// pinned to the right edge of the active screen, hosting ``SidebarView`` over
/// the shared ``SnapshotStore``.
///
/// The panel never steals focus (`.nonactivatingPanel`, does not become key),
/// rides along across Spaces and full-screen apps, and re-pins itself when the
/// screen layout changes. Shown state is remembered for the app session.
@MainActor
final class EdgeSidebarController {
    private let store: SnapshotStore
    private let theme: ThemeManager
    private let onOpenMainWindow: () -> Void

    private var panel: NSPanel?
    private var screenObserver: (any NSObjectProtocol)?
    private var cancellables: Set<AnyCancellable> = []

    private let panelWidth: CGFloat = 320

    /// Whether the sidebar is currently on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: SnapshotStore, theme: ThemeManager, onOpenMainWindow: @escaping () -> Void) {
        self.store = store
        self.theme = theme
        self.onOpenMainWindow = onOpenMainWindow
        // Re-pin the panel live when the user flips the sidebar edge (from the
        // quick toggle or Settings). Fires on the current value too, which is a
        // no-op when the panel isn't visible yet.
        store.$sidebarOnLeft
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel)
            }
            .store(in: &cancellables)
    }

    // MARK: Visibility

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = ensurePanel()
        position(panel)
        store.refresh()
        panel.orderFrontRegardless()   // appears without activating the app
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(
            rootView: SidebarView(
                onClose: { [weak self] in self?.hide() },
                onOpenMainWindow: { [weak self] in self?.onOpenMainWindow() }
            )
            .environmentObject(store)
            .environmentObject(theme)
        )
        panel.contentView = host

        self.panel = panel
        observeScreenChanges()
        return panel
    }

    // MARK: Layout

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = store.sidebarOnLeft ? visible.minX : visible.maxX - panelWidth
        let frame = NSRect(
            x: x,
            y: visible.minY,
            width: panelWidth,
            height: visible.height
        )
        panel.setFrame(frame, display: true)
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The .main queue guarantees main-thread delivery.
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel)
            }
        }
    }
}
