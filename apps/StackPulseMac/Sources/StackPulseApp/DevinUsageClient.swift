import Foundation

// MARK: - Devin live usage

/// Reads the user's Devin (Cognition / Windsurf) daily and weekly quota from the
/// same Connect-RPC call the Devin editor makes.
///
/// **Provenance, stated plainly.** Devin publishes no usage API; `GetUserStatus`
/// on the Seat Management service is the **undocumented** internal call its own
/// client makes. Every number here is *reported by Devin* for the signed-in
/// account — nothing is inferred or priced locally. Devin reports quota as percent
/// **remaining**, so each meter is flipped to percent *used* (`100 - remaining`)
/// exactly once, here, where it can be seen. A window Devin didn't report — or one
/// its own plan flags as hidden — is **dropped**, never rendered as 0%, and every
/// reading is stamped with its capture time.
///
/// **The API key travels in the JSON body, not a header.** The service reads it
/// from `metadata.apiKey` alongside the IDE-identifying fields its client sends;
/// there is no `Authorization` header on this endpoint. Unusual, but it's what the
/// server expects, so it's what we send — over HTTPS, in a POST body, never a URL.
///
/// **Security.** The key is the user's own, read from Devin's own local
/// credentials file or, failing that, its VS Code-style state DB. It is held in
/// memory only for the duration of a request and never logged, printed, persisted,
/// or placed in a URL. Response bodies are parsed, never logged.
///
/// **Why a shell-out to sqlite3.** Same reason as the Cursor client: the Rust core
/// already bundles its own SQLite into the static archive this binary links, so
/// linking a second `libsqlite3` for Swift risks duplicate symbols. A bounded
/// `/usr/bin/sqlite3 -readonly` shell-out can neither lock nor write the user's DB.
enum DevinUsageClient {

    /// Same provenance tag every live reading uses: reported by the provider.
    static let liveProvenance = "provider_reported"

    /// Result of a live fetch. `error` is short and user-facing (never the key or
    /// a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        /// Prepaid overage balance in USD, when Devin reported one. A present
        /// balance of `0` is a real measured zero; `nil` means Devin said nothing.
        var balance: ProviderBalance?
        var planName: String?
        var error: String?

        init(limits: [LimitWindow] = [], balance: ProviderBalance? = nil,
             planName: String? = nil, error: String? = nil) {
            self.limits = limits
            self.balance = balance
            self.planName = planName
            self.error = error
        }

