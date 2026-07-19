import Foundation

// MARK: - GitHub Copilot live per-seat quota

/// Reads the user's own GitHub Copilot premium-request quota using a token the
/// Copilot tooling **already left on this Mac** — no BYOK, no PAT prompt, no
/// browser cookies.
///
/// **Provenance, stated plainly.** GitHub publishes no supported per-seat quota
/// API. The number here comes from `GET https://api.github.com/copilot_internal/user`
/// — the same **undocumented** endpoint the official Copilot editor plugins call,
/// which is why the request carries the plugins' editor-identifying headers. Every
/// value is *reported by GitHub* for the signed-in account; nothing is inferred,
/// modelled, or priced locally. Because the endpoint is undocumented it can change
/// without notice, so every failure degrades to "no reading" and the card says so.
/// The reading is stamped with its capture time like every other live limit, so a
/// stale value can't pass as current.
///
/// **Security.** The token is the user's own GitHub OAuth token, read from local
/// config that Copilot / `gh` wrote (or the Keychain item `gh` writes). It is held
/// in a local, sent only to `api.github.com` over HTTPS, and never logged,
/// persisted, or printed. Response bodies are parsed, never logged. Only
/// `github.com` credentials are used: a GitHub Enterprise host's token in the same
/// config must never be sent to `api.github.com`.
///
/// **Why a shell-out to `security`.** `gh` may store its token in the system
/// keyring instead of `hosts.yml`. The bounded `/usr/bin/security` shell-out is the
/// same pattern this app already uses for Claude's and Cursor's Keychain items: a
/// stable process identity keeps "Always Allow" durable across rebuilds.
///
/// **Org-managed seats.** A Copilot Business/Enterprise seat on token-based billing
/// reports no per-user quota — GitHub returns either no `premium_interactions`
/// bucket or a zero-entitlement placeholder, with `token_based_billing: true`. The
/// real usage lives in *organization* billing (`/orgs/{org}/settings/billing/usage`),
/// which only owners and billing managers may read, and which requires probing every
/// org the user belongs to. That org fallback is **deliberately not implemented
/// here** — it is a multi-request, permission-dependent lookup that belongs with the
/// org-billing surface, and guessing would be worse than silence. This client emits
/// **no window** and an honest note instead. A placeholder is never rendered as
/// "0% used".
enum CopilotUsageClient {

    /// Same provenance tag the other live readings use: reported by the provider.
    static let liveProvenance = "provider_reported"

    /// Copilot's premium pool is a **monthly** allotment, not a rolling 5h/weekly
    /// window. 30 days expressed in minutes, the same convention the other clients
    /// use for a month-long period.
    static let monthlyWindowMinutes = 43_200

    /// Result of a live fetch. `error` is short and user-facing (never the token or
    /// a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        /// Premium interactions consumed *beyond* the included pool. `nil` when
        /// GitHub reported no overage allowance — absence, not a measured zero.
        var overageCount: Double?
        /// e.g. "Copilot Pro". Reported by GitHub, lightly title-cased.
        var planName: String?
        /// Carries the honest "no per-seat quota" note for org-managed seats. No
        /// dollar amounts: this endpoint exposes none.
        var balance: ProviderBalance?
        var error: String?

        init(limits: [LimitWindow] = [], overageCount: Double? = nil,
             planName: String? = nil, balance: ProviderBalance? = nil,
             error: String? = nil) {
            self.limits = limits
            self.overageCount = overageCount
            self.planName = planName
            self.balance = balance
            self.error = error
        }

