import Foundation

// MARK: - Grok live usage

/// Reads the user's Grok weekly shared-pool usage from the same endpoint the Grok
/// CLI itself calls.
///
/// **Provenance, stated plainly.** `cli-chat-proxy.grok.com/v1/billing?format=credits`
/// is the CLI's own billing call (`GET`, with the CLI's auth headers), so this
/// reading shares the CLI's stability — but it is **undocumented** and can change
/// without notice. Every number is *reported by Grok* for the signed-in account;
/// nothing is inferred or priced locally. The weekly meter is emitted **only when
/// Grok says the current period is weekly**: an account still on the old
/// monthly-only billing has no weekly pool, and mislabelling its monthly percent
/// would be worse than an honest blank. Any failure degrades to "no reading".
///
/// **The zero rule.** The response is a proto3 message serialized as JSON, so
/// zero-valued fields are *dropped from the wire*. An **absent** `creditUsagePercent`
/// therefore means a genuine 0% — while a **present but non-numeric** value means
/// the schema drifted and must be an error, never a silent clamp to 0. The same
/// distinction governs `onDemandCap`. Getting this backwards would either hide a
/// real reading or invent one.
///
/// **Security.** The access token is the user's own, read from `~/.grok/auth.json`
/// (written by `grok login`). It is held in memory for the duration of a request,
/// sent only to `cli-chat-proxy.grok.com` over HTTPS, and never logged, printed,
/// persisted, or placed in a URL. We only ever **read** that file — token refresh
/// and rewriting `auth.json` belong to the Grok CLI, not to a usage reader that
/// could corrupt other accounts' entries. Response bodies are parsed, never logged.
enum GrokUsageClient {

    /// Same provenance tag every live reading uses: reported by the provider.
    static let liveProvenance = "provider_reported"

    /// The header the Grok CLI identifies itself with; the proxy requires it
    /// alongside the bearer token.
    static let tokenAuthHeader = "xai-grok-cli"

    /// Result of a live fetch. `error` is short and user-facing (never the token
    /// or a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        /// Pay-as-you-go cap, **in Grok credits** — deliberately not converted to
        /// USD, because Grok does not report a dollar value here and inventing an
        /// exchange rate would be a fabricated number. `nil` = Grok said nothing;
        /// `0` = a real, measured "disabled".
        var onDemandCapCredits: Double?
        var planName: String?
        var error: String?

        init(limits: [LimitWindow] = [], onDemandCapCredits: Double? = nil,
             planName: String? = nil, error: String? = nil) {
            self.limits = limits
            self.onDemandCapCredits = onDemandCapCredits
            self.planName = planName
            self.error = error
        }

