import Foundation
import Testing
@testable import StackPulseApp

/// The live-limits payload parser.
///
/// `_selftest()` already covers this and runs in the shipping binary; these tests
/// exist because the self-test is one boolean — when it fails it says `FAIL` and
/// nothing else. These name the specific promise that broke.
@Suite("Anthropic usage parsing")
struct AnthropicUsageParsingTests {
    func parse(_ json: String, assumePercent: Bool = false) -> AnthropicUsageClient.ParsedUsage {
        AnthropicUsageClient.parseUsage(Data(json.utf8), assumePercentScale: assumePercent,
                                        capturedAt: Date(timeIntervalSince1970: 1_784_000_000))
    }
    func find(_ p: AnthropicUsageClient.ParsedUsage, _ label: String) -> LimitWindow? {
        p.limits.first { $0.label == label }
    }

    /// THE bug: the scale was decided per VALUE (`v <= 1 ? v*100 : v`), so one
    /// response was read as two scales at once — `12.5` passed through as 12.5%
    /// while `0.45` in the SAME body was multiplied to 45%. No API reports both
    /// scales in one payload, so at least one of those was wrong.
    @Test("one payload is read at ONE scale")
    func oneScalePerPayload() {
        let p = parse("""
        { "five_hour": { "utilization": 0.45 }, "seven_day": { "utilization": 12.5 } }
        """)
        // 12.5 can only be a percent ⇒ the payload is percent-scaled ⇒ 0.45 is
        // 0.45%, not 45%.
        #expect(p.provedPercentScale)
        #expect(find(p, "5h")!.used_percent == 0.45)
        #expect(find(p, "weekly")!.used_percent == 12.5)
    }

    /// A value above 1.0 is proof: a fraction cannot exceed 1.0.
    @Test("a value above 1.0 proves the percent scale")
    func provesPercent() {
        #expect(parse(#"{ "seven_day": { "utilization": 82 } }"#).provedPercentScale)
        #expect(!parse(#"{ "seven_day": { "utilization": 0.82 } }"#).provedPercentScale)
    }

    /// All-≤1.0 is genuinely ambiguous — 0.82 is either 82% or 0.82% and nothing
    /// in the body says which. This is exactly the state just after a reset.
    @Test("an ambiguous payload scales until the endpoint proves otherwise")
    func ambiguousScales() {
        let p = parse(#"{ "limits": [ { "kind": "seven_day", "percent": 0.82 } ] }"#)
        #expect(!p.provedPercentScale)
        #expect(find(p, "weekly")!.used_percent == 82)
    }

    /// ...and once proved, the same body reads as 0.82%. Without the remembered
    /// verdict this is a fake "you're nearly out" alert right after a reset.
    @Test("a learned percent scale fixes the post-reset reading")
    func learnedScale() {
        let p = parse(#"{ "limits": [ { "kind": "seven_day", "percent": 0.82 } ] }"#,
                      assumePercent: true)
        #expect(find(p, "weekly")!.used_percent == 0.82)
    }

    /// A malformed or error-shaped body must yield nothing — never a confident
    /// empty result that reads as "all clear".
    @Test("garbage degrades to no limits, never to a fabricated one")
    func garbage() {
        #expect(parse("not json").limits.isEmpty)
        #expect(parse("{}").limits.isEmpty)
        #expect(parse(#"{ "error": { "type": "authentication_error" } }"#).limits.isEmpty)
    }

    /// Every reading carries when it was taken (protocol 1.20.0) — that is what
    /// lets the UI age it instead of implying it is current.
    @Test("parsed limits are stamped with the capture time")
    func stamped() {
        let p = parse(#"{ "seven_day": { "utilization": 82 } }"#)
        #expect(find(p, "weekly")!.captured_at_unix == 1_784_000_000)
    }

    @Test("an inactive window is skipped")
    func inactiveSkipped() {
        let p = parse("""
        { "limits": [ { "kind": "seven_day", "percent": 82, "is_active": false },
                      { "kind": "five_hour", "percent": 5 } ] }
        """)
        #expect(find(p, "weekly") == nil)
        #expect(find(p, "5h") != nil)
    }
}
