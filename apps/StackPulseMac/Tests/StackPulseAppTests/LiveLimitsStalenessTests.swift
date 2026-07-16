import Foundation
import Testing
@testable import StackPulseApp

/// The rule that failed in the field, pinned.
///
/// StackPulse displayed **82% for 70 hours** after that window had already reset,
/// because a cached value was shown for up to 3 days and the check for "has this
/// window reset?" read the cached `resets_at` — part of the same stale snapshot.
/// Stale data cannot adjudicate its own freshness. Age is the only honest guard.
@Suite("Live-limits staleness")
struct LiveLimitsStalenessTests {
    let hour: TimeInterval = 60 * 60

    @Test("a 70-hour-old reading is never trustworthy")
    func seventyHoursIsStale() {
        let now = Date()
        #expect(!SnapshotStore.cachedLimitsAreTrustworthy(
            capturedAt: now.addingTimeInterval(-70 * hour), now: now, staleAfter: hour))
    }

    /// Never captured ⇒ never fresh. An absent timestamp is unknown, not "now".
    @Test("a reading we never captured is not fresh by default")
    func nilIsNotFresh() {
        #expect(!SnapshotStore.cachedLimitsAreTrustworthy(
            capturedAt: nil, now: Date(), staleAfter: hour))
    }

    /// The refetch interval is 8 minutes, so the bound must absorb a 429 or a
    /// closed laptop across several consecutive failures.
    @Test("a momentary blip still rides on the last good value")
    func recentIsTrusted() {
        let now = Date()
        #expect(SnapshotStore.cachedLimitsAreTrustworthy(
            capturedAt: now.addingTimeInterval(-5 * 60), now: now, staleAfter: hour))
    }

    @Test("the boundary is exact on both sides")
    func boundary() {
        let now = Date()
        #expect(SnapshotStore.cachedLimitsAreTrustworthy(
            capturedAt: now.addingTimeInterval(-59 * 60), now: now, staleAfter: hour))
        #expect(!SnapshotStore.cachedLimitsAreTrustworthy(
            capturedAt: now.addingTimeInterval(-61 * 60), now: now, staleAfter: hour))
    }
}

/// Per-reading staleness (protocol 1.20.0). Codex's limits come from log files and
/// were **18.5 hours old** on a real machine while rendering as current, because
/// nothing on the wire said when the reading was taken.
@Suite("LimitWindow age")
struct LimitWindowAgeTests {
    func window(capturedAt: Int64?, resetsAt: Int64?) -> LimitWindow {
        LimitWindow(label: "weekly", used_percent: 32, window_minutes: 10_080,
                    resets_at_unix: resetsAt, provenance: "provider_reported",
                    captured_at_unix: capturedAt)
    }

    @Test("an 18-hour-old reading is stale even though its reset is days away")
    func staleDespiteFutureReset() {
        let now = Date()
        let w = window(capturedAt: Int64(now.timeIntervalSince1970) - Int64(18.5 * 3600),
                       resetsAt: Int64(now.timeIntervalSince1970) + 3 * 86_400)
        // The exact trap: `resets_at` is in the future, so every reset-based check
        // passes it as current. Only age catches it.
        #expect(w.isStale(now: now, staleAfter: 3600))
        #expect(w.resets_at_unix! > Int64(now.timeIntervalSince1970))
    }

    @Test("age is reported from the reading's own capture time")
    func ageIsReal() {
        let now = Date()
        let w = window(capturedAt: Int64(now.timeIntervalSince1970) - 7200, resetsAt: nil)
        let age = try! #require(w.age(now: now))
        #expect(abs(age - 7200) < 1)
    }

    @Test("a fresh reading is not stale")
    func freshIsNotStale() {
        let now = Date()
        let w = window(capturedAt: Int64(now.timeIntervalSince1970) - 60, resetsAt: nil)
        #expect(!w.isStale(now: now, staleAfter: 3600))
        #expect(w.age(now: now)! < 120)
    }

    /// A source that didn't timestamp its reading tells us nothing. We must not
    /// claim it is stale — but `LimitAgeNote` also draws nothing, so we never
    /// present an unknown-age number as "measured just now" either.
    @Test("an untimestamped reading has unknown age and makes no staleness claim")
    func unknownAge() {
        let w = window(capturedAt: nil, resetsAt: nil)
        #expect(w.age() == nil)
        #expect(!w.isStale(staleAfter: 3600))
    }
}