        static let empty = Outcome()
    }

    // MARK: Credential (local, read-only)

    /// `grok login`'s credential file, relative to the home directory.
    static let authRelativePath = ".grok/auth.json"

    /// The period type that carries the shared weekly pool.
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    /// The access token to use, or `nil` when Grok isn't signed in on this Mac.
    /// Never throws.
    static func readAccessToken(now: Date = Date()) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(authRelativePath).path
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return selectToken(fromAuthJSON: data, now: now)
    }

    /// Pick an account's token out of `auth.json`.
    ///
    /// The file is a **map of accounts** (`{ "<account>::<clientID>": { "key": … } }`),
    /// not a single credential, so a machine with two logins has two entries. We
    /// mirror the CLI reader's selection: keep every entry with a non-empty `key`,
    /// prefer one whose JWT hasn't expired, and fall back to the first candidate
    /// when we can't tell (a token with no readable `exp` is not assumed dead).
    /// Keys are sorted first so the choice is deterministic across runs —
    /// dictionary iteration order is not.
    static func selectToken(fromAuthJSON data: Data, now: Date = Date()) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var candidates: [String] = []
        for accountKey in root.keys.sorted() {
            guard let entry = root[accountKey] as? [String: Any],
                  let token = (entry["key"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else { continue }
            candidates.append(token)
        }
        guard !candidates.isEmpty else { return nil }
        // A live token wins; otherwise hand back the first and let the server be
        // the judge (it, not us, decides what's expired).
        return candidates.first { !isExpired($0, now: now) } ?? candidates[0]
    }

    /// Whether a JWT's `exp` claim is in the past. A token we can't decode is
    /// **not** treated as expired — we don't discard a credential on a guess.
    /// No signature is verified or implied; we only read the expiry.
    static func isExpired(_ token: String, now: Date) -> Bool {
        guard let payload = jwtPayload(token),
              let exp = coerceDouble(payload["exp"])
        else { return false }
        return now.timeIntervalSince1970 >= exp
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Endpoints

    /// The weekly shared-pool data — the exact call the Grok CLI's `billing.rs`
    /// makes.
    static let creditsURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    /// Plan name only. Best-effort: a failure here must never blank the meter.
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    /// Fetch the current weekly pool. Returns `.empty` (no error) when Grok simply
    /// isn't signed in on this Mac — that's an absence, not a failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let token = readAccessToken(now: now) else { return .empty }
        let capturedAt = Int64(now.timeIntervalSince1970)

        switch await get(creditsURL, token: token) {
        case .ok(let data):
            var outcome = parseCredits(data, capturedAt: capturedAt)
            if outcome.error != nil { return outcome }
            if outcome.limits.isEmpty && outcome.onDemandCapCredits == nil {
                return Outcome(error: "Grok returned no usable billing data.")
            }
            if case .ok(let settings) = await get(settingsURL, token: token) {
                outcome.planName = parsePlanName(settings)
            }
            return outcome
        case .unauthorized:
            return Outcome(error: "Grok sign-in expired — run `grok login`.")
        case .notFound, .httpError, .failure:
            return Outcome(error: "Grok usage unavailable right now.")
        }
    }

    // MARK: Parsing (pure, headless-testable)

    /// Parse `GET /v1/billing?format=credits`.
    ///
    /// Shape (proto-JSON, zero-valued fields omitted):
    ///
    ///     { "config": {
    ///         "creditUsagePercent": 99.0,
    ///         "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
    ///                            "start": "2026-07-03T04:01:09.238389+00:00",
    ///                            "end":   "2026-07-10T04:01:09.238389+00:00" },
    ///         "onDemandCap": { "val": 2500 } } }
    ///
    /// A missing config/period, unparseable timestamps, a period that doesn't move
    /// forward, or a present-but-non-numeric percent is an **error** — the server
    /// answered, but not in a shape we know, and a wrong meter is worse than none.
    static func parseCredits(_ data: Data, capturedAt: Int64) -> Outcome {
        let drift = Outcome(error: "Grok billing response changed.")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any]
        else { return .empty }

        // Absent ⇒ genuine 0 (proto-JSON drops zeros). Present-but-unreadable ⇒ drift.
        let percent: Double
        if let raw = config["creditUsagePercent"] {
            guard let n = coerceDouble(raw), n.isFinite else { return drift }
            percent = n
        } else {
            percent = 0
        }

        // Same rule for the cap: absent means 0 (disabled), a present non-numeric
        // value means drift.
        let cap: Double
        if let rawCap = config["onDemandCap"] {
            guard let object = rawCap as? [String: Any] else { return drift }
            guard let n = coerceDouble(object["val"] ?? 0), n.isFinite else { return drift }
            cap = n
        } else {
            cap = 0
        }

        guard let period = config["currentPeriod"] as? [String: Any],
              let type = (period["type"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty,
              let start = date(period["start"]), let end = date(period["end"]),
              end > start
        else { return drift }

        // Only a weekly period feeds the weekly meter. Any other period type is
        // dropped rather than relabelled — the cap still comes back, so the card
        // isn't empty for a monthly-billing account.
        var limits: [LimitWindow] = []
        if type == weeklyPeriodType {
            limits.append(LimitWindow(
                label: "weekly",
                used_percent: max(0, min(100, percent)),
                window_minutes: Int((end.timeIntervalSince(start) / 60).rounded()),
                resets_at_unix: Int64(end.timeIntervalSince1970),
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            ))
        }
        return Outcome(limits: limits, onDemandCapCredits: cap)
    }

    /// The account's plan, from `/v1/settings`.
    static func parsePlanName(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = root["subscription_tier_display"] as? String
        else { return nil }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Small pure helpers

    /// Grok's timestamps carry **microsecond** fractional seconds and an explicit
    /// offset (`2026-07-03T04:01:09.238389+00:00`), while some fields omit the
    /// fraction entirely.
    ///
    /// `ISO8601DateFormatter` only reliably accepts *milliseconds*, so a 6-digit
    /// fraction can silently fail to parse — which would turn a perfectly good
    /// response into "billing response changed". We truncate the fraction to three
    /// digits before parsing (sub-millisecond precision is meaningless for a
    /// weekly window) and fall back to the fraction-less spelling.
    static func date(_ any: Any?) -> Date? {
        guard let raw = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: truncatingFraction(raw)) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: stripFraction(raw)) ?? plain.date(from: raw)
    }

    /// `…:09.238389+00:00` → `…:09.238+00:00`. Leaves a string with no fraction,
    /// or one already ≤ 3 digits, untouched.
    private static func truncatingFraction(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        let after = raw.index(after: dot)
        let digits = String(raw[after...].prefix { $0.isNumber })
        guard digits.count > 3 else { return raw }
        let head = String(raw[..<after])
        let rest = String(raw[raw.index(after, offsetBy: digits.count)...])
        return head + String(digits.prefix(3)) + rest
    }

    /// `…:09.238389+00:00` → `…:09+00:00`, for the fraction-less parser.
    private static func stripFraction(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        let after = raw.index(after: dot)
        let digitCount = raw[after...].prefix { $0.isNumber }.count
        let head = String(raw[..<dot])
        let rest = String(raw[raw.index(after, offsetBy: digitCount)...])
        return head + rest
    }

    private static func coerceDouble(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: Networking

    private enum HTTPOutcome {
        case ok(Data)
        case unauthorized
        case notFound
        case httpError(Int)
        case failure
    }

    /// A GET with the CLI's auth headers. The token goes on the Authorization
    /// header and nowhere else.
    private static func get(_ url: URL, token: String) async -> HTTPOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(tokenAuthHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure }
            switch http.statusCode {
            case 200..<300: return .ok(data)
            case 401, 403: return .unauthorized
            case 404: return .notFound
            default: return .httpError(http.statusCode)
            }
        } catch {
            return .failure
        }
    }

    // MARK: Headless self-test

    /// Exercises the pure parsers against fixtures shaped like Grok's responses.
    /// Offline and side-effect-free — safe to run headlessly, like the sibling
    /// clients' self-tests.
    static func _selftest() -> Bool {
        func approx(_ a: Double?, _ b: Double) -> Bool {
            guard let a else { return false }
            return abs(a - b) < 0.0001
        }

        // 1) A full weekly payload: percent, 7-day period, pay-as-you-go cap.
        let full = """
        { "config": { "creditUsagePercent": 99.0,
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
                               "start": "2026-07-03T04:01:09.238389+00:00",
                               "end":   "2026-07-10T04:01:09.238389+00:00" },
            "onDemandCap": { "val": 2500 }, "isUnifiedBillingUser": true } }
        """
        let out = parseCredits(Data(full.utf8), capturedAt: 1_752_000_000)
        guard out.error == nil, out.limits.count == 1,
              let weekly = out.limits.first,
              weekly.label == "weekly",
              approx(weekly.used_percent, 99.0),
              weekly.window_minutes == 10_080,
              weekly.captured_at_unix == 1_752_000_000,
              weekly.provenance == liveProvenance,
              approx(out.onDemandCapCredits, 2500)
        else { return false }

        // 2) THE ZERO RULE. An absent percent is proto-JSON's dropped zero — a real
        //    0%, not missing data. An absent cap is likewise a real "disabled".
        let zeros = """
        { "config": { "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-07-03T04:01:09Z", "end": "2026-07-10T04:01:09Z" } } }
        """
        let z = parseCredits(Data(zeros.utf8), capturedAt: 1)
        guard z.error == nil, approx(z.limits.first?.used_percent, 0),
              approx(z.onDemandCapCredits, 0)
        else { return false }

        // 3) …but a PRESENT non-numeric value is drift, not a zero. This is the
        //    distinction that keeps a schema change from reading as "0% used".
        let junk = """
        { "config": { "creditUsagePercent": "lots",
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-07-03T04:01:09Z", "end": "2026-07-10T04:01:09Z" } } }
        """
        let badCap = """
        { "config": { "creditUsagePercent": 5, "onDemandCap": 2500,
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-07-03T04:01:09Z", "end": "2026-07-10T04:01:09Z" } } }
        """
        guard parseCredits(Data(junk.utf8), capturedAt: 0).error != nil,
              parseCredits(Data(junk.utf8), capturedAt: 0).limits.isEmpty,
              parseCredits(Data(badCap.utf8), capturedAt: 0).error != nil
        else { return false }

        // 4) A non-weekly period DROPS the meter rather than mislabelling a monthly
        //    percent as weekly; the cap still comes through.
        let monthly = """
        { "config": { "creditUsagePercent": 40,
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_MONTHLY",
            "start": "2026-07-01T00:00:00Z", "end": "2026-08-01T00:00:00Z" },
            "onDemandCap": { "val": 0 } } }
        """
        let m = parseCredits(Data(monthly.utf8), capturedAt: 0)
        guard m.error == nil, m.limits.isEmpty, approx(m.onDemandCapCredits, 0)
        else { return false }

        // 5) A period that doesn't move forward, or is missing, is drift.
        let backwards = """
        { "config": { "creditUsagePercent": 1, "currentPeriod": {
            "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-07-10T00:00:00Z", "end": "2026-07-03T00:00:00Z" } } }
        """
        guard parseCredits(Data(backwards.utf8), capturedAt: 0).error != nil,
              parseCredits(Data(#"{"config":{}}"#.utf8), capturedAt: 0).error != nil
        else { return false }

        // 6) Account selection out of the auth.json MAP: entries without a usable
        //    `key` are skipped, an unexpired token wins over an expired one, and
        //    the choice is deterministic (keys sorted).
        //    Payloads below are {"exp":1000000000} and {"exp":4000000000}.
        let expiredJWT = "h.eyJleHAiOjEwMDAwMDAwMDB9.s"
        let liveJWT = "h.eyJleHAiOjQwMDAwMDAwMDB9.s"
        let authJSON = """
        { "aaa::client": { "key": "\(expiredJWT)" },
          "bbb::client": { "key": "" },
          "ccc::client": { "key": "\(liveJWT)" } }
        """
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        guard selectToken(fromAuthJSON: Data(authJSON.utf8), now: now) == liveJWT,
              // Every candidate expired ⇒ still hand back the first (sorted) one
              // and let the server decide; we don't blank a reading on a guess.
              selectToken(fromAuthJSON: Data(#"{"z::c":{"key":"\#(expiredJWT)"}}"#.utf8),
                          now: now) == expiredJWT,
              // An opaque (non-JWT) token is never assumed expired.
              !isExpired("opaque-token", now: now),
              selectToken(fromAuthJSON: Data("{}".utf8), now: now) == nil,
              selectToken(fromAuthJSON: Data("not json".utf8), now: now) == nil
        else { return false }

        // 7) Plan name, and garbage degrading to empty rather than a reading.
        guard parsePlanName(Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8))
                == "SuperGrok",
              parsePlanName(Data("{}".utf8)) == nil,
              parseCredits(Data("not json".utf8), capturedAt: 0).limits.isEmpty,
              parseCredits(Data("not json".utf8), capturedAt: 0).error == nil
        else { return false }

        return true
    }
}
