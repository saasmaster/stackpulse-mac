import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Delivers macOS notifications for needs-attention alerts.
///
/// Local-first and privacy-preserving: it only ever surfaces an alert the core
/// (or the live-limits synthesizer) already produced from the user's own local
/// data — it originates nothing and contacts no network. Authorization is
/// requested lazily and a denied/unavailable state is never an error: the rest
/// of StackPulse works unchanged, notifications simply stay silent.
///
/// The gating logic (what's *newly* worth notifying, and quiet-hours) lives in
/// the pure ``NotificationGate`` so it's headlessly self-testable without any
/// system calls; this class is only the thin AppKit bridge around it.
@MainActor
final class NotificationManager: NSObject {
    /// Invoked when the user clicks a delivered notification. The AppDelegate
    /// wires this to open the main window on the needs-attention section.
    var onOpen: (() -> Void)?

    /// Reports the effective OS-level authorization (granted or not) after a
    /// request or a status check, so Settings can hint when banners are blocked
    /// in System Settings. Always delivered on the main actor.
    var onAuthorizationResolved: ((Bool) -> Void)?

    /// True only inside a real `.app` bundle. Running the bare SwiftPM executable
    /// (`swift run`, the `--selftest-*` flags) has no bundle id, and touching
    /// `UNUserNotificationCenter` there traps — so every system call is gated here.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private var center: UNUserNotificationCenter? {
        isAvailable ? UNUserNotificationCenter.current() : nil
    }

    /// Installs the delegate so notifications present while the app is active and
    /// clicks route back through `onOpen`. Call once on launch.
    func configure() {
        center?.delegate = self
    }

    /// Requests alert + sound authorization (the system prompts only the first
    /// time; later calls just resolve the current status). Reports the result via
    /// `onAuthorizationResolved`. Unavailable/denied resolves to `false`.
    ///
    /// The actual center call goes through a `nonisolated static` helper: this
    /// class is `@MainActor`, and UserNotifications' Objective-C completion
    /// bridge, if invoked from a main-actor-isolated context, resumes its
    /// continuation with a main-actor isolation check that traps when the daemon
    /// fires it on a background queue. Running it nonisolated avoids that; we hop
    /// back to the main actor only to publish the result.
    func requestAuthorization() {
        Task { [weak self] in
            let granted = await Self.requestAuthorizationRaw()
            await MainActor.run { self?.onAuthorizationResolved?(granted) }
        }
    }

    /// Reads the current authorization without prompting, reporting via
    /// `onAuthorizationResolved`. Used on launch when notifications are enabled in
    /// the app but we don't want to force the system prompt.
    func refreshAuthorizationStatus() {
        Task { [weak self] in
            let ok = await Self.authorizationOKRaw()
            await MainActor.run { self?.onAuthorizationResolved?(ok) }
        }
    }

    /// Nonisolated so the bridged completion doesn't inherit main-actor isolation
    /// (see `requestAuthorization`). Returns whether authorization was granted.
    private nonisolated static func requestAuthorizationRaw() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Nonisolated status read (see `requestAuthorization`). Returns whether the
    /// current status permits delivering notifications.
    private nonisolated static func authorizationOKRaw() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Posts (or replaces, keyed by the alert id) a system notification for one
    /// alert. Critical alerts carry a sound and a time-sensitive interruption
    /// level; lower severities are quiet banners.
    func deliver(_ alert: Alert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.threadIdentifier = "stackpulse.alerts.\(alert.provider)"
        if alert.severityKind == .critical {
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        } else {
            content.interruptionLevel = .active
        }
        // Identifier = the alert id, so re-delivering a still-active alert later
        // replaces its prior banner instead of stacking duplicates.
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// Clears StackPulse's delivered notifications from Notification Center — used
    /// when the user turns notifications off.
    func clearDelivered() {
        center?.removeAllDeliveredNotifications()
    }

    /// Requests authorization if needed, then posts a one-off test banner so the
    /// user can confirm notifications work (and grant permission on first use).
    /// Reports the resolved authorization via `onAuthorizationResolved`. Safe no-op
    /// when notifications are unavailable (no bundle).
    func sendTest() {
        Task { [weak self] in
            let granted = await Self.requestAuthorizationRaw()
            await MainActor.run {
                self?.onAuthorizationResolved?(granted)
                guard granted else { return }
                self?.deliver(Alert(
                    id: "stackpulse.test",
                    provider: "claude",
                    severity: "info",
                    kind: "other",
                    title: "StackPulse test notification",
                    detail: "Notifications are working — you'll be alerted when something needs attention.",
                    created_at_unix: 0
                ))
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Present banners even while StackPulse is the active app (it's a menu-bar
    /// accessory, so "active" is common and the user still wants to see alerts).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A click on the notification opens the app on the needs-attention section.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor in self.onOpen?() }
    }
}

// MARK: - Pure gating logic (headlessly testable, no system calls)

/// The decision layer for notifications, kept free of AppKit so it can be
/// self-tested deterministically (see ``NotificationManager/_selftest()``).
enum NotificationGate {
    /// Decide which alert ids to notify for this evaluation.
    ///
    /// The **first** evaluation (`seeded == false`) silently adopts whatever is
    /// currently active, so launching with pre-existing alerts never fires a burst
    /// of banners for things already visible in the popover. Afterwards only ids
    /// that are newly present since the last evaluation are returned. The returned
    /// `notified` set is pruned to still-active ids (plus the fresh ones), so a
    /// condition that clears and later returns will notify again.
    static func transition(current: Set<String>, alreadyNotified: Set<String>, seeded: Bool)
        -> (toNotify: Set<String>, notified: Set<String>)
    {
        guard seeded else { return ([], current) }
        let fresh = current.subtracting(alreadyNotified)
        let stillActive = alreadyNotified.intersection(current)
        return (fresh, stillActive.union(fresh))
    }

    /// Whether `hour` (0–23) falls inside a quiet-hours window that may wrap past
    /// midnight (e.g. 22 → 8). An empty window (`start == end`) is "never quiet".
    static func isQuiet(hour: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }
}

extension NotificationManager {
    /// Pure self-test of ``NotificationGate`` (no system calls). Wired into the
    /// `--selftest-parsers` flag. Returns true iff every transition and
    /// quiet-hours case holds.
    static func _selftest() -> Bool {
        // First evaluation seeds silently (no burst on launch).
        let seed = NotificationGate.transition(current: ["a", "b"], alreadyNotified: [], seeded: false)
        guard seed.toNotify.isEmpty, seed.notified == ["a", "b"] else { return false }
        // A newly-appearing alert notifies exactly once.
        let appear = NotificationGate.transition(
            current: ["a", "b", "c"], alreadyNotified: ["a", "b"], seeded: true)
        guard appear.toNotify == ["c"], appear.notified == ["a", "b", "c"] else { return false }
        // A persisting alert does not re-notify; cleared ids drop out of the set.
        let persist = NotificationGate.transition(
            current: ["a"], alreadyNotified: ["a", "b", "c"], seeded: true)
        guard persist.toNotify.isEmpty, persist.notified == ["a"] else { return false }
        // A cleared alert that returns notifies again.
        let recur = NotificationGate.transition(
            current: ["a", "c"], alreadyNotified: ["a"], seeded: true)
        guard recur.toNotify == ["c"], recur.notified == ["a", "c"] else { return false }
        // Quiet hours wrapping midnight (22:00–08:00).
        guard NotificationGate.isQuiet(hour: 23, start: 22, end: 8),
              NotificationGate.isQuiet(hour: 2, start: 22, end: 8),
              !NotificationGate.isQuiet(hour: 8, start: 22, end: 8),
              !NotificationGate.isQuiet(hour: 12, start: 22, end: 8) else { return false }
        // Same-day window (01:00–06:00) and an empty window.
        guard NotificationGate.isQuiet(hour: 3, start: 1, end: 6),
              !NotificationGate.isQuiet(hour: 6, start: 1, end: 6),
              !NotificationGate.isQuiet(hour: 5, start: 9, end: 9) else { return false }
        return true
    }
}