        static let empty = Outcome()
    }

    // MARK: Credential (local, read-only)

    /// The Copilot editor plugins' OAuth token store (newer name).
    static let editorAppsRelativePath = ".config/github-copilot/apps.json"
    /// The same store under its older name.
    static let editorHostsRelativePath = ".config/github-copilot/hosts.json"
    /// GitHub CLI config, when `gh` keeps the token in a file rather than the keyring.
    static let ghHostsRelativePath = ".config/gh/hosts.yml"
    /// The Keychain item `gh` writes when it uses the system keyring instead.
    static let ghKeychainService = "gh:github.com"

    /// A `github.com` token already on this machine, or `nil` when Copilot/`gh`
    /// simply aren't set up here. Prompt-free file sources first, Keychain last, so
    /// the common case never triggers a Keychain dialog. Never throws.
    static func readToken() -> String? {
        readTokenFromEditorConfig()
            ?? readTokenFromGhConfig()
            ?? readTokenFromGhKeychain()
    }

    private static func readTokenFromEditorConfig() -> String? {
        for relative in [editorAppsRelativePath, editorHostsRelativePath] {
            guard let text = readHomeFile(relative),
                  let token = oauthToken(fromEditorJSON: text)
            else { continue }
            return token
        }
        return nil
    }

    private static func readTokenFromGhConfig() -> String? {
        guard let text = readHomeFile(ghHostsRelativePath) else { return nil }
        return yamlValue(text, key: "oauth_token")
    }

    private static func readTokenFromGhKeychain() -> String? {
        guard let raw = readGhKeychainRaw() else { return nil }
        return unwrapGoKeyring(raw)
    }

    /// `gh` files its Keychain item under the GitHub username as the account. Read
    /// it scoped to that account when `hosts.yml` reveals it; otherwise fall back to
    /// a service-only lookup.
    private static func readGhKeychainRaw() -> String? {
        if let account = ghUsername() {
            let scoped = BoundedProcess.run(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-a", account, "-s", ghKeychainService, "-w"],
                timeout: 8
            )
            if let text = scoped?.trimmedText { return text }
        }
        let outcome = BoundedProcess.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", ghKeychainService, "-w"],
            timeout: 8
        )
        return outcome?.trimmedText
    }

    private static func ghUsername() -> String? {
        guard let text = readHomeFile(ghHostsRelativePath) else { return nil }
        return yamlValue(text, key: "user")
    }

    private static func readHomeFile(_ relativePath: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Credential parsing (pure)

    /// Pull a `github.com` `oauth_token` out of the Copilot editor config. The file
    /// is a JSON object keyed by host — `"github.com"` (older `hosts.json`) or
    /// `"github.com:<appId>"` (newer `apps.json`) — each value an object carrying
    /// `oauth_token`. **Only github.com entries are used**: another host's token
    /// (GitHub Enterprise) must not be sent to api.github.com, and returning `nil`
    /// lets the chain fall through to gh config / Keychain, which may hold a valid
    /// github.com token.
    static func oauthToken(fromEditorJSON text: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        for (key, value) in obj where key == "github.com" || key.hasPrefix("github.com:") {
            guard let dict = value as? [String: Any],
                  let token = (dict["oauth_token"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else { continue }
            return token
        }
        return nil
    }

    /// Read an indented `key: value` from inside one host block of the `hosts.yml`
    /// the GitHub CLI writes. `gh` keys each host block by an unindented `<host>:`
    /// line; the read is scoped to `github.com` because an Enterprise block in the
    /// same file would otherwise win and get its token sent to api.github.com (a
    /// guaranteed 401/403). `users:` (the nested map) doesn't match `user:` — the
    /// colon position differs.
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    /// Unwrap the blob Go's `go-keyring` (which `gh` uses) stores: values it deems
    /// unsafe for the Keychain are written as `go-keyring-base64:<base64>`. Anything
    /// else is already the plain token.
    static func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8)
            else { return nil }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    // MARK: Endpoint

    private static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    /// Fetch the current per-seat premium quota. Returns `.empty` (no error) when
    /// Copilot/`gh` simply aren't set up on this Mac — that's an absence, not a
    /// failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let token = readToken() else { return .empty }
        let capturedAt = Int64(now.timeIntervalSince1970)

        switch await get(usageURL, token: token) {
        case .ok(let data):
            return parseUsage(data, capturedAt: capturedAt)
        case .unauthorized:
            return Outcome(error: "GitHub token expired — run gh auth login, or sign in to Copilot again.")
        case .notFound, .httpError, .failure:
            return Outcome(error: "Copilot usage unavailable right now.")
        }
    }

    // MARK: Parsing (pure, headless-testable)

    /// Parse `/copilot_internal/user`. Copilot reports what's **remaining**; our
    /// `LimitWindow.used_percent` is what's **used**, so `used = 100 - percent_remaining`
    /// (falling back to `100 - remaining/entitlement*100` when the percentage is
    /// absent). A bucket we can't honestly measure — missing, `unlimited`, the `-1`
    /// sentinel paid plans send for uncapped meters, or a zero-entitlement
    /// placeholder — produces **no window at all**, never a 0% bar.
    static func parseUsage(_ data: Data, capturedAt: Int64) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Outcome(error: "Copilot returned an unreadable response.")
        }

        let plan = planLabel(root["copilot_plan"])
        let resetsAt = parseResetDate(root["quota_reset_date"])
            ?? parseResetDate(root["limited_user_reset_date"])

        let snapshots = root["quota_snapshots"] as? [String: Any]
        let premiumSnapshot = snapshots?["premium_interactions"] as? [String: Any]

        guard let premium = premiumSnapshot, let used = usedPercent(premium) else {
            // No honest per-seat number. Say so plainly; never emit a 0% window.
            // `token_based_billing` marks the org-managed seat, whose real usage
            // lives in org billing (see the type doc — not implemented here).
            let zeroEntitlement = premiumSnapshot.map { coerceDouble($0["entitlement"]) == 0 } ?? false
            let orgManaged = coerceBool(root["token_based_billing"]) == true || zeroEntitlement
            let note = orgManaged
                ? "Org-managed Copilot seat — GitHub reports no per-user quota."
                : "Copilot reported no premium-request quota for this account."
            return Outcome(limits: [], overageCount: nil, planName: plan,
                           balance: ProviderBalance(note: note), error: note)
        }

        let window = LimitWindow(
            label: "premium",
            used_percent: used,
            window_minutes: monthlyWindowMinutes,
            resets_at_unix: resetsAt,
            provenance: liveProvenance,
            captured_at_unix: capturedAt
        )
        return Outcome(limits: [window],
                       overageCount: overageCount(premium),
                       planName: plan,
                       balance: nil,
                       error: nil)
    }

    /// Percent **used**, or `nil` to suppress the meter entirely. Suppressed for an
    /// explicit `unlimited`, GitHub's `-1` sentinel on `entitlement`/`remaining`, a
    /// zero entitlement (a placeholder pool, not a measured 0%), and any shape that
    /// gives no denominator.
    static func usedPercent(_ snapshot: [String: Any]) -> Double? {
        let entitlement = coerceDouble(snapshot["entitlement"])
        let remaining = coerceDouble(snapshot["remaining"])

        if coerceBool(snapshot["unlimited"]) == true { return nil }
        if entitlement == -1 || remaining == -1 { return nil }
        if entitlement == 0 { return nil }

        if let percentRemaining = coerceDouble(snapshot["percent_remaining"]) {
            return clampPercent(100 - percentRemaining)
        }
        if let entitlement, entitlement > 0, let remaining {
            return clampPercent(100 - (remaining / entitlement) * 100)
        }
        return nil
    }

    /// Premium interactions consumed beyond the included pool. Surfaced only once
    /// the user has enabled overage spend (`overage_permitted`); a real zero is then
    /// shown. When overage isn't enabled the field is genuinely N/A → `nil`. GitHub
    /// exposes no spending cap here, so this is an unbounded count, not a meter.
    static func overageCount(_ snapshot: [String: Any]) -> Double? {
        guard coerceBool(snapshot["overage_permitted"]) == true else { return nil }
        return max(0, coerceDouble(snapshot["overage_count"]) ?? 0)
    }

    /// `"copilot_pro"` → `"Copilot Pro"`. Cosmetic only; never affects a number.
    static func planLabel(_ any: Any?) -> String? {
        guard let raw = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let words = raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return titled.isEmpty ? nil : titled.joined(separator: " ")
    }

    /// `quota_reset_date` → unix **seconds**. Paid plans send an ISO-8601 datetime
    /// (sometimes with fractional seconds); free plans send a bare `yyyy-MM-dd`.
    static func parseResetDate(_ any: Any?) -> Int64? {
        guard let raw = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return Int64(date.timeIntervalSince1970) }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return Int64(date.timeIntervalSince1970) }

        // Free tier's day-only form, read as UTC midnight.
        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dayOnly.dateFormat = "yyyy-MM-dd"
        if let date = dayOnly.date(from: raw) { return Int64(date.timeIntervalSince1970) }

        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
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

    private static func coerceBool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
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

    /// The exact request the Copilot editor plugins make: a plain GET, the token on
    /// `Authorization` under the **`token`** scheme (this endpoint rejects `Bearer`),
    /// plus the editor-identifying headers GitHub expects from a Copilot client. The
    /// token goes on that header and nowhere else.
    private static func get(_ url: URL, token: String) async -> HTTPOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        req.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        req.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        req.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
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

    /// Exercises the pure parsers against fixtures shaped like GitHub's responses
    /// and the on-disk credential files. Offline and side-effect-free — safe to run
    /// headlessly, like the sibling clients' self-tests.
    static func _selftest() -> Bool {
        func approx(_ a: Double?, _ b: Double) -> Bool {
            guard let a else { return false }
            return abs(a - b) < 0.0001
        }

        // 1) A paid seat: remaining → used, monthly window, ISO reset, overage.
        let paid = """
        { "copilot_plan": "copilot_pro",
          "quota_reset_date": "2026-08-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": { "entitlement": 300, "remaining": 75,
              "percent_remaining": 25, "overage_permitted": true, "overage_count": 12 },
            "chat": { "unlimited": true, "entitlement": -1, "remaining": -1 } } }
        """
        let out = parseUsage(Data(paid.utf8), capturedAt: 1_752_000_000)
        guard out.limits.count == 1,
              let premium = out.limits.first,
              premium.label == "premium",
              approx(premium.used_percent, 75),                 // 100 - percent_remaining
              premium.window_minutes == monthlyWindowMinutes,
              premium.resets_at_unix == 1_785_542_400,
              premium.provenance == liveProvenance,
              premium.captured_at_unix == 1_752_000_000,
              approx(out.overageCount, 12),
              out.planName == "Copilot Pro",
              out.error == nil
        else { return false }

        // 2) No percent_remaining → derived from remaining/entitlement; a day-only
        //    reset date parses; no overage allowance ⇒ nil, not 0 (absence ≠ zero).
        let derived = """
        { "quota_reset_date": "2026-08-01",
          "quota_snapshots": { "premium_interactions": { "entitlement": 200, "remaining": 50 } } }
        """
        let d = parseUsage(Data(derived.utf8), capturedAt: 5)
        guard d.limits.count == 1, approx(d.limits[0].used_percent, 75),
              d.limits[0].resets_at_unix == 1_785_542_400,
              d.overageCount == nil, d.limits[0].captured_at_unix == 5
        else { return false }

        // 3) Org-managed seat (zero-entitlement placeholder + token_based_billing):
        //    NO window, an honest note — never a 0% bar.
        let org = """
        { "copilot_plan": "business", "token_based_billing": true,
          "quota_snapshots": { "premium_interactions": { "entitlement": 0, "remaining": 0,
            "percent_remaining": 0, "overage_permitted": true } } }
        """
        let o = parseUsage(Data(org.utf8), capturedAt: 1)
        guard o.limits.isEmpty, o.error != nil, o.planName == "Business",
              o.balance?.note != nil, o.overageCount == nil
        else { return false }

        // 4) Unlimited / -1 sentinels are suppressed, never rendered as a meter.
        guard usedPercent(["unlimited": true, "entitlement": 300, "remaining": 300]) == nil,
              usedPercent(["entitlement": -1, "remaining": -1]) == nil,
              usedPercent(["remaining": 10]) == nil,
              approx(usedPercent(["entitlement": 100, "remaining": 0]), 100)
        else { return false }

        // 5) Editor config: github.com wins, an Enterprise-only file yields nothing.
        let apps = """
        { "github.com:Iv1.abc": { "oauth_token": "gho_editor", "user": "octocat" },
          "ghe.example.com": { "oauth_token": "gho_enterprise" } }
        """
        let gheOnly = #"{ "ghe.example.com": { "oauth_token": "gho_enterprise" } }"#
        guard oauthToken(fromEditorJSON: apps) == "gho_editor",
              oauthToken(fromEditorJSON: gheOnly) == nil,
              oauthToken(fromEditorJSON: "not json") == nil
        else { return false }

        // 6) hosts.yml: only the github.com block is read; `users:` ≠ `user:`.
        let hosts = """
        github.com:
            user: octocat
            oauth_token: gho_cli
            git_protocol: https
        ghe.example.com:
            user: someone
            oauth_token: gho_enterprise
        """
        guard yamlValue(hosts, key: "oauth_token") == "gho_cli",
              yamlValue(hosts, key: "user") == "octocat",
              yamlValue(hosts, key: "oauth_token", host: "ghe.example.com") == "gho_enterprise",
              yamlValue("nothing here", key: "oauth_token") == nil
        else { return false }

        // 7) go-keyring blob unwrapping (base64 of "gho_keyring").
        guard unwrapGoKeyring("go-keyring-base64:Z2hvX2tleXJpbmc=") == "gho_keyring",
              unwrapGoKeyring("  gho_plain  ") == "gho_plain",
              unwrapGoKeyring("go-keyring-base64:!!!") == nil,
              unwrapGoKeyring("   ") == nil
        else { return false }

        // 8) Garbage degrades to a stated problem, never to a fabricated reading.
        guard parseUsage(Data("not json".utf8), capturedAt: 0).limits.isEmpty,
              parseUsage(Data("{}".utf8), capturedAt: 0).limits.isEmpty,
              parseUsage(Data("{}".utf8), capturedAt: 0).error != nil,
              parseResetDate("whenever") == nil,
              parseResetDate(nil) == nil,
              planLabel("") == nil
        else { return false }

        return true
    }
}
