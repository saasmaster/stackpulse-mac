import Foundation

/// Fetches Claude's live session/weekly usage limits from Anthropic using the
/// user's *own* local Claude Code OAuth login.
///
/// SECURITY (this whole type is the network boundary):
///   • The bearer token is read on demand, held in a local value, sent ONLY to
///     the exact HTTPS endpoint below, and dropped. It is never logged, never
///     persisted, never written to disk, never printed.
///   • The raw HTTP response body is never logged either — only parsed. On any
///     failure we surface a short, generic error string (never the body/token).
///   • We never attempt a token refresh (that would mutate the user's creds). An
///     expired token yields an empty result plus a "sign in again" note.
///
/// This runs entirely off the main actor (all funcs are `nonisolated`/`static`)
/// and returns `Sendable` values, so it composes cleanly with Swift 6 strict
/// concurrency: read creds → fetch → parse → hand `[LimitWindow]` to the store.
enum AnthropicUsageClient {
    /// The one and only destination the token is ever sent to.
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Required OAuth beta header value for this endpoint.
    static let betaHeader = "oauth-2025-04-20"

    /// Fallback User-Agent version when the core hasn't detected the Claude CLI.
    static let defaultClaudeVersion = "2.1.181"

    /// The provenance stamped on every live-fetched limit, matching the
    /// protocol's convention for values the provider itself reported.
    static let liveProvenance = "provider_reported"

    /// What the user can actually DO about a failure, as a value rather than a
    /// sentence the UI would have to string-match to act on.
    enum Recovery: Sendable, Equatable {
        /// The saved CLI token aged out. Only a *terminal* Claude Code session
        /// rewrites it — Desktop sessions authenticate through Claude's own
        /// encrypted storage and never renew it. Running `claude` once fixes it.
        case renewLoginInTerminal
    }

    /// Result of a live-limits fetch. `error` is a short, user-facing note (never
    /// the token or raw response); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        var error: String?
        /// Set when there is a concrete, safe action that would fix this.
        var recovery: Recovery?

        init(limits: [LimitWindow], error: String? = nil, recovery: Recovery? = nil) {
            self.limits = limits
            self.error = error
            self.recovery = recovery
        }

