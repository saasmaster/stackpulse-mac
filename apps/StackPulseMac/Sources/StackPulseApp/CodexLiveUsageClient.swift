import Foundation

// MARK: - Codex live usage

/// Reads the signed-in ChatGPT account's **authoritative** Codex rate limits from
/// the endpoint the Codex CLI itself calls.
///
/// **Provenance, stated plainly.** Until now StackPulse *derived* Codex's session
/// and weekly percentages from the CLI's local rollout logs — an estimate, and it
/// said so. This client asks OpenAI instead: every percentage, reset time and
/// window duration below is **reported by the provider** for the signed-in
/// account, nothing is inferred or priced locally. The endpoint
/// (`chatgpt.com/backend-api/wham/usage`) is **undocumented** and can change
/// without notice, so every failure degrades to "no reading" — we never fall back
/// to a guess, and never emit a window the API didn't report. Each reading carries
/// its capture time, so a stale value can't pass as current.
///
/// **Security.** The access token is the user's own, written by `codex` itself to
/// `auth.json` (or the Keychain item it keeps). It is held locally, sent only to
/// `chatgpt.com` over HTTPS, and never logged, persisted, or printed. Response
/// bodies are parsed, never logged; errors are short user-facing strings.
///
/// **Read-only.** Unlike the Codex CLI we never refresh or rotate the token: a
/// refresh would rewrite `auth.json` / invalidate the CLI's refresh token, and a
/// monitor has no business mutating another tool's credential. An expired token
/// is reported as "sign in again", which is what the CLI's own next run fixes.
enum CodexLiveUsageClient {

    /// Same provenance tag every other live reading uses: reported by the provider.
    static let liveProvenance = "provider_reported"

    /// The two labels the app already knows how to display, and the core emits the
    /// same two — they must not drift.
    static let sessionLabel = "5h"
    static let weeklyLabel = "weekly"

    /// Result of a live fetch. `error` is short and user-facing (never the token or
    /// a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        /// Only windows the API actually reported. A window it omitted is absent
        /// here — never present as 0%.
        var limits: [LimitWindow]
        /// Flex-credit balance (`credits.balance`), in credits, when reported.
        var creditsBalance: Double?
        /// `plan_type` verbatim from the payload (e.g. "plus", "pro"), when present.
        var planType: String?
        var error: String?

        init(limits: [LimitWindow] = [], creditsBalance: Double? = nil,
             planType: String? = nil, error: String? = nil) {
            self.limits = limits
            self.creditsBalance = creditsBalance
            self.planType = planType
            self.error = error
        }

