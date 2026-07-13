import Foundation

/// A record of one command StackPulse ran and captured — the outcome (pass/fail),
/// timing, and a tail of the output. Persisted locally so you can glance back at
/// "did the tests pass last time?" without re-running. This is the app's own
/// action log (like the live-limits cache), not portable core data.
struct CommandRun: Codable, Identifiable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case running    // still executing
        case passed     // exited 0
        case failed     // exited non-zero
        case stopped    // user stopped it

        var isFinished: Bool { self != .running }
    }

    let id: UUID
    let label: String
    let command: String
    let cwd: String
    /// The original command's safety class, preserved so a re-run keeps its gate.
    var safety: String = "read_only"
    let projectName: String?
    let startedAtUnix: Double
    var finishedAtUnix: Double?
    var exitCode: Int32?
    var status: Status
    /// The last lines of combined stdout/stderr (capped), for a quick look back.
    var outputTail: [String]

    var startedAt: Date { Date(timeIntervalSince1970: startedAtUnix) }

    /// Wall-clock duration in seconds, if finished.
    var duration: TimeInterval? {
        finishedAtUnix.map { $0 - startedAtUnix }
    }
}
