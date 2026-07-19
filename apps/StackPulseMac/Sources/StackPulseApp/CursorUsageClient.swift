import Foundation

// MARK: - Cursor live usage

/// Reads the user's own Cursor usage the only way Cursor exposes it: the private
/// endpoints its own web dashboard calls.
///
/// **Provenance, stated plainly.** Cursor publishes no usage API for individuals
/// (its Admin/Analytics APIs are team-scoped). Every number here is *reported by
/// Cursor* for the signed-in account — nothing is inferred or priced locally — but
/// the endpoints are **undocumented** and can change without notice. So every
/// failure degrades to "no reading" and the card says so; we never fall back to a
/// guess. The reading is labelled with its capture time like every other live
/// limit, so a stale value can't pass as current.
///
/// **Security.** The access token is the user's own, read from Cursor's local
/// state DB (or the Keychain item Cursor itself writes). It is held in a local,
/// sent only to `api2.cursor.sh` / `cursor.com` over HTTPS, and never logged,
/// persisted, or printed. Response bodies are parsed, never logged.
///
/// **Why a shell-out to sqlite3.** Cursor stores the token in a VS Code-style
/// SQLite state DB. The Rust core already bundles its own SQLite into the static
/// archive this binary links, so linking a second `libsqlite3` for Swift risks
/// duplicate symbols. Shelling out to the system `sqlite3` in read-only mode is
/// the same bounded shell-out pattern this app already uses to read Claude's
/// Keychain item, and it can't lock or write the user's DB.
enum CursorUsageClient {

    /// Same provenance tag the Claude live reading uses: reported by the provider.
    static let liveProvenance = "provider_reported"

    /// Result of a live fetch. `error` is short and user-facing (never the token
    /// or a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        /// "Extra Usage" — on-demand spend beyond the plan, in USD.
        var extraUsageUSD: Double?
        var planName: String?
        var error: String?

        init(limits: [LimitWindow] = [], extraUsageUSD: Double? = nil,
             planName: String? = nil, error: String? = nil) {
            self.limits = limits
            self.extraUsageUSD = extraUsageUSD
            self.planName = planName
            self.error = error
        }