        static let empty = Outcome(limits: [])
    }

    /// The windows a payload reported, plus what that payload proved about its own
    /// scale.
    ///
    /// The scale has to be decided per PAYLOAD, not per value. `utilization` may
    /// arrive as a percent (0–100) or a fraction (0–1), and `0.8` is 80% under one
    /// reading and 0.8% under the other — but a single response is one or the
    /// other, never both. Deciding value-by-value (`v <= 1 ? v * 100 : v`) claimed
    /// otherwise: given `{ seven_day: 12.5, five_hour: 0.45 }` it reported weekly
    /// 12.5% and 5h 45%, silently multiplying one and passing the other through.
    /// No API reports both scales in one body, so at least one of those was wrong.
    ///
    /// A value above 1.0 proves the payload is already a percent, since a fraction
    /// cannot exceed 1.0 — so nothing in it is scaled. Only when EVERY window is
    /// ≤ 1.0 is the payload genuinely ambiguous, and that is precisely the state
    /// just after a reset. Hence ``percentScaleLearned``: once the endpoint has
    /// proved it speaks percent, that verdict is remembered and the ambiguous
    /// payload is read correctly.
    ///
    /// Until it has proved anything, an all-≤1.0 payload is scaled — the reading
    /// under which the percentages this app has actually displayed (82%, 5%) are
    /// real. It errs toward over-reporting: a false "near your limit" is a wasted
    /// warning, while the opposite error is silence while you burn through a limit.
    struct ParsedUsage: Sendable {
        var limits: [LimitWindow]
        /// True when a window exceeded 1.0 — only a percent-scaled payload can.
        var provedPercentScale: Bool

        static let empty = ParsedUsage(limits: [], provedPercentScale: false)
    }

    // MARK: Public entry point

    /// Reads the local Claude Code credentials and, if valid, fetches live
    /// limits. All failure modes degrade to an empty `Outcome` (silently, or
    /// with a short note) — never a throw, never a crash.
    ///
    /// - Parameter claudeVersion: the core-detected Claude CLI version (e.g.
    ///   `"2.1.181"`), used to build the `User-Agent`. Falls back to
    ///   `defaultClaudeVersion` when `nil`.
    static func fetchClaudeLimits(claudeVersion: String?) async -> Outcome {
        switch KeychainProbe.readClaudeCredentialsResult() {
        case .notFound:
            // This is only reached when the user has explicitly enabled live
            // limits, so "no login found" is a reason they need — not something to
            // pass over in silence. Returning `.empty` (error `nil`) meant the card
            // simply showed nothing, or worse, kept showing a cached number with no
            // hint that it could no longer be refreshed.
            return Outcome(
                limits: [],
                error: "No Claude Code login found — run `claude` in Terminal once to sign in."
            )
        case .accessDenied:
            return Outcome(
                limits: [],
                error: "Allow Keychain access to show Claude's live limits — click “Always Allow” on the macOS prompt."
            )
        case .parseFailed:
            return Outcome(limits: [], error: "Couldn't read the Claude login for live limits.")
        case .ok(let creds):
            if creds.isExpired {
                // The saved access token has aged out. We deliberately do NOT
                // refresh it — using the refresh token could rotate it and sign
                // the user out of Claude Code itself. Claude Code rewrites this
                // token when it next refreshes, and StackPulse picks it up then.
                // Desktop (app) sessions authenticate via Claude's own encrypted
                // storage and never renew this CLI token — only a terminal
                // session does. Say exactly how to revive it.
                return Outcome(
                    limits: [],
                    error: "Claude's saved login has expired — run `claude` in Terminal once to renew it. (Desktop sessions don't refresh it; StackPulse never changes your login.)",
                    recovery: .renewLoginInTerminal
                )
            }
            return await fetchUsage(token: creds.accessToken, claudeVersion: claudeVersion)
        }
    }

    // MARK: Networking

    private static func fetchUsage(token: String, claudeVersion: String?) async -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        // The token goes out on THIS header, to THIS endpoint, and nowhere else.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent(claudeVersion: claudeVersion), forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Outcome(limits: [], error: "Live limits: unexpected response.")
            }
            guard http.statusCode == 200 else {
                // Note the status code only — never the body (may echo the token
                // context or account details).
                if http.statusCode == 401 || http.statusCode == 403 {
                    // A non-expired token that's still rejected means the login
                    // itself is no longer valid — a real re-auth is needed.
                    return Outcome(
                        limits: [],
                        error: "Claude Code's login was rejected — sign in to Claude Code again."
                    )
                }
                if http.statusCode == 429 {
                    // Transient rate-limit — the store keeps the last-good value and
                    // backs off, so this rarely reaches the UI.
                    return Outcome(limits: [], error: "Live limits are rate-limited — retrying shortly.")
                }
                return Outcome(limits: [], error: "Live limits unavailable (HTTP \(http.statusCode)).")
            }
            let learned = percentScaleLearned
            let parsed = parseUsage(data, assumePercentScale: learned)
            if parsed.provedPercentScale, !learned {
                percentScaleLearned = true // one-way: a fraction can never exceed 1.0
            }
            if parsed.limits.isEmpty {
                return Outcome(limits: [], error: "Live limits: no limit data in response.")
            }
            return Outcome(limits: parsed.limits, error: nil)
        } catch {
            // Offline / TLS / timeout. Report the category, never the details.
            return Outcome(limits: [], error: "Live limits unavailable (offline?).")
        }
    }

    private static func userAgent(claudeVersion: String?) -> String {
        let version = (claudeVersion?.isEmpty == false ? claudeVersion : nil) ?? defaultClaudeVersion
        return "claude-code/\(version)"
    }

    // MARK: Parsing (pure, headless-testable)

    /// Decodes the Anthropic usage payload into `[LimitWindow]`, tolerating BOTH
    /// the modern `limits: [...]` array and the legacy flat fields. Pure and
    /// side-effect-free: it never touches the network, Keychain, or disk, so it
    /// is exercised directly by `_selftest()`.
    ///
    /// Uses `JSONSerialization` (rather than `Codable`) on purpose: the two
    /// shapes differ structurally, `percent`/`utilization` may be Int or Double,
    /// and `resets_at` may be a unix number OR an ISO-8601 string — a permissive
    /// hand-decode is far less brittle here than a bespoke `Decodable`.
    static func parseUsage(_ data: Data, assumePercentScale: Bool = false) -> ParsedUsage {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }

        /// A window read from the payload but not yet scaled — the scale is a
        /// property of the payload as a whole, so it can't be applied yet.
        struct Staged {
            let label: String
            let raw: Double
            let resetsAt: Int64?
        }
        var staged: [Staged] = []
        var seen = Set<String>()

        func add(_ window: Staged) {
            guard !seen.contains(window.label) else { return }   // live/first wins
            seen.insert(window.label)
            staged.append(window)
        }

        // --- Modern shape: `limits: [{ kind, group?, percent, resets_at, scope?, is_active? }]`
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                if let active = entry["is_active"] as? Bool, active == false { continue }
                guard let raw = coerceDouble(entry["percent"] ?? entry["utilization"]) else { continue }
                let kind = (entry["kind"] as? String) ?? ""
                let group = entry["group"] as? String
                add(Staged(
                    label: modernLabel(kind: kind, group: group, scopedModel: scopeModelName(entry["scope"])),
                    raw: raw,
                    resetsAt: parseResetsAt(entry["resets_at"])
                ))
            }
        }

        // --- Legacy flat shape: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`.
        let legacy: [(key: String, label: String)] = [
            ("five_hour", "5h"),
            ("seven_day", "weekly"),
            ("seven_day_opus", "weekly (Opus)"),
            ("seven_day_sonnet", "weekly (Sonnet)"),
        ]
        for (key, label) in legacy {
            guard
                let entry = root[key] as? [String: Any],
                let raw = coerceDouble(entry["utilization"] ?? entry["percent"])
            else { continue }
            add(Staged(label: label, raw: raw, resetsAt: parseResetsAt(entry["resets_at"])))
        }

        let provedPercentScale = staged.contains { $0.raw > 1.0 }
        let scale = (provedPercentScale || assumePercentScale) ? 1.0 : 100.0
        return ParsedUsage(
            limits: staged.map { s in
                LimitWindow(
                    label: s.label,
                    used_percent: s.raw * scale,
                    window_minutes: windowMinutes(forLabel: s.label),
                    resets_at_unix: s.resetsAt,
                    provenance: liveProvenance
                )
            },
            provedPercentScale: provedPercentScale
        )
    }

    // MARK: Parsing helpers

    /// Maps a modern `kind`/`group`/`scope` to a display label consistent with the
    /// legacy variants. Real kinds include `session`, `weekly_all` (→ "weekly"),
    /// and `weekly_scoped` with a `scope.model.display_name` (→ "weekly (Fable)").
    static func modernLabel(kind: String, group: String?, scopedModel: String? = nil) -> String {
        let k = kind.lowercased()
        let g = (group ?? "").lowercased()
        let isWeekly = k.contains("seven") || k.contains("week") || k.contains("day") || g.contains("week")
        if isWeekly {
            if let m = scopedModel, !m.isEmpty { return "weekly (\(m))" }
            if g.contains("opus") || k.contains("opus") { return "weekly (Opus)" }
            if g.contains("sonnet") || k.contains("sonnet") { return "weekly (Sonnet)" }
            return "weekly"
        }
        // session / five_hour / hour → the 5-hour window.
        return "5h"
    }

    /// Extracts a scoped model name from a modern limit's `scope.model` object,
    /// e.g. `{ "model": { "display_name": "Fable" } }` → "Fable".
    static func scopeModelName(_ any: Any?) -> String? {
        guard let scope = any as? [String: Any],
              let model = scope["model"] as? [String: Any] else { return nil }
        if let name = model["display_name"] as? String, !name.isEmpty { return name }
        if let id = model["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    static func windowMinutes(forLabel label: String) -> Int {
        label == "5h" ? 300 : 10080
    }

    /// Whether this endpoint has ever been observed reporting a utilization above
    /// 1.0 — which only a percent-scaled payload can do. See ``ParsedUsage``.
    ///
    /// Remembered across launches because the decisive evidence and the ambiguous
    /// payload rarely arrive together: the proof shows up whenever usage passes
    /// 1%, but the payload that *needs* it is the one where every window is under
    /// 1% (right after a reset) — exactly when there is nothing to learn from.
    static var percentScaleLearned: Bool {
        get { UserDefaults.standard.bool(forKey: percentScaleDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: percentScaleDefaultsKey) }
    }

    private static let percentScaleDefaultsKey = "stackpulse.anthropicUsage.percentScaleObserved"

    static func coerceDouble(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Parses `resets_at`, which may be a unix epoch (seconds OR milliseconds),
    /// a numeric string, or an ISO-8601 timestamp. Returns unix **seconds**.
    static func parseResetsAt(_ any: Any?) -> Int64? {
        if let d = coerceDouble(any) {
            return d > 1_000_000_000_000 ? Int64(d / 1000.0) : Int64(d)
        }
        if let s = any as? String {
            return parseISO8601(s)
        }
        return nil
    }

    private static func parseISO8601(_ s: String) -> Int64? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: s) { return Int64(date.timeIntervalSince1970) }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: s) { return Int64(date.timeIntervalSince1970) }

        return nil
    }

    // MARK: Headless self-test

    /// Exercises `parseUsage` against embedded fixtures covering BOTH the legacy
    /// flat shape and the modern `limits:` array, returning `true` when every
    /// assertion holds. Pure and offline — safe to run headlessly (it never
    /// touches the Keychain or network). Kept in the shipping binary (not behind
    /// `#if DEBUG`) so it can be compiled + run standalone for verification.
    ///
    /// Fixtures validated against:
    ///
    /// Legacy:
    /// ```json
    /// { "five_hour":        { "utilization": 0.45, "resets_at": 1893456000 },
    ///   "seven_day":        { "utilization": 12.5, "resets_at": "2026-07-19T00:00:00Z" },
    ///   "seven_day_opus":   { "utilization": 0.9,  "resets_at": 1893456000 },
    ///   "seven_day_sonnet": { "utilization": 30,   "resets_at": 1893456000000 } }
    /// ```
    /// Modern:
    /// ```json
    /// { "limits": [
    ///     { "kind": "five_hour", "percent": 45,   "resets_at": "2026-07-12T18:00:00.500Z", "is_active": true },
    ///     { "kind": "seven_day", "percent": 0.125,"resets_at": 1893456000 },
    ///     { "kind": "seven_day", "group": "opus", "percent": 88, "resets_at": 1893456000 },
    ///     { "kind": "seven_day", "group": "sonnet","percent": 0.02,"resets_at": 1893456000, "is_active": false } ] }
    /// ```
    static func _selftest() -> Bool {
        func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

        // 1) Legacy flat shape (also checks millis→seconds + ISO parsing).
        let legacyJSON = """
        {
          "five_hour":        { "utilization": 0.45, "resets_at": 1893456000 },
          "seven_day":        { "utilization": 12.5, "resets_at": "2026-07-19T00:00:00Z" },
          "seven_day_opus":   { "utilization": 0.9,  "resets_at": 1893456000 },
          "seven_day_sonnet": { "utilization": 30,   "resets_at": 1893456000000 }
        }
        """
        let legacyParsed = parseUsage(Data(legacyJSON.utf8))
        let legacy = legacyParsed.limits
        func find(_ list: [LimitWindow], _ label: String) -> LimitWindow? {
            list.first { $0.label == label }
        }
        // 12.5 and 30 can only be percents, so this payload is percent-scaled and
        // NOTHING in it is multiplied — 0.45 means 0.45%, not 45%. The old
        // per-value rule read the same body as both scales at once.
        guard legacyParsed.provedPercentScale,
              legacy.count == 4,
              let l5 = find(legacy, "5h"), approx(l5.used_percent, 0.45), l5.window_minutes == 300,
              l5.resets_at_unix == 1_893_456_000,
              let lw = find(legacy, "weekly"), approx(lw.used_percent, 12.5), lw.window_minutes == 10080,
              (lw.resets_at_unix ?? 0) > 1_700_000_000,               // ISO parsed to a real epoch
              let lo = find(legacy, "weekly (Opus)"), approx(lo.used_percent, 0.9),
              let ls = find(legacy, "weekly (Sonnet)"), approx(ls.used_percent, 30),
              ls.resets_at_unix == 1_893_456_000,                     // millis normalized to seconds
              legacy.allSatisfy({ $0.provenance == liveProvenance })
        else { return false }

        // 2) Modern `limits:` array (also checks is_active:false is skipped).
        let modernJSON = """
        {
          "limits": [
            { "kind": "five_hour", "percent": 45,    "resets_at": "2026-07-12T18:00:00.500Z", "is_active": true },
            { "kind": "seven_day", "percent": 0.125, "resets_at": 1893456000 },
            { "kind": "seven_day", "group": "opus",  "percent": 88, "resets_at": 1893456000 },
            { "kind": "seven_day", "group": "sonnet","percent": 0.02, "resets_at": 1893456000, "is_active": false }
          ]
        }
        """
        let modern = parseUsage(Data(modernJSON.utf8)).limits
        guard modern.count == 3,                                       // sonnet skipped (is_active:false)
              let m5 = find(modern, "5h"), approx(m5.used_percent, 45), m5.window_minutes == 300,
              (m5.resets_at_unix ?? 0) > 1_700_000_000,                // fractional-second ISO parsed
              // 45 and 88 prove the percent scale, so 0.125 is 0.125% — not 12.5%.
              let mw = find(modern, "weekly"), approx(mw.used_percent, 0.125), mw.window_minutes == 10080,
              let mo = find(modern, "weekly (Opus)"), approx(mo.used_percent, 88), mo.window_minutes == 10080,
              find(modern, "weekly (Sonnet)") == nil
        else { return false }

        // 3) An all-≤1.0 payload is genuinely ambiguous: 0.82 is either 82% or
        //    0.82% and nothing in the body says which. Unproven ⇒ scaled.
        let ambiguousJSON = """
        { "limits": [ { "kind": "session", "percent": 0.05 },
                      { "kind": "seven_day", "percent": 0.82 } ] }
        """
        let ambiguous = parseUsage(Data(ambiguousJSON.utf8))
        guard !ambiguous.provedPercentScale,
              let a5 = find(ambiguous.limits, "5h"), approx(a5.used_percent, 5),
              let aw = find(ambiguous.limits, "weekly"), approx(aw.used_percent, 82)
        else { return false }

        // 4) ...but once the endpoint has PROVED it speaks percent, the same body
        //    reads as 0.05% / 0.82%. This is the just-after-a-reset case: without
        //    the remembered verdict, 0.82% would be shown as 82% — a fake "you're
        //    nearly out" alert, and a notification to match.
        let known = parseUsage(Data(ambiguousJSON.utf8), assumePercentScale: true)
        guard let k5 = find(known.limits, "5h"), approx(k5.used_percent, 0.05),
              let kw = find(known.limits, "weekly"), approx(kw.used_percent, 0.82)
        else { return false }

        // 5) Garbage / empty inputs degrade to [].
        guard parseUsage(Data("not json".utf8)).limits.isEmpty,
              parseUsage(Data("{}".utf8)).limits.isEmpty
        else { return false }

        return true
    }
}
