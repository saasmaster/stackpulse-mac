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

// A custom `init(from:)` in an extension (so the memberwise initializer is kept)
// that tolerates a missing `safety` key. `safety` was added after the first
// releases, and Swift's *synthesized* `Decodable` ignores a stored-property
// default value — it emits a required `decode(_:forKey:)`, so a `command_runs.json`
// written before the field existed throws `keyNotFound`. `loadCommandRuns` decodes
// the whole array at once, so that one throw collapses the entire array to empty
// and the next persist overwrites the file — silently wiping the run history.
extension CommandRun {
    private enum CodingKeys: String, CodingKey {
        case id, label, command, cwd, safety, projectName
        case startedAtUnix, finishedAtUnix, exitCode, status, outputTail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        command = try c.decode(String.self, forKey: .command)
        cwd = try c.decode(String.self, forKey: .cwd)
        // The one field that must tolerate absence — default to the safest class.
        safety = try c.decodeIfPresent(String.self, forKey: .safety) ?? "read_only"
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        startedAtUnix = try c.decode(Double.self, forKey: .startedAtUnix)
        finishedAtUnix = try c.decodeIfPresent(Double.self, forKey: .finishedAtUnix)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        status = try c.decode(Status.self, forKey: .status)
        outputTail = try c.decode([String].self, forKey: .outputTail)
    }
}
