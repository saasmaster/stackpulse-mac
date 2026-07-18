import Foundation
import Testing
@testable import StackPulseApp

/// Pins the shared subprocess-deadline helper — the one place that owns the
/// `availableData`-can't-time-out subtlety. The timeout path is the whole reason
/// this exists, so it's the one most worth a test.
@Suite("Bounded process")
struct BoundedProcessTests {

    @Test("captures stdout of a fast process")
    func capturesStdout() {
        let outcome = BoundedProcess.run(
            executable: "/bin/echo", arguments: ["hello"], timeout: 5)
        #expect(outcome?.timedOut == false)
        #expect(outcome?.trimmedText == "hello")
        #expect(outcome?.exitStatus == 0)
    }

    @Test("a process that outlives the deadline is killed and reported as timed out")
    func enforcesTheDeadline() {
        // `sleep 30` produces no output and holds stdout open — exactly the shape
        // (silent, long-lived) that defeated the old poll-loop timeout. A 0.3s
        // deadline must actually fire here.
        let start = Date()
        let outcome = BoundedProcess.run(
            executable: "/bin/sleep", arguments: ["30"], timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        #expect(outcome?.timedOut == true)
        #expect(outcome?.trimmedText == nil, "a timed-out run yields no usable text")
        #expect(elapsed < 5, "must return near the deadline, not after sleep finishes")
    }

    @Test("a non-launchable executable returns nil, not a crash")
    func missingExecutableIsNil() {
        #expect(BoundedProcess.run(
            executable: "/nonexistent/binary", arguments: [], timeout: 1) == nil)
    }

    @Test("a non-zero exit yields no usable text")
    func nonZeroExitHasNoText() {
        // `false` exits 1 with no output.
        let outcome = BoundedProcess.run(executable: "/usr/bin/false", arguments: [], timeout: 5)
        #expect(outcome?.timedOut == false)
        #expect(outcome?.exitStatus != 0)
        #expect(outcome?.trimmedText == nil)
    }
}
