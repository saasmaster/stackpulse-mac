import Foundation

/// One reading of a rate-limit window's consumption, kept over time so the app can
/// see the *trajectory* — the only honest basis for "when will I hit this?".
///
/// Persisted (`limit_samples.json`) like the live-limits cache: it's the app's own
/// observation history, not portable core data.
struct LimitSample: Codable, Equatable, Sendable {
    /// The window this belongs to (the limit's `label`, e.g. `5h`, `weekly`).
    let windowKey: String
    let capturedAtUnix: Double
    let usedPercent: Double
}

/// Forecasts when a rate limit will be hit, from the observed rate of consumption.
///
/// The honest core: StackPulse cannot know a hidden rate limit's internal
/// accounting, so it does **not** convert token spend into a percentage. It reads
/// the percentage the provider reports, watches how fast *that* moves, and
/// extrapolates. That means:
///
/// - **With too little history it says so** and forecasts nothing. Two points over
///   a few minutes is not a trend, and a confident "6 hours" drawn from noise is
///   exactly the kind of made-up number this project refuses.
/// - **A reset is a discontinuity.** After the window rolls over, the percentage
///   drops and the old samples belong to a different cycle. Fitting a line across
///   that would invent a negative or garbage rate, so samples from before the
///   current window are dropped — detected both from `resets_at` (when known) and
///   from the percentage falling (which always means a reset).
/// - **"Won't hit it" is a real answer.** A flat or falling rate forecasts no hit,
///   and a projected hit *after* the window resets means you clear it — both are
///   good news the app should state, not hide.
enum LimitForecast {

    enum Confidence: Sendable, Equatable {
        case none   // not enough signal to forecast; `reason` says why
        case low    // a projection exists but rests on thin data
        case ok     // enough spread of readings to trust the slope
    }

    struct Result: Sendable, Equatable {
        /// Percentage points consumed per hour, from a least-squares fit over the
        /// in-window samples. Zero or negative ⇒ not trending toward the limit.
        let ratePerHour: Double
        /// Hours until 100%, or `nil` when the rate is flat/negative (no hit).
        let hoursToLimit: Double?
        /// `now + hoursToLimit`, or `nil` when there's no projected hit.
        let projectedHitUnix: Double?
        /// Whether the projected hit lands before the window resets. `nil` when the
        /// reset time is unknown — a state reported, never guessed.
        let willHitBeforeReset: Bool?
        let confidence: Confidence
        /// Present only when `confidence == .none`: the plain reason.
        let reason: String?

        /// Nothing to forecast, with a reason for the UI to show verbatim.
        static func insufficient(_ reason: String) -> Result {
            Result(ratePerHour: 0, hoursToLimit: nil, projectedHitUnix: nil,
                   willHitBeforeReset: nil, confidence: .none, reason: reason)
        }
    }

    /// Minimum spread of readings before a slope means anything. Below this, two
    /// readings a minute apart could swing the forecast wildly.
    static let minSpanSeconds: Double = 5 * 60
    /// A rate at or below this (%/hour) is treated as "not moving" — measurement
    /// jitter, not a trend toward the limit.
    static let flatRateEpsilon = 0.05
    /// A drop of more than this many points between consecutive readings is a
    /// window reset, not consumption.
    static let resetDropPoints = 3.0

