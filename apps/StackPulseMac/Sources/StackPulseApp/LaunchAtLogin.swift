import Foundation
import ServiceManagement

/// Whether StackPulse starts itself when the user logs in.
///
/// The OS owns this state — `SMAppService.mainApp` registers a login item that
/// macOS persists and the user can also toggle in System Settings → General →
/// Login Items. So this type stores **nothing**: it reads the live status and asks
/// the OS to change it. A cached bool would drift the moment the user flipped it in
/// System Settings, and then StackPulse's own switch would lie.
///
/// A menu-bar monitor is only useful if it's running, so this is the one
/// convenience that makes the app do its job without being launched by hand —
/// hence offering it in onboarding. It is still off until the user says yes.
enum LaunchAtLogin {

    /// True when the login item is registered and enabled right now.
    ///
    /// `.requiresApproval` (the user disabled it in System Settings) reads as
    /// **not enabled** — because it isn't, and a switch that showed "on" while the
    /// OS refused to launch us would be exactly the kind of confident-wrong state
    /// this app avoids. `statusDetail` names that case so the UI can explain it.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The registration succeeded/failed as a fact, not a hope. Returns `false`
    /// when the OS refused (unsigned build, sandbox quirk); the caller re-reads
    /// `isEnabled` rather than assuming the toggle took.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // register() is idempotent; calling it while already enabled is fine.
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// A plain-language line for the current status, used by the diagnostics-style
    /// note under the toggle. Never a hope — it reports what the OS says now.
    static var statusDetail: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "StackPulse opens automatically when you log in."
        case .requiresApproval:
            return "Turned on here, but macOS is holding it — approve StackPulse in System Settings → General → Login Items."
        case .notRegistered:
            return "StackPulse won't start on its own — open it from Applications or Spotlight."
        case .notFound:
            return "Not available — StackPulse isn't installed where macOS can register a login item (run it from /Applications)."
        @unknown default:
            return "Login-item status is unavailable."
        }
    }

    /// True when the OS is holding the login item pending the user's approval in
    /// System Settings — a state the toggle must surface rather than swallow.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
