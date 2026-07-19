import Foundation
import Testing
@testable import StackPulseApp

/// Cursor publishes no individual usage API, so its own dashboard endpoints are
/// the only source. These pin the parsing rules that keep that honest: a meter
/// Cursor didn't report is DROPPED (never rendered as 0%), on-demand spend that
/// wasn't reported stays `nil` (absence ≠ a measured $0.00), and the billing
/// cycle Cursor gives us is used verbatim rather than assumed to be a month.
@Suite("Cursor live usage")
struct CursorUsageTests {

    @Test("the parser self-test passes (meters, billing cycle, extra usage, JWT)")
    func selftestPasses() {
        #expect(CursorUsageClient._selftest())
    }

    @Test("a meter Cursor didn't report is dropped, not shown as 0%")
    func missingMeterIsDropped() {
        let json = """
        { "planUsage": { "totalPercentUsed": 42.0, "billingCycleEnd": 1752592000000 } }
        """
        let out = CursorUsageClient.parseUsage(Data(json.utf8), capturedAt: 99)
        #expect(out.limits.count == 1)
        #expect(out.limits.first?.label == "cursor_total")
        // auto/api absent → no window at all, rather than a fabricated 0%.
        #expect(!out.limits.contains { $0.label == "cursor_auto" })
        #expect(!out.limits.contains { $0.label == "cursor_api" })
    }

    @Test("the reading carries its capture time so it can't pass as current forever")
    func readingIsTimestamped() {
        let json = #"{"planUsage":{"totalPercentUsed":10.0}}"#
        let out = CursorUsageClient.parseUsage(Data(json.utf8), capturedAt: 1_752_000_000)
        #expect(out.limits.first?.captured_at_unix == 1_752_000_000)
        #expect(out.limits.first?.provenance == CursorUsageClient.liveProvenance)
    }

    @Test("a 100%-used meter is a real reading, not clamped away")
    func limitReachedSurvives() {
        let json = #"{"planUsage":{"apiPercentUsed":100.0}}"#
        let out = CursorUsageClient.parseUsage(Data(json.utf8), capturedAt: 1)
        #expect(out.limits.first?.used_percent == 100)
        // The UI renders this as "0% left" — the openusage "Limit reached" case.
        #expect(Format.limitLeft(out.limits[0].used_percent) == "0% left")
    }

    @Test("garbage degrades to no reading, never to a fabricated one")
    func garbageDegrades() {
        #expect(CursorUsageClient.parseUsage(Data("not json".utf8), capturedAt: 0).limits.isEmpty)
        #expect(CursorUsageClient.parseUsage(Data("{}".utf8), capturedAt: 0).limits.isEmpty)
        #expect(CursorUsageClient.userID(fromJWT: "not-a-jwt") == nil)
    }

    @Test("the dashboard session cookie is rebuilt from the token's own subject")
    func cookieDerivation() {
        // {"sub":"auth0|user_abc"} base64url-encoded as the JWT payload.
        let jwt = "h.eyJzdWIiOiJhdXRoMHx1c2VyX2FiYyJ9.s"
        #expect(CursorUsageClient.userID(fromJWT: jwt) == "user_abc")
        #expect(CursorUsageClient.sessionCookie(userID: "user_abc", token: "TOK")
                == "WorkosCursorSessionToken=user_abc%3A%3ATOK")
    }
}
