import Foundation
import Testing
@testable import StackPulseApp

/// The forecast is only worth showing if it refuses to make things up. These pin
/// the honesty rules: not enough data forecasts nothing, a reset is a
/// discontinuity (never a negative rate), a flat pace says "won't hit it", and a
/// projected hit past the reset is reported as clearing the window.
@Suite("Limit forecast")
struct LimitForecastTests {

    private let hour: Double = 3600
    /// A fixed "now" so tests are deterministic.
    private let now: Double = 1_770_000_000

    /// Samples counting up from `startPct` at `ratePerHour`, one every `stepMin`
    /// minutes, ending at `now`.
    private func rising(from startPct: Double, ratePerHour: Double,
                        count: Int, stepMin: Double = 5) -> [LimitSample] {
        let step = stepMin * 60
        let firstT = now - Double(count - 1) * step
        return (0..<count).map { i in
            let t = firstT + Double(i) * step
            let pct = startPct + ratePerHour * ((t - firstT) / hour)
            return LimitSample(windowKey: "weekly", capturedAtUnix: t, usedPercent: pct)
        }
    }

    // MARK: Refuses to forecast on thin data

    @Test("a single reading forecasts nothing")
    func oneSampleIsInsufficient() {
        let r = LimitForecast.project(
            samples: [LimitSample(windowKey: "weekly", capturedAtUnix: now, usedPercent: 20)],
            currentPercent: 20, resetAtUnix: nil, windowMinutes: 10080, now: now)
        #expect(r.confidence == .none)
        #expect(r.hoursToLimit == nil)
    }

    @Test("two readings seconds apart forecast nothing — the span is too short")
    func tooShortASpanIsInsufficient() {
        let s = [
            LimitSample(windowKey: "weekly", capturedAtUnix: now - 30, usedPercent: 20),
            LimitSample(windowKey: "weekly", capturedAtUnix: now, usedPercent: 21),
        ]
        let r = LimitForecast.project(samples: s, currentPercent: 21,
                                      resetAtUnix: nil, windowMinutes: 10080, now: now)
        #expect(r.confidence == .none)
    }

    // MARK: A real trend projects

    @Test("a steady climb projects the hours to 100% from the measured rate")
    func steadyClimbProjects() {
        // 10 %/hour, currently 50% → 5 hours to 100%.
        let s = rising(from: 20, ratePerHour: 10, count: 8, stepMin: 10)
        let current = s.last!.usedPercent
        let r = LimitForecast.project(samples: s, currentPercent: current,
                                      resetAtUnix: nil, windowMinutes: 10080, now: now)
        #expect(r.confidence == .ok)
        #expect(abs(r.ratePerHour - 10) < 0.5)
        let expectedHours = (100 - current) / 10
        #expect(r.hoursToLimit != nil)
        #expect(abs((r.hoursToLimit ?? 0) - expectedHours) < 0.3)
    }

    // MARK: "Won't hit it" is a real answer

    @Test("a flat pace forecasts no hit, not a divide-by-zero or a huge number")
    func flatPaceForecastsNoHit() {
        let s = (0..<6).map { i in
            LimitSample(windowKey: "weekly", capturedAtUnix: now - Double(5 - i) * 600,
                        usedPercent: 30) // never moves
        }
        let r = LimitForecast.project(samples: s, currentPercent: 30,
                                      resetAtUnix: nil, windowMinutes: 10080, now: now)
        #expect(r.hoursToLimit == nil)
        #expect(r.willHitBeforeReset == false)
        #expect(r.confidence != .none)
    }

    @Test("a projected hit after the reset is reported as clearing the window")
    func hitAfterResetClearsTheWindow() {
        // 2 %/hour from 50% → 25 hours to 100%, but the window resets in 5 hours.
        let s = rising(from: 40, ratePerHour: 2, count: 8, stepMin: 10)
        let current = s.last!.usedPercent
        let reset = now + 5 * hour
        let r = LimitForecast.project(samples: s, currentPercent: current,
                                      resetAtUnix: reset, windowMinutes: 10080, now: now)
        #expect(r.hoursToLimit != nil)
        #expect(r.willHitBeforeReset == false, "the reset comes first")
    }

    @Test("a hit before the reset is flagged")
    func hitBeforeResetIsFlagged() {
        // 15 %/hour from ~50% → ~3 hours; reset is 8 hours out.
        let s = rising(from: 20, ratePerHour: 15, count: 8, stepMin: 6)
        let current = s.last!.usedPercent
        let r = LimitForecast.project(samples: s, currentPercent: current,
                                      resetAtUnix: now + 8 * hour, windowMinutes: 10080, now: now)
        #expect(r.willHitBeforeReset == true)
    }

    // MARK: A reset is a discontinuity, never a negative rate

    @Test("samples from before a reset are dropped, not fitted across the drop")
    func resetIsADiscontinuity() {
        // Old cycle climbed to 90%, then reset to 5% and climbed again. Fitting the
        // whole thing would give a huge negative slope; the forecast must use only
        // the post-reset tail.
        var s: [LimitSample] = []
        for i in 0..<5 { s.append(LimitSample(windowKey: "weekly",
                                              capturedAtUnix: now - Double(9 - i) * 600,
                                              usedPercent: 70 + Double(i) * 5)) } // 70→90
        for i in 0..<5 { s.append(LimitSample(windowKey: "weekly",
                                              capturedAtUnix: now - Double(4 - i) * 600,
                                              usedPercent: 5 + Double(i) * 4)) }  // 5→21 after reset
        let r = LimitForecast.project(samples: s, currentPercent: 21,
                                      resetAtUnix: nil, windowMinutes: 10080, now: now)
        #expect(r.ratePerHour > 0, "must forecast from the post-reset climb, not across the drop")
        #expect(r.hoursToLimit != nil)
    }

    // MARK: Already maxed

    @Test("at 100% the forecast says it's already there")
    func alreadyAtLimit() {
        let r = LimitForecast.project(samples: [], currentPercent: 100,
                                      resetAtUnix: now + hour, windowMinutes: 300, now: now)
        #expect(r.hoursToLimit == 0)
        #expect(r.willHitBeforeReset == true)
    }

    // MARK: Presentation

    @Test("the label leads with the reason when there's nothing to project")
    func labelSurfacesReason() {
        let r = LimitForecast.Result.insufficient("Need a few more readings.")
        #expect(LimitForecast.label(r) == "Need a few more readings.")
    }

    @Test("hours are shown coarsely, never with false precision")
    func humanHoursIsCoarse() {
        #expect(LimitForecast.humanHours(0.5) == "30 min")
        #expect(LimitForecast.humanHours(5.2) == "5 hr")
        #expect(LimitForecast.humanHours(48) == "2 days")
    }
}
