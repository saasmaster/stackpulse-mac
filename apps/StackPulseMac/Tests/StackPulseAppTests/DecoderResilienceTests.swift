import Foundation
import Testing
@testable import StackPulseApp

/// Pins the decoder-resilience fixes: a single malformed element (or a leaner
/// future core) must degrade gracefully, never collapse the whole snapshot or —
/// worse — turn a decode error into a false "all clear".
@Suite("Decoder resilience")
struct DecoderResilienceTests {

    private func decode(_ json: String) -> UsageSnapshot? {
        try? JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }

    private func base(providers: String, alerts: String = "[]") -> String {
        """
        {"protocol_version":{"major":1,"minor":20,"patch":0},"core_version":"t",
         "generated_at_unix":0,"bucket_date_utc":"2026-07-17","pricing_note":"",
         "providers":[\(providers)],"alerts":\(alerts),"missions":[],"insights":[],"canaries":[]}
        """
    }

    private func provider(_ extra: String) -> String {
        """
        {"provider":"claude","display_name":"Claude","health":"fully_supported",
         "installed":true,"authenticated":true \(extra)}
        """
    }

    // MARK: ProviderUsage tolerance

    @Test("a provider missing its collection fields degrades to empty, not a whole-snapshot failure")
    func leanProviderStillDecodes() {
        // No windows/models/limits/capabilities/notes — a leaner core. The old
        // required decode would throw and fail the ENTIRE snapshot to nil.
        let snap = decode(base(providers: provider("")))
        #expect(snap != nil)
        #expect(snap?.providers.first?.windows.isEmpty == true)
        #expect(snap?.providers.first?.provider == "claude")
    }

    @Test("a provider missing a load-bearing scalar is genuinely malformed")
    func missingIdStillFailsThatDecode() {
        // No `provider` id — that IS malformed, not merely lean, so it must not
        // silently become a blank provider. The lossy array in the snapshot means
        // the bad provider drops rather than nuking everything… but ProviderUsage
        // itself must still refuse it.
        let bad = """
        {"display_name":"x","health":"ok","installed":true,"authenticated":true}
        """
        #expect((try? JSONDecoder().decode(ProviderUsage.self, from: Data(bad.utf8))) == nil)
    }

    // MARK: Lossy arrays — one bad element doesn't empty the array

    @Test("one malformed alert does not collapse the inbox to empty (false all-clear)")
    func oneBadAlertKeepsTheRest() {
        // Two alerts; the first is missing required fields. The old `try?` on the
        // whole array would drop BOTH → an empty inbox the bell renders as
        // "all clear", hiding the second, real alert.
        let alerts = """
        [ {"garbage":true},
          {"id":"a2","provider":"claude","severity":"critical","kind":"usage_threshold",
           "title":"Weekly limit at 96%","detail":"...","created_at_unix":0} ]
        """
        let snap = decode(base(providers: provider(""), alerts: alerts))
        #expect(snap != nil)
        #expect(snap?.alerts.count == 1, "the valid alert survives its malformed sibling")
        #expect(snap?.alerts.first?.id == "a2")
    }

    @Test("an all-valid alert array decodes every element")
    func validAlertsAllDecode() {
        let alerts = """
        [ {"id":"a1","provider":"claude","severity":"warning","kind":"usage_threshold","title":"t1","detail":"d","created_at_unix":0},
          {"id":"a2","provider":"codex","severity":"critical","kind":"usage_threshold","title":"t2","detail":"d","created_at_unix":0} ]
        """
        #expect(decode(base(providers: provider(""), alerts: alerts))?.alerts.count == 2)
    }
}