        static let empty = Outcome()
    }

    /// A credential plus the API server it belongs to (self-hosted installs point
    /// elsewhere, and the credentials file is where they say so).
    struct Credential: Sendable {
        var apiKey: String
        var apiServerURL: String
    }

    // MARK: Credential (local, read-only)

    /// Devin CLI's credentials file, relative to the home directory.
    static let credentialsRelativePath = ".local/share/devin/credentials.toml"
    /// Devin app's VS Code-style state DB, relative to the home directory.
    static let stateDBRelativePath =
        "Library/Application Support/Devin/User/globalStorage/state.vscdb"
    static let defaultAPIServerURL = "https://server.codeium.com"
    /// The Connect-RPC service path.
    static let servicePath = "exa.seat_management_pb.SeatManagementService/GetUserStatus"
    /// The client version Devin's own IDE integration reports. Sent verbatim so
    /// the server treats us like the client it expects.
    static let clientVersion = "1.108.2"

    /// The API key from Devin's own local state, or `nil` when Devin isn't
    /// installed / isn't signed in. Never throws. The CLI's credentials file wins
    /// because it also carries a self-hosted `api_server_url`.
    static func readCredential() -> Credential? {
        readCredentialFromFile() ?? readCredentialFromStateDB()
    }

    private static func readCredentialFromFile() -> Credential? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(credentialsRelativePath).path
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              let key = tomlString(text, key: "windsurf_api_key")
        else { return nil }
        return Credential(
            apiKey: key,
            apiServerURL: cleanAPIServerURL(tomlString(text, key: "api_server_url"))
                ?? defaultAPIServerURL
        )
    }

    private static func readCredentialFromStateDB() -> Credential? {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(stateDBRelativePath).path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        // `-readonly` guarantees we can never write or lock Devin's DB.
        let sql = "SELECT value FROM ItemTable WHERE key='windsurfAuthStatus' LIMIT 1;"
        let outcome = BoundedProcess.run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-readonly", db, sql],
            timeout: 5
        )
        guard let value = outcome?.trimmedText,
              let key = apiKey(fromAuthStatusJSON: value)
        else { return nil }
        return Credential(apiKey: key, apiServerURL: defaultAPIServerURL)
    }

    /// `.apiKey` out of the `windsurfAuthStatus` JSON blob the state DB stores.
    static func apiKey(fromAuthStatusJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (root["apiKey"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// A single scalar out of a flat TOML file. Deliberately minimal — we read two
    /// known keys from a file Devin writes, not arbitrary TOML — and it handles the
    /// three spellings that actually appear: bare, quoted, and trailing-comment.
    static func tomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
            else { continue }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if let quote = value.first, quote == "\"" || quote == "'" {
                return quotedTOMLString(value, quote: quote)
            }
            if let comment = value.firstIndex(of: "#") {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func quotedTOMLString(_ value: String, quote: Character) -> String? {
        var output = ""
        var previous: Character?
        for character in value.dropFirst() {
            if character == quote, previous != "\\" {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            output.append(character)
            previous = character
        }
        return nil
    }

    /// Only an explicit `https://` override is honored; anything else falls back to
    /// the default host, so a malformed or plaintext value can never redirect a
    /// credential somewhere unencrypted.
    static func cleanAPIServerURL(_ value: String?) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("https://")
        else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty || trimmed == "https:/" ? nil : trimmed
    }

    // MARK: Fetch

    /// Fetch the current quota. Returns `.empty` (no error) when Devin simply isn't
    /// set up on this Mac — that's an absence, not a failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let credential = readCredential() else { return .empty }
        guard let url = URL(string: "\(credential.apiServerURL)/\(servicePath)") else {
            return Outcome(error: "Devin server address isn't usable.")
        }
        let capturedAt = Int64(now.timeIntervalSince1970)

        switch await postUserStatus(url, apiKey: credential.apiKey) {
        case .ok(let data):
            let outcome = parseUserStatus(data, capturedAt: capturedAt)
            if outcome.limits.isEmpty && outcome.balance == nil {
                return Outcome(error: "Devin returned no usable quota right now.")
            }
            return outcome
        case .unauthorized:
            return Outcome(error: "Devin sign-in expired — sign in to Devin again.")
        case .notFound, .httpError, .failure:
            return Outcome(error: "Devin usage unavailable right now.")
        }
    }

    // MARK: Parsing (pure, headless-testable)

    /// Parse `GetUserStatus`.
    ///
    /// `userStatus.planStatus` carries `dailyQuotaRemainingPercent` /
    /// `weeklyQuotaRemainingPercent` (percent **remaining**, flipped here),
    /// `dailyQuotaResetAtUnix` / `weeklyQuotaResetAtUnix` (unix **seconds**), and
    /// `overageBalanceMicros` (micros → USD). A plan that sets
    /// `planInfo.hideDailyQuota` has no meaningful daily window, so we drop it
    /// rather than show a meter Devin's own UI hides.
    static func parseUserStatus(_ data: Data, capturedAt: Int64) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userStatus = root["userStatus"] as? [String: Any]
        else { return .empty }

        let planStatus = (userStatus["planStatus"] as? [String: Any]) ?? [:]
        let planInfo = (planStatus["planInfo"] as? [String: Any]) ?? [:]
        let hideDaily = (planInfo["hideDailyQuota"] as? Bool) == true

        var limits: [LimitWindow] = []
        /// One quota row: remaining → used, clamped, with Devin's own reset time.
        func addQuota(_ label: String, remaining: Any?, resetKey: String, minutes: Int) {
            guard let remaining = LiveUsageJSON.coerceDouble(remaining), remaining.isFinite else { return }
            limits.append(LimitWindow(
                label: label,
                used_percent: LiveUsageJSON.clampPercent(100 - remaining),
                window_minutes: minutes,
                resets_at_unix: unixSeconds(planStatus[resetKey]),
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            ))
        }
        if !hideDaily {
            addQuota("daily", remaining: planStatus["dailyQuotaRemainingPercent"],
                     resetKey: "dailyQuotaResetAtUnix", minutes: 24 * 60)
        }
        addQuota("weekly", remaining: planStatus["weeklyQuotaRemainingPercent"],
                 resetKey: "weeklyQuotaResetAtUnix", minutes: 7 * 24 * 60)

        return Outcome(
            limits: limits,
            balance: balance(fromMicros: planStatus["overageBalanceMicros"]),
            planName: trimmedString(planInfo["planName"])
        )
    }

    /// Overage balance in USD from micros. `nil` when the field is missing or
    /// non-numeric (truly no data); a reported `0` stays a real, measured zero.
    static func balance(fromMicros any: Any?) -> ProviderBalance? {
        guard let micros = LiveUsageJSON.coerceDouble(any), micros.isFinite else { return nil }
        return ProviderBalance(
            remaining_usd: max(0, micros) / 1_000_000,
            currency: "USD",
            note: "Extra usage balance"
        )
    }

    // MARK: Small pure helpers

    private static func unixSeconds(_ any: Any?) -> Int64? {
        guard let seconds = LiveUsageJSON.coerceDouble(any), seconds > 0, seconds.isFinite else { return nil }
        return Int64(seconds)
    }

    private static func trimmedString(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        return s
    }

    // MARK: Networking

    /// The Connect-RPC POST. The API key rides in `metadata.apiKey` in the body —
    /// this endpoint has no Authorization header — beside the IDE-identifying
    /// fields Devin's client sends.
    private static func postUserStatus(_ url: URL, apiKey: String) async -> LiveUsageHTTP.Outcome {
        let body: [String: Any] = [
            "metadata": [
                "apiKey": apiKey,
                "ideName": "devin",
                "ideVersion": clientVersion,
                "extensionName": "devin",
                "extensionVersion": clientVersion,
                "locale": "en",
            ]
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure
        }

        return await LiveUsageHTTP.post(
            url,
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ],
            body: encoded
        )
    }

    // MARK: Headless self-test

    /// Exercises the pure parsers against fixtures shaped like Devin's responses.
    /// Offline and side-effect-free — safe to run headlessly, like the sibling
    /// clients' self-tests.
    static func _selftest() -> Bool {
        func approx(_ a: Double?, _ b: Double) -> Bool {
            guard let a else { return false }
            return abs(a - b) < 0.0001
        }
        func find(_ o: Outcome, _ label: String) -> LimitWindow? {
            o.limits.first { $0.label == label }
        }

        // 1) A full payload. REMAINING is flipped to USED exactly once: 82.5%
        //    remaining is 17.5% used, 30% remaining is 70% used.
        let full = """
        { "userStatus": { "planStatus": {
            "planInfo": { "planName": "Devin Team" },
            "dailyQuotaRemainingPercent": 82.5,
            "weeklyQuotaRemainingPercent": 30,
            "dailyQuotaResetAtUnix": 1752040000,
            "weeklyQuotaResetAtUnix": 1752500000,
            "overageBalanceMicros": 12500000 } } }
        """
        let out = parseUserStatus(Data(full.utf8), capturedAt: 1_752_000_000)
        guard out.limits.count == 2,
              let daily = find(out, "daily"),
              approx(daily.used_percent, 17.5),
              daily.window_minutes == 1440,
              daily.resets_at_unix == 1_752_040_000,
              daily.captured_at_unix == 1_752_000_000,
              daily.provenance == liveProvenance,
              let weekly = find(out, "weekly"),
              approx(weekly.used_percent, 70),
              weekly.window_minutes == 10_080,
              weekly.resets_at_unix == 1_752_500_000,
              // 12,500,000 micros = $12.50.
              approx(out.balance?.remaining_usd, 12.5),
              out.balance?.currency == "USD",
              out.planName == "Devin Team"
        else { return false }

        // 2) A window Devin didn't report is DROPPED, never rendered as 0% — and a
        //    plan that hides its daily quota drops that row too.
        let weeklyOnly = """
        { "userStatus": { "planStatus": { "weeklyQuotaRemainingPercent": 100 } } }
        """
        let w = parseUserStatus(Data(weeklyOnly.utf8), capturedAt: 1)
        guard w.limits.count == 1, w.limits[0].label == "weekly",
              approx(w.limits[0].used_percent, 0),   // 100% remaining = 0% used
              w.limits[0].resets_at_unix == nil,
              w.balance == nil                        // absence, not $0.00
        else { return false }

        let hidden = """
        { "userStatus": { "planStatus": {
            "planInfo": { "hideDailyQuota": true },
            "dailyQuotaRemainingPercent": 50, "weeklyQuotaRemainingPercent": 40 } } }
        """
        let h = parseUserStatus(Data(hidden.utf8), capturedAt: 0)
        guard h.limits.count == 1, h.limits[0].label == "weekly",
              approx(h.limits[0].used_percent, 60)
        else { return false }

        // 3) A reported zero balance is a MEASURED zero, not missing data.
        guard approx(balance(fromMicros: 0)?.remaining_usd, 0),
              balance(fromMicros: nil) == nil,
              balance(fromMicros: "n/a") == nil
        else { return false }

        // 4) Out-of-range remaining is clamped, never trusted blindly.
        let odd = """
        { "userStatus": { "planStatus": { "dailyQuotaRemainingPercent": -20,
            "weeklyQuotaRemainingPercent": 140 } } }
        """
        let o = parseUserStatus(Data(odd.utf8), capturedAt: 0)
        guard approx(find(o, "daily")?.used_percent, 100),
              approx(find(o, "weekly")?.used_percent, 0)
        else { return false }

        // 5) The credentials file: bare, quoted, and commented values all read, and
        //    a non-HTTPS server override is refused rather than followed.
        let toml = """
        # devin credentials
        windsurf_api_key = "sk-test-123"
        api_server_url = https://devin.internal.example.com/   # self-hosted
        """
        guard tomlString(toml, key: "windsurf_api_key") == "sk-test-123",
              cleanAPIServerURL(tomlString(toml, key: "api_server_url"))
                == "https://devin.internal.example.com",
              tomlString(toml, key: "missing") == nil,
              cleanAPIServerURL("http://plaintext.example.com") == nil,
              cleanAPIServerURL(nil) == nil
        else { return false }

        // 6) The state-DB fallback blob.
        guard apiKey(fromAuthStatusJSON: #"{"apiKey":"sk-db-456","other":1}"#) == "sk-db-456",
              apiKey(fromAuthStatusJSON: #"{"apiKey":"  "}"#) == nil,
              apiKey(fromAuthStatusJSON: "not json") == nil
        else { return false }

        // 7) Garbage degrades to empty, never to a fabricated reading.
        guard parseUserStatus(Data("not json".utf8), capturedAt: 0).limits.isEmpty,
              parseUserStatus(Data("{}".utf8), capturedAt: 0).limits.isEmpty,
              parseUserStatus(Data(#"{"userStatus":{}}"#.utf8), capturedAt: 0).balance == nil
        else { return false }

        return true
    }
}
