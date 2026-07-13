import Darwin
import Foundation

/// Safe, explicit control over the locally-running dev servers StackPulse
/// detected. The only mutating action is **Stop**, always gated behind a
/// confirmation dialog at the call site and only ever aimed at a process the
/// user started. Sends `SIGTERM` (graceful — the server can clean up and free
/// its port), never `SIGKILL`. Nothing here runs on a timer or without a tap.
enum ServiceControl {
    /// Ask a process to terminate gracefully (SIGTERM). Returns whether the signal
    /// was delivered (`false` when the pid is already gone or not ours to signal).
    @discardableResult
    static func stop(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), SIGTERM) == 0
    }
}
