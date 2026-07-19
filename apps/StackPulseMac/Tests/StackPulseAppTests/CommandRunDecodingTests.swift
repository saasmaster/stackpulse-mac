import Foundation
import Testing
@testable import StackPulseApp

/// Pins the `CommandRun` decoder tolerance. `safety` was added after the first
/// releases with a default value — but Swift's *synthesized* `Decodable` ignores
/// stored-property defaults, so a `command_runs.json` written before the field
/// existed used to throw `keyNotFound`. Because `loadCommandRuns` decodes the
/// whole array at once, that single throw collapsed the entire run history to
/// empty and the next persist overwrote the file — a silent, permanent wipe.
@Suite("CommandRun decoding")
struct CommandRunDecodingTests {

    /// A run object with NO `safety` key (an older on-disk record) must still
    /// decode, defaulting to the safest class — not throw and take the array down.
    @Test("a run missing the safety field still decodes, defaulting to read_only")
    func missingSafetyDecodes() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","label":"Test",
         "command":"npm test","cwd":"/tmp/p","projectName":"p",
         "startedAtUnix":1000,"status":"passed","outputTail":["ok"]}
        """
        let run = try JSONDecoder().decode(CommandRun.self, from: Data(json.utf8))
        #expect(run.safety == "read_only")
        #expect(run.status == .passed)
        #expect(run.label == "Test")
    }

    /// The real failure mode: an array where an OLD record (no `safety`) sits
    /// beside a new one. The whole array must survive — the old-format bug dropped
    /// every run, not just the legacy element.
    @Test("an array mixing legacy and new records decodes every element")
    func mixedArrayFullyDecodes() throws {
        let json = """
        [ {"id":"11111111-1111-1111-1111-111111111111","label":"Old","command":"make",
           "cwd":"/tmp/a","startedAtUnix":10,"status":"failed","outputTail":[]},
          {"id":"22222222-2222-2222-2222-222222222222","label":"New","command":"npm test",
           "cwd":"/tmp/b","safety":"destructive","startedAtUnix":20,"status":"passed",
           "outputTail":["done"]} ]
        """
        let runs = try JSONDecoder().decode([CommandRun].self, from: Data(json.utf8))
        #expect(runs.count == 2, "the legacy record must not collapse the whole array")
        #expect(runs[0].safety == "read_only")   // defaulted
        #expect(runs[1].safety == "destructive")  // preserved
    }

    /// A present `safety` value is preserved exactly (the gate must not be lost on
    /// a round-trip) — encode then decode.
    @Test("safety survives an encode/decode round-trip")
    func roundTripPreservesSafety() throws {
        let original = CommandRun(
            id: UUID(), label: "Deploy", command: "./deploy.sh", cwd: "/tmp/p",
            safety: "destructive", projectName: "p", startedAtUnix: 1, finishedAtUnix: 2,
            exitCode: 0, status: .passed, outputTail: ["ok"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CommandRun.self, from: data)
        #expect(decoded.safety == "destructive")
        #expect(decoded == original)
    }
}