        static let empty = Outcome()
    }

    // MARK: Credential (local, read-only)

    /// The pieces of `auth.json` we need. The token is the OAuth *access* token;
    /// `accountID` addresses the right workspace when the user has more than one.
    struct Credential: Sendable, Equatable {
        var accessToken: String
        var accountID: String?
    }

    /// Keychain service the Codex CLI writes the same auth payload to.
    static let keychainService = "Codex Auth"
    /// Auth-file homes searched when `CODEX_HOME` is unset, in order.
    static let defaultAuthHomes = ["~/.config/codex", "~/.codex"]
    private static let authFileName = "auth.json"

    /// Candidate `auth.json` paths, in precedence order. `CODEX_HOME` is
    /// authoritative when set — the CLI itself looks nowhere else — so we don't
    /// silently fall back to the default homes and read a *different* account's
    /// credential than the one the user is actually using.
    static func authPaths(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func expand(_ path: String) -> String {
            path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
        }
        if let codexHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !codexHome.isEmpty {
            return [expand(codexHome).trimmedTrailingSlashes + "/" + authFileName]
        }
        return defaultAuthHomes.map { expand($0).trimmedTrailingSlashes + "/" + authFileName }
    }

    /// The first usable credential: `auth.json` (per `authPaths()`), then the
    /// Keychain item. `nil` when Codex isn't installed or isn't signed in — an
    /// absence, not a failure. Never throws.
    static func readCredential(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Credential? {
        for path in authPaths(environment: environment) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let credential = parseCredential(text)
            else { continue }
            return credential
        }
        return readCredentialFromKeychain()
    }

    private static func readCredentialFromKeychain() -> Credential? {
        // The same bounded `security` shell-out the app uses for Claude's and
        // Cursor's items: a stable process identity keeps "Always Allow" durable
        // across rebuilds, and the deadline means a pending prompt can't hang us.
        let outcome = BoundedProcess.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: 8
        )
        guard let text = outcome?.trimmedText else { return nil }
        return parseCredential(text)
    }

    /// Parse an `auth.json` payload → credential. Pure.
    ///
    /// Reads `tokens.access_token` and `tokens.account_id`. An auth file carrying
    /// only `OPENAI_API_KEY` yields `nil`: the usage endpoint is OAuth-scoped and an
    /// API key cannot read it, so pretending otherwise would only produce an error
    /// row. `security -w` prints the value as **hex** whenever it isn't plain
    /// printable text, so a hex-encoded body is decoded and retried.
    static func parseCredential(_ text: String) -> Credential? {
        if let credential = credential(fromJSON: text) { return credential }
        guard let decoded = hexDecoded(text) else { return nil }
        return credential(fromJSON: decoded)
    }

    private static func credential(fromJSON text: String) -> Credential? {
        guard
            let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty
        else { return nil }
        let account = tokens["account_id"] as? String
        return Credential(accessToken: token,
                          accountID: (account?.isEmpty ?? true) ? nil : account)
    }

    static func hexDecoded(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit)
        else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    // MARK: Endpoint

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Fetch the account's live rate limits. Returns `.empty` with **no error** when
    /// Codex simply isn't signed in on this Mac — that's an absence, not a failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let credential = readCredential() else { return .empty }
        let capturedAt = Int64(now.timeIntervalSince1970)

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StackPulse", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Outcome(error: "Codex usage unavailable right now.")
            }
            switch http.statusCode {
            case 200..<300:
                let outcome = parseUsage(data, headers: headerMap(http), capturedAt: capturedAt,
                                         now: now)
                if outcome.limits.isEmpty && outcome.creditsBalance == nil {
                    return Outcome(error: "Codex returned no usable rate limits.")
                }
                return outcome
            case 401, 403:
                return Outcome(error: "Codex sign-in expired — run `codex` to log in again.")
            default:
                return Outcome(error: "Codex usage unavailable right now.")
            }
        } catch {
            return Outcome(error: "Codex usage unavailable right now.")
        }
    }

    /// Response headers, lowercased, so the header fallbacks below can't miss a
    /// value because the server changed its casing.
    static func headerMap(_ response: HTTPURLResponse) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            map[key.lowercased()] = value
        }
        return map
    }

    // MARK: Parsing (pure, headless-testable)

    private enum WindowKind { case session, weekly }

    /// Parse the `wham/usage` body. Every field is optional; a window the payload
    /// didn't report simply doesn't appear in `limits`.
    static func parseUsage(_ data: Data, headers: [String: String] = [:],
                           capturedAt: Int64, now: Date = Date()) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        let rateLimit = root["rate_limit"] as? [String: Any]

        // Codex normally puts the five-hour window in `primary_window` and the
        // weekly one in `secondary_window` — but it can move a temporarily sole
        // weekly limit into the primary slot. Classify on the window's own declared
        // `limit_window_seconds`; slot order is only the compatibility fallback for
        // payloads that omit or introduce an unfamiliar duration.
        struct Candidate {
            var window: [String: Any]
            var usedPercent: Double?
            var fallbackKind: WindowKind
        }
        func candidate(_ value: Any?, headerKey: String, fallback: WindowKind) -> Candidate? {
            let headerPercent = coerceDouble(headers[headerKey])
            guard let window = value as? [String: Any] ?? (headerPercent == nil ? nil : [:])
            else { return nil }
            return Candidate(window: window,
                             usedPercent: coerceDouble(window["used_percent"]) ?? headerPercent,
                             fallbackKind: fallback)
        }
        let candidates = [
            candidate(rateLimit?["primary_window"],
                      headerKey: "x-codex-primary-used-percent", fallback: .session),
            candidate(rateLimit?["secondary_window"],
                      headerKey: "x-codex-secondary-used-percent", fallback: .weekly)
        ].compactMap { $0 }

        func limit(_ kind: WindowKind) -> LimitWindow? {
            let exact = candidates.first { exactKind($0.window) == kind }
            let fallback = candidates.first {
                exactKind($0.window) == nil && $0.fallbackKind == kind
            }
            // No percentage ⇒ no meter. A window we can't read is absent, not 0%.
            guard let chosen = exact ?? fallback, let used = chosen.usedPercent else { return nil }
            let defaultMinutes = kind == .session ? 300 : 10_080
            return LimitWindow(
                label: kind == .session ? sessionLabel : weeklyLabel,
                used_percent: max(0, min(100, used)),
                window_minutes: windowMinutes(chosen.window) ?? defaultMinutes,
                resets_at_unix: resetsAt(chosen.window, now: now),
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            )
        }

        return Outcome(
            limits: [limit(.session), limit(.weekly)].compactMap { $0 },
            creditsBalance: creditsBalance(root: root, headers: headers),
            planType: planType(root["plan_type"])
        )
    }

    /// Which window this is, per its own declared duration — `nil` when it declares
    /// none or declares one we don't recognise (then the caller falls back to slot
    /// order rather than mislabelling it).
    private static func exactKind(_ window: [String: Any]) -> WindowKind? {
        switch windowMinutes(window) {
        case 300: return .session
        case 10_080: return .weekly
        default: return nil
        }
    }

    /// `limit_window_seconds` → whole minutes, or `nil` when absent.
    static func windowMinutes(_ window: [String: Any]) -> Int? {
        guard let seconds = coerceDouble(window["limit_window_seconds"]), seconds > 0
        else { return nil }
        return Int(seconds / 60)
    }

    /// Absolute reset time: `reset_at` (already epoch seconds) when present, else
    /// `reset_after_seconds` measured from the fetch. `nil` when neither is given —
    /// we don't invent a reset.
    static func resetsAt(_ window: [String: Any], now: Date) -> Int64? {
        if let at = coerceDouble(window["reset_at"]) { return Int64(at) }
        if let after = coerceDouble(window["reset_after_seconds"]) {
            return Int64(now.timeIntervalSince1970 + after)
        }
        return nil
    }

    /// Flex-credit balance. An explicit `has_credits: false` is a *measured* zero,
    /// so it reports 0.0; a payload that mentions credits not at all reports `nil`
    /// (absence ≠ zero). Falls back to the `x-codex-credits-balance` header.
    static func creditsBalance(root: [String: Any], headers: [String: String] = [:]) -> Double? {
        if let credits = root["credits"] as? [String: Any] {
            if let balance = coerceDouble(credits["balance"]) { return balance }
            if credits["has_credits"] as? Bool == false { return 0 }
        }
        return coerceDouble(headers["x-codex-credits-balance"])
    }

    static func planType(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
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

    // MARK: Headless self-test

    /// Exercises the pure parsers against fixtures shaped like Codex's responses.
    /// Offline and side-effect-free — safe to run headlessly, like the sibling
    /// clients' self-tests.
    static func _selftest() -> Bool {
        func approx(_ a: Double?, _ b: Double) -> Bool {
            guard let a else { return false }
            return abs(a - b) < 0.0001
        }
        let now = Date(timeIntervalSince1970: 1_752_000_000)

        // 1) Ordinary payload: 5h in the primary slot, weekly in the secondary.
        let full = """
        { "plan_type": "pro",
          "credits": { "balance": 821.0, "has_credits": true },
          "rate_limit": {
            "primary_window": { "used_percent": 41.5, "limit_window_seconds": 18000,
                                "reset_at": 1752003600 },
            "secondary_window": { "used_percent": 12.0, "limit_window_seconds": 604800,
                                  "reset_after_seconds": 7200 } } }
        """
        let out = parseUsage(Data(full.utf8), capturedAt: 1_752_000_000, now: now)
        guard out.limits.count == 2,
              let session = out.limits.first(where: { $0.label == sessionLabel }),
              let weekly = out.limits.first(where: { $0.label == weeklyLabel }),
              approx(session.used_percent, 41.5),
              session.window_minutes == 300,
              session.resets_at_unix == 1_752_003_600,
              session.captured_at_unix == 1_752_000_000,
              session.provenance == liveProvenance,
              approx(weekly.used_percent, 12.0),
              weekly.window_minutes == 10_080,
              // reset_after_seconds is measured from the fetch, not from epoch.
              weekly.resets_at_unix == 1_752_007_200,
              approx(out.creditsBalance, 821.0),
              out.planType == "pro"
        else { return false }

        // 2) A sole WEEKLY limit parked in the primary slot must still read
        //    "weekly" — classification is by duration, never by slot order — and the
        //    unreported session window is DROPPED, not shown as 0%.
        let soleWeekly = """
        { "rate_limit": { "primary_window": { "used_percent": 63.0,
                                              "limit_window_seconds": 604800 } } }
        """
        let sw = parseUsage(Data(soleWeekly.utf8), capturedAt: 7, now: now)
        guard sw.limits.count == 1, sw.limits[0].label == weeklyLabel,
              sw.limits[0].window_minutes == 10_080,
              sw.limits[0].resets_at_unix == nil,
              sw.limits[0].captured_at_unix == 7
        else { return false }

        // 3) No declared duration ⇒ slot order is the fallback, with the default
        //    window lengths.
        let noDuration = """
        { "rate_limit": { "primary_window": { "used_percent": 5.0 },
                          "secondary_window": { "used_percent": 6.0 } } }
        """
        let nd = parseUsage(Data(noDuration.utf8), capturedAt: 1, now: now)
        guard nd.limits.count == 2,
              nd.limits[0].label == sessionLabel, nd.limits[0].window_minutes == 300,
              nd.limits[1].label == weeklyLabel, nd.limits[1].window_minutes == 10_080
        else { return false }

        // 4) Header fallback: percentages carried only on the response headers.
        let hdr = parseUsage(
            Data("{}".utf8),
            headers: ["x-codex-primary-used-percent": "88.5",
                      "x-codex-secondary-used-percent": "9",
                      "x-codex-credits-balance": "12"],
            capturedAt: 2, now: now)
        guard hdr.limits.count == 2,
              approx(hdr.limits.first(where: { $0.label == sessionLabel })?.used_percent, 88.5),
              approx(hdr.creditsBalance, 12)
        else { return false }

        // 5) Credits: explicit "no credits" is a measured 0; silence is nil.
        guard creditsBalance(root: ["credits": ["has_credits": false]]) == 0,
              creditsBalance(root: [:]) == nil
        else { return false }

        // 6) Credential discovery: tokens.access_token / tokens.account_id, the hex
        //    form `security -w` prints, and the API-key-only file that can't serve
        //    this endpoint.
        let authJSON = #"{"tokens":{"access_token":"TOK","account_id":"ACC"}}"#
        guard parseCredential(authJSON) == Credential(accessToken: "TOK", accountID: "ACC"),
              parseCredential(#"{"tokens":{"access_token":"TOK"}}"#)
                == Credential(accessToken: "TOK", accountID: nil),
              parseCredential(#"{"OPENAI_API_KEY":"sk-x"}"#) == nil,
              parseCredential(Data(authJSON.utf8).map { String(format: "%02x", $0) }.joined())
                == Credential(accessToken: "TOK", accountID: "ACC")
        else { return false }

        // 7) CODEX_HOME wins outright; otherwise both default homes are searched.
        guard authPaths(environment: ["CODEX_HOME": "/opt/codex/"])
                == ["/opt/codex/auth.json"],
              authPaths(environment: [:]).count == 2,
              authPaths(environment: [:]).allSatisfy({ $0.hasSuffix("/auth.json") }),
              authPaths(environment: [:])[0].hasSuffix(".config/codex/auth.json"),
              authPaths(environment: [:])[1].hasSuffix(".codex/auth.json")
        else { return false }

        // 8) Garbage degrades to empty, never to a fabricated reading.
        guard parseUsage(Data("not json".utf8), capturedAt: 0, now: now).limits.isEmpty,
              parseUsage(Data("{}".utf8), capturedAt: 0, now: now).limits.isEmpty,
              parseCredential("nope") == nil
        else { return false }

        return true
    }
}

private extension String {
    var trimmedTrailingSlashes: String {
        var value = self
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