    /// Project a window's future from its samples.
    ///
    /// - `currentPercent`: the live reading, used as the anchor for "how far to
    ///   100%" so the forecast agrees with what's on screen.
    /// - `resetAtUnix`: the window's reset time, if the provider gave one.
    static func project(
        samples: [LimitSample],
        currentPercent: Double,
        resetAtUnix: Double?,
        windowMinutes: Int,
        now: Double
    ) -> Result {
        if currentPercent >= 100 {
            return Result(ratePerHour: 0, hoursToLimit: 0, projectedHitUnix: now,
                          willHitBeforeReset: true, confidence: .ok, reason: nil)
        }

        // Keep only this window's cycle. Two guards, because either alone misses a
        // case: `resets_at` places the window boundary when known; the percentage
        // dropping catches a reset even when it isn't.
        var inWindow = samples.sorted { $0.capturedAtUnix < $1.capturedAtUnix }
        if let reset = resetAtUnix {
            let windowStart = reset - Double(windowMinutes) * 60
            inWindow = inWindow.filter { $0.capturedAtUnix >= windowStart }
        }
        inWindow = tailAfterLastReset(inWindow)

        guard inWindow.count >= 2 else {
            return .insufficient("Need a few more readings to project a trend.")
        }
        let span = inWindow.last!.capturedAtUnix - inWindow.first!.capturedAtUnix
        guard span >= minSpanSeconds else {
            return .insufficient("Watching — a trend needs a few minutes of readings.")
        }

        let rate = slopePerHour(inWindow)
        if rate <= flatRateEpsilon {
            // Flat or falling: honestly, no hit is coming at this pace.
            return Result(ratePerHour: max(0, rate), hoursToLimit: nil, projectedHitUnix: nil,
                          willHitBeforeReset: false,
                          confidence: confidence(count: inWindow.count, span: span), reason: nil)
        }

        let hours = (100 - currentPercent) / rate
        let hitUnix = now + hours * 3600
        let beforeReset = resetAtUnix.map { hitUnix < $0 }
        return Result(ratePerHour: rate, hoursToLimit: hours, projectedHitUnix: hitUnix,
                      willHitBeforeReset: beforeReset,
                      confidence: confidence(count: inWindow.count, span: span), reason: nil)
    }

    /// Drop everything up to and including the last point where the percentage
    /// fell — that fall is a window reset, and readings before it are a prior cycle.
    private static func tailAfterLastReset(_ sorted: [LimitSample]) -> [LimitSample] {
        var startIndex = 0
        for i in 1..<max(sorted.count, 1) where i < sorted.count {
            if sorted[i].usedPercent < sorted[i - 1].usedPercent - resetDropPoints {
                startIndex = i
            }
        }
        return Array(sorted[startIndex...])
    }

    /// Least-squares slope of percent vs. time, in points per hour.
    private static func slopePerHour(_ s: [LimitSample]) -> Double {
        let n = Double(s.count)
        let t0 = s.first!.capturedAtUnix
        // Work in hours from the first sample to keep the numbers well-scaled.
        let xs = s.map { ($0.capturedAtUnix - t0) / 3600 }
        let ys = s.map(\.usedPercent)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<s.count {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        return den == 0 ? 0 : num / den
    }

    private static func confidence(count: Int, span: Double) -> Confidence {
        (count >= 3 && span >= 10 * 60) ? .ok : .low
    }

    // MARK: Presentation

    /// A one-line, honest label for a forecast. `nil` when there is nothing worth
    /// saying (no projection and no reason to surface).
    static func label(_ r: Result) -> String? {
        switch r.confidence {
        case .none:
            return r.reason
        case .low, .ok:
            guard let hours = r.hoursToLimit else {
                return "At this pace you won't reach it before it resets."
            }
            let when = humanHours(hours)
            switch r.willHitBeforeReset {
            case .some(true):
                return "At this pace, ~\(when) to the limit — before it resets."
            case .some(false):
                return "At this pace ~\(when) to the limit, but it resets first — you should clear it."
            case .none:
                return "At this pace, ~\(when) to the limit."
            }
        }
    }

    /// Coarse hours→words. A forecast is inherently fuzzy, so it never shows
    /// false precision like "5h 12m".
    static func humanHours(_ hours: Double) -> String {
        if hours < 1 {
            let m = max(1, Int((hours * 60).rounded()))
            return "\(m) min"
        }
        if hours < 24 {
            return "\(Int(hours.rounded())) hr"
        }
        let d = Int((hours / 24).rounded())
        return "\(d) day\(d == 1 ? "" : "s")"
    }
}
