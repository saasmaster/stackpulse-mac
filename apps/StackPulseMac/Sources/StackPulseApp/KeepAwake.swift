import Foundation

/// Prevents idle **system** sleep while StackPulse is actively monitoring, using
/// a single `ProcessInfo` activity assertion. This needs no entitlement and no
/// user permission — it is the same local mechanism `caffeinate` and media apps
/// use, and it is released automatically when the process exits.
///
/// The display is intentionally left free to sleep (`idleSystemSleepDisabled`
/// only), so the screen still dims normally; we merely keep the machine awake
/// enough for background scans to keep running.
@MainActor
final class KeepAwake {
    private var token: (any NSObjectProtocol)?

    /// Whether the assertion is currently held.
    var isActive: Bool { token != nil }

    /// Begin holding the assertion (idempotent).
    func start() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "StackPulse monitoring"
        )
    }

    /// Release the assertion (idempotent).
    func stop() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
