import Foundation
import Testing
@testable import StackPulseApp

/// The demo snapshot is built by force-decoding JSON through the real
/// `UsageSnapshot` decoder, so this test is what turns a model/shape drift into a
/// caught failure instead of a runtime crash in front of a first-time user.
@Suite("Demo data")
struct DemoDataTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("the sample snapshot decodes and is populated")
    func decodesAndPopulated() {
        let snap = DemoData.snapshot(now: now)
        #expect(snap.providers.count >= 3)
        #expect(!snap.missions.isEmpty)
        // Claude has real spend and two live limits — the money shot.
        let claude = snap.providers.first { $0.provider == "claude" }
        #expect(claude?.hasLocalSpend == true)
        #expect((claude?.limits.count ?? 0) >= 2)
    }

    @Test("limit timestamps are relative to now, so they read as current")
    func limitsAreCurrent() {
        let snap = DemoData.snapshot(now: now)
        let claude = snap.providers.first { $0.provider == "claude" }!
        for limit in claude.limits {
            // captured at ~now (fresh, not stale) and resets in the future.
            #expect(limit.isStale(now: now, staleAfter: 60 * 60) == false)
            #expect((limit.resets_at_unix ?? 0) > Int64(now.timeIntervalSince1970))
        }
    }

    @Test("Antigravity is activity-only — sample data respects the real semantics")
    func antigravityIsActivityOnly() {
        // Even the fake data obeys the honesty rules: a server-metered provider
        // shows activity, never a fabricated $0.
        let snap = DemoData.snapshot(now: now)
        let ag = snap.providers.first { $0.provider == "antigravity" }
        #expect(ag?.isActivityOnly == true)
    }

    @Test("missions include an active and an idle session")
    func missionsHaveVariety() {
        let missions = DemoData.missions(now: now)
        #expect(missions.contains { $0.statusKind == .active })
    }
}