        static let empty = Outcome()
    }

    // MARK: Credential (local, read-only)

    /// Cursor's VS Code-style state DB, relative to the home directory.
    static let stateDBRelativePath =
        "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    private static let accessTokenKey = "cursorAuth/accessToken"
    /// Keychain service Cursor writes the same token to (our fallback).
    private static let keychainService = "cursor-access-token"

    /// The access token from Cursor's own local state, or `nil` when Cursor isn't
    /// installed / isn't signed in. Never throws.
    static func readAccessToken() -> String? {
        readTokenFromStateDB() ?? readTokenFromKeychain()
    }

    private static func readTokenFromStateDB() -> String? {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(stateDBRelativePath).path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        // `-readonly` guarantees we can never write or lock Cursor's DB.
        let sql = "SELECT value FROM ItemTable WHERE key='\(accessTokenKey)' LIMIT 1;"
        let outcome = BoundedProcess.run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-readonly", db, sql],
            timeout: 5
        )
        return outcome?.trimmedText
    }

    private static func readTokenFromKeychain() -> String? {
        // Same bounded `security` shell-out the app uses for Claude's item: a
        // stable process identity keeps "Always Allow" durable across rebuilds.
        let outcome = BoundedProcess.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: 8
        )
        return outcome?.trimmedText
    }

    // MARK: Token → identity

    /// The user id inside the JWT's `sub` claim (`auth0|user_abc` → `user_abc`).
    /// Pure; no validation of the signature is attempted or implied — we only need
    /// the subject to address the user's own dashboard.
    static func userID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard
            let data = Data(base64Encoded: b64),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sub = obj["sub"] as? String, !sub.isEmpty
        else { return nil }
        let segments = sub.split(separator: "|")
        let id = String(segments.count > 1 ? segments[1] : segments[0])
        return id.isEmpty ? nil : id
    }

    /// The session cookie Cursor's web dashboard sends, rebuilt from the local
    /// token: `WorkosCursorSessionToken=<userID>::<jwt>` (`::` percent-encoded).
    static func sessionCookie(userID: String, token: String) -> String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
    }

    // MARK: Endpoints

    private static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let planURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!

    /// Fetch the current billing period's usage. Returns `.empty` (no error) when
    /// Cursor simply isn't set up on this Mac — that's an absence, not a failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let token = readAccessToken() else { return .empty }
        let capturedAt = Int64(now.timeIntervalSince1970)

        switch await post(usageURL, token: token) {
        case .ok(let data):
            var outcome = parseUsage(data, capturedAt: capturedAt)
            if outcome.limits.isEmpty && outcome.extraUsageUSD == nil {
                return Outcome(error: "Cursor returned no usable usage for this period.")
            }
            // Plan name is a nice-to-have: never let it fail the reading.
            if case .ok(let planData) = await post(planURL, token: token) {
                outcome.planName = parsePlanName(planData)
            }
            return outcome
        case .unauthorized:
            return Outcome(error: "Cursor sign-in expired — sign in again in Cursor.")
        case .notFound, .httpError, .failure:
            return Outcome(error: "Cursor usage unavailable right now.")
        }
    }

    // MARK: Parsing (pure, headless-testable)

    /// Parse `GetCurrentPeriodUsage`. Every field is optional and a missing one
    /// simply drops its meter — a window we can't read is reported as absent, not
    /// as 0%.
    static func parseUsage(_ data: Data, capturedAt: Int64) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        let plan = (root["planUsage"] as? [String: Any]) ?? root

        // The billing cycle is authoritative — Cursor tells us when it resets, so
        // we never assume a calendar month.
        let startMS = coerceDouble(plan["billingCycleStart"] ?? root["billingCycleStart"])
        let endMS = coerceDouble(plan["billingCycleEnd"] ?? root["billingCycleEnd"])
        let resetsAt: Int64? = endMS.map { Int64($0 / 1000) }
        let windowMinutes: Int = {
            guard let s = startMS, let e = endMS, e > s else { return 0 }
            return Int((e - s) / 60_000)
        }()

        var limits: [LimitWindow] = []
        func addMeter(_ key: String, _ label: String) {
            guard let used = coerceDouble(plan[key]) else { return }
            limits.append(LimitWindow(
                label: label,
                used_percent: max(0, min(100, used)),
                window_minutes: windowMinutes,
                resets_at_unix: resetsAt,
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            ))
        }
        addMeter("totalPercentUsed", "cursor_total")
        addMeter("autoPercentUsed", "cursor_auto")
        addMeter("apiPercentUsed", "cursor_api")

        return Outcome(limits: limits,
                       extraUsageUSD: extraUsageUSD(root: root),
                       planName: nil,
                       error: nil)
    }

    /// "Extra Usage" dollars: the first positive of the on-demand spend fields,
    /// else what the limit implies. Cents on the wire → USD. `nil` when Cursor
    /// reported nothing (no on-demand spend is not the same as $0.00 measured).
    static func extraUsageUSD(root: [String: Any]) -> Double? {
        guard let spend = root["spendLimitUsage"] as? [String: Any] else { return nil }
        let candidates = ["individualUsed", "pooledUsed", "totalSpend"]
        for key in candidates {
            if let cents = coerceDouble(spend[key]), cents > 0 { return cents / 100 }
        }
        if let limit = coerceDouble(spend["limit"]), let remaining = coerceDouble(spend["remaining"]),
           limit >= remaining {
            return (limit - remaining) / 100
        }
        return nil
    }

    static func parsePlanName(_ data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let info = (root["planInfo"] as? [String: Any]) ?? root
        let name = info["planName"] as? String
        return (name?.isEmpty ?? true) ? nil : name
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

    /// A Connect-RPC POST with an empty body — the shape Cursor's dashboard uses.
    /// The token goes on the Authorization header and nowhere else.
    private static func post(_ url: URL, token: String) async -> HTTPOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure }
            switch http.statusCode {
            case 200: return .ok(data)
            case 401, 403: return .unauthorized
            case 404: return .notFound
            default: return .httpError(http.statusCode)
            }
        } catch {
            return .failure
        }
    }

    // MARK: Headless self-test

    /// Exercises the pure parsers against fixtures shaped like Cursor's responses.
    /// Offline and side-effect-free — safe to run headlessly, like the sibling
    /// clients' self-tests.
    static func _selftest() -> Bool {
        func approx(_ a: Double?, _ b: Double) -> Bool {
            guard let a else { return false }
            return abs(a - b) < 0.0001
        }

        // 1) A full period payload: three meters + an authoritative billing cycle.
        let full = """
        { "planUsage": { "totalPercentUsed": 27.0, "autoPercentUsed": 2.0,
            "apiPercentUsed": 100.0,
            "billingCycleStart": 1750000000000, "billingCycleEnd": 1752592000000 },
          "spendLimitUsage": { "individualUsed": 36404, "limit": 0, "remaining": 0 } }
        """
        let out = parseUsage(Data(full.utf8), capturedAt: 1_752_000_000)
        guard out.limits.count == 3,
              let total = out.limits.first(where: { $0.label == "cursor_total" }),
              approx(total.used_percent, 27.0),
              total.resets_at_unix == 1_752_592_000,
              total.captured_at_unix == 1_752_000_000,
              total.provenance == liveProvenance,
              // 2_592_000_000 ms = 30 days = 43,200 minutes.
              total.window_minutes == 43_200,
              approx(out.extraUsageUSD, 364.04)
        else { return false }

        // 2) A meter Cursor didn't report is DROPPED, never rendered as 0%.
        let partial = """
        { "planUsage": { "totalPercentUsed": 10.0, "billingCycleEnd": 1752592000000 } }
        """
        let p = parseUsage(Data(partial.utf8), capturedAt: 1)
        guard p.limits.count == 1, p.limits[0].label == "cursor_total",
              p.extraUsageUSD == nil
        else { return false }

        // 3) No on-demand spend reported ⇒ nil, not $0.00 (absence ≠ measured zero).
        guard extraUsageUSD(root: ["spendLimitUsage": ["individualUsed": 0, "pooledUsed": 0]]) == nil
        else { return false }

        // 4) JWT subject extraction (`auth0|user_abc` → `user_abc`) and the cookie.
        //    Payload below is {"sub":"auth0|user_abc"} base64url-encoded.
        let jwt = "h.eyJzdWIiOiJhdXRoMHx1c2VyX2FiYyJ9.s"
        guard userID(fromJWT: jwt) == "user_abc",
              sessionCookie(userID: "user_abc", token: "TOK")
                == "WorkosCursorSessionToken=user_abc%3A%3ATOK"
        else { return false }

        // 5) Garbage degrades to empty, never to a fabricated reading.
        guard parseUsage(Data("not json".utf8), capturedAt: 0).limits.isEmpty,
              parseUsage(Data("{}".utf8), capturedAt: 0).limits.isEmpty,
              userID(fromJWT: "nope") == nil
        else { return false }

        // 6) Plan name.
        guard parsePlanName(Data(#"{"planInfo":{"planName":"Ultra"}}"#.utf8)) == "Ultra",
              parsePlanName(Data("{}".utf8)) == nil
        else { return false }

        return true
    }
}
