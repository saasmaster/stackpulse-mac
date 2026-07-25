import Foundation

// MARK: - MiniMax Code (Coding Plan) live usage

/// Reads the user's MiniMax Coding Plan quota from the endpoint MiniMax Code's own
/// usage popover calls.
///
/// **Provenance, stated plainly.** MiniMax publishes no usage API. The endpoint
/// below is the **undocumented internal** one the desktop app itself calls, and it
/// can change without notice. Every number here is *reported by MiniMax* for this
/// machine's logged-in account — nothing is inferred, priced, or estimated locally.
/// A window MiniMax didn't report is **dropped**, never rendered as 0%.
///
/// **How the shape was established.** The request path, the field names, and the
/// direction of every number were read out of the shipped `app.asar` — MiniMax's
/// own transform, not a guess at one. Two details are worth recording because they
/// are the kind that get "fixed" wrongly later:
///
/// - `current_*_remaining_percent` is **remaining**. MiniMax's own helper computes
///   `100 - remaining` before rendering, so its popover shows *used*. This client
///   does the same inversion, which is also the direction every StackPulse card
///   uses. Read the raw field as "used" and every meter is backwards.
/// - The two windows are 5-hour and weekly. That is not inferred from the field
///   names: MiniMax's own locale strings label them `window_5h` = "5 Hours" and
///   `window_weekly` = "Weekly". So they map onto this app's existing `5h`/`weekly`
///   vocabulary exactly, with no new label and no invented duration.
///
/// A third quota MiniMax tracks (`window_video`, a per-model *count*) is
/// deliberately ignored: it measures video generations, not coding usage, and its
/// units are counts rather than a percentage.
///
/// **What the shipped code could not settle**, and how it was settled instead: the
/// host, and how the credential travels. Both came from the server rather than from
/// a guess. It answers `200` with `base_resp.status_code` carrying the real verdict
/// — a REST-shaped path that returns 200 for a failed request — and the first
/// verdict it gave was "cookie is missing", which is how the bearer header this
/// client originally sent turned out to be the wrong mechanism entirely. Reading
/// HTTP status as the outcome would have read that refusal as a successful empty
/// quota and shown a card with no numbers and no reason.
///
/// **Security.** MiniMax Code stores its session token in a plain JSON file that it
/// creates world-readable *and world-writable* (mode 0666 on a real install, where
/// Codex writes its own credential 0600). That is MiniMax's choice and nothing here
/// can fix it; what this client does is treat the value as untrusted input — it is
/// read into memory for the duration of one request, sent only to a **hardcoded**
/// MiniMax host over HTTPS, and never logged, persisted, placed in a URL, or put in
/// a subprocess argument. The hosts are compile-time constants precisely so a file
/// anyone can write cannot redirect a credential anywhere.
enum MiniMaxUsageClient {

    /// Same provenance tag every live reading uses: reported by the provider.
    static let liveProvenance = "provider_reported"

    /// Provider id, matching `ProviderId::MiniMax`'s wire value.
    static let providerID = "minimax"

    /// Result of a live fetch. `error` is short and user-facing (never the token or
    /// a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        /// Credit balance, for an account with no Coding Plan. Denominated in
        /// **credits**, which is why `currency` matters here — see `balanceFrom`.
        var balance: ProviderBalance?
        var error: String?

        init(limits: [LimitWindow] = [], balance: ProviderBalance? = nil, error: String? = nil) {
            self.limits = limits
            self.balance = balance
            self.error = error
        }

        static let empty = Outcome()
    }

    // MARK: Credential (MiniMax's own file — read-only)

    /// Where MiniMax Code keeps its config. Verified against a real install; the
    /// product name ("MiniMax Code") and this directory ("MiniMax Agent") genuinely
    /// differ, which is why the path is not derived from the app name.
    static func configPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MiniMax Agent")
            .appendingPathComponent("minimax-agent-config.json").path
    }

    /// The session token, or `nil` when MiniMax Code isn't signed in on this Mac.
    ///
    /// Only ever called on the fetch path. StackPulse's *detection* of MiniMax
    /// checks that this file exists and never opens it — presence is that layer's
    /// entire signal, and this is the one place the contents are read.
    static func readToken() -> String? {
        guard let data = FileManager.default.contents(atPath: configPath()),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = (tokens["accessToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: Endpoint

    /// The path MiniMax Code's usage popover requests.
    static let remainsPath = "/v1/api/openplatform/coding_plan/remains"

    /// The cookie MiniMax authenticates this endpoint with.
    ///
    /// **Not** a bearer header, which is what a REST-shaped path like this one
    /// invites you to assume — the server answered `200` with "cookie is missing"
    /// in its body. The session JWT rides in a cookie named `_token`, byte-identical
    /// to the `accessToken` in the config file (verified by hash on a real install),
    /// which is why this client keeps a single credential source instead of also
    /// opening MiniMax's cookie database.
    static let sessionCookieName = "_token"

    /// Headers for an authenticated quota request. Split out so the fetch path and
    /// the shape probe cannot drift apart on the thing that took two rounds to learn.
    static func authHeaders(token: String) -> [String: String] {
        ["Cookie": "\(sessionCookieName)=\(token)", "Accept": "application/json"]
    }

    /// MiniMax's own hosts, hardcoded and tried in order.
    ///
    /// `agent.minimax.io` is where a running MiniMax Code actually holds its
    /// connection; `api.minimax.io` is the sibling the bundle also names, kept as a
    /// fallback in case the account is routed differently. Both appear verbatim in
    /// MiniMax's shipped code.
    ///
    /// The `minimaxi.com` pair (MiniMax's China region) is deliberately absent. A
    /// token issued for one region is not valid in the other, so trying it would
    /// send a credential somewhere it can only be rejected — a cost with no benefit.
    static let hosts = ["agent.minimax.io", "api.minimax.io"]

    // MARK: Fetch

    /// Read the live Coding Plan quota. `.empty` (no error) when MiniMax Code simply
    /// isn't signed in here — that is an absence, not a failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let token = readToken() else { return .empty }
        let capturedAt = Int64(now.timeIntervalSince1970)
        let headers = authHeaders(token: token)

        var sawUnauthorized = false
        var sawResponse = false

        for host in hosts {
            guard let url = URL(string: "https://\(host)\(remainsPath)") else { continue }
            switch await LiveUsageHTTP.get(url, headers: headers) {
            case .ok(let data):
                sawResponse = true
                // A parsed reading is authoritative. A 2xx we cannot read is schema
                // drift rather than data — keep looking rather than reporting zero.
                switch parseRemains(data, capturedAt: capturedAt) {
                case .quota(let limits):
                    return Outcome(limits: limits)
                case .noPlan, .serviceError:
                    // No plan quota. MiniMax Code itself doesn't stop here — without
                    // a Coding Plan it shows the account's **credit balance**
                    // instead, and that is the only number such an account has. A
                    // service message is treated the same way: MiniMax reports "no
                    // active token plan" through that channel, so failing here would
                    // turn its answer into an error.
                    return await creditBalanceOutcome(headers: headers, host: host)
                case .unrecognized:
                    continue
                }
            case .unauthorized:
                sawUnauthorized = true
            case .notFound, .httpError, .failure:
                continue
            }
        }

        if sawUnauthorized {
            return Outcome(error: "MiniMax rejected the saved login — sign in again in MiniMax Code.")
        }
        if sawResponse {
            return Outcome(error: "MiniMax answered with a quota shape StackPulse doesn't recognize.")
        }
        return Outcome(error: "Couldn't reach MiniMax to read your Coding Plan quota.")
    }

    // MARK: Credit balance (accounts with no Coding Plan)

    /// The endpoint MiniMax Code reads account state from, `opcredit_balance`
    /// included.
    static let userInfoPath = "/matrix/api/v1/user/get_user_extra_info"

    /// The credit balance for an account with no plan quota, or an honest note when
    /// MiniMax doesn't report one.
    static func creditBalanceOutcome(headers: [String: String], host: String) async -> Outcome {
        guard let url = URL(string: "https://\(host)\(userInfoPath)"),
              case .ok(let data) = await LiveUsageHTTP.get(url, headers: headers),
              let balance = balanceFrom(data)
        else {
            return Outcome(error: "No MiniMax Coding Plan on this account, and no credit balance reported.")
        }
        return Outcome(balance: balance)
    }

    /// `opcredit_balance` as a **credit** balance — never as dollars.
    ///
    /// MiniMax's own UI labels this "Credits" and floors it to an integer, so it is
    /// a count, not money. It rides in `ProviderBalance.remaining_usd` because that
    /// is the wire field's name, with `currency: "credits"` saying what the number
    /// actually is; `Format.balanceAmount` renders it as "1,240 credits" rather than
    /// inventing "$1,240".
    static func balanceFrom(_ data: Data) -> ProviderBalance? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let credits = findNumber(named: "opcredit_balance", in: root)
        else { return nil }
        return ProviderBalance(
            remaining_usd: max(0, credits.rounded(.down)),
            currency: "credits",
            note: "MiniMax credits — no Coding Plan quota on this account."
        )
    }

    /// Depth-bounded search for a distinctively-named key anywhere in a response.
    ///
    /// Deliberately not a fixed path: MiniMax reads this same value from two
    /// different places (the selected workspace, or the membership object) and picks
    /// whichever is present, so pinning one path would break on the other. The key
    /// name is unique enough that a match cannot be something else, and the depth
    /// bound keeps a hostile or pathological payload from costing anything.
    static func findNumber(named key: String, in value: Any, depth: Int = 0) -> Double? {
        guard depth < 6 else { return nil }
        switch value {
        case let dict as [String: Any]:
            if let hit = LiveUsageJSON.coerceDouble(dict[key]) { return hit }
            for nested in dict.values {
                if let hit = findNumber(named: key, in: nested, depth: depth + 1) { return hit }
            }
            return nil
        case let array as [Any]:
            for element in array.prefix(20) {
                if let hit = findNumber(named: key, in: element, depth: depth + 1) { return hit }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: Parsing (pure, headless-testable)

    /// What a 2xx body turned out to be.
    ///
    /// Four outcomes, not two, because they call for four different things on the
    /// card and collapsing them is how "MiniMax answered with a shape StackPulse
    /// doesn't recognize" ended up standing in for "this account has no Coding
    /// Plan" — a true statement about our parser, useless to the reader.
    enum Reading: Equatable {
        /// At least one readable window.
        case quota([LimitWindow])
        /// MiniMax answered normally and there is no Coding Plan quota to report.
        case noPlan
        /// MiniMax reported a failure inside a 200. Carries no message: it used to,
        /// and nothing ever read it — "no active token plan" arrives through this
        /// channel and is handled by falling back to the credit balance, so the
        /// text was ceremony. Detection is what matters; treating this as success
        /// would read a refusal as an empty quota.
        case serviceError
        /// Not a shape we know. The only one worth trying another host for.
        case unrecognized
    }

    /// True when MiniMax reported a failure inside a `200 OK`.
    ///
    /// It answers 200 even when the request failed, putting the real outcome in
    /// `base_resp.status_code` (0 = success). Treating HTTP status as the verdict
    /// would read an auth failure as a successful empty quota.
    static func reportedFailure(in root: [String: Any]) -> Bool {
        guard let resp = root["base_resp"] as? [String: Any],
              let code = LiveUsageJSON.coerceDouble(resp["status_code"])
        else { return false }
        return Int(code) != 0
    }

    static func parseRemains(_ data: Data, capturedAt: Int64) -> Reading {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unrecognized
        }
        if reportedFailure(in: root) { return .serviceError }
        guard let quota = quotaObject(in: root) else {
            // An explicitly empty `model_remains` is an answer, not drift: MiniMax
            // is saying this account has no coding-plan quota. Only a body with no
            // such key at all is a shape we failed to read.
            let envelope = (root["data"] as? [String: Any]) ?? root
            let listed = (envelope["model_remains"] as? [Any]) ?? (root["model_remains"] as? [Any])
            return listed != nil ? .noPlan : .unrecognized
        }

        var out: [LimitWindow] = []
        // (remaining-percent key, status key, reset key, label, window length)
        let specs: [(percent: String, status: String, reset: String, label: String, minutes: Int)] = [
            ("current_interval_remaining_percent", "current_interval_status", "end_time", "5h", 300),
            ("current_weekly_remaining_percent", "current_weekly_status", "weekly_end_time", "weekly", 10_080)
        ]
        for spec in specs {
            // Status 3 is MiniMax's "unlimited". A percentage of an unbounded pool
            // has no meaning, so the window is dropped rather than shown at 0%.
            if let status = LiveUsageJSON.coerceDouble(quota[spec.status]), Int(status) == 3 {
                continue
            }
            // Absent ⇒ dropped. MiniMax's own helper substitutes 0 here, which makes
            // an unreported meter read as a comfortable "0% used"; copying that would
            // import a lie. Absence is not a measurement.
            guard let remaining = LiveUsageJSON.coerceDouble(quota[spec.percent]) else { continue }
            out.append(LimitWindow(
                label: spec.label,
                used_percent: LiveUsageJSON.clampPercent(100 - remaining),
                window_minutes: spec.minutes,
                resets_at_unix: unixSeconds(quota[spec.reset]),
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            ))
        }
        // A quota object whose every window was unreported or unlimited is still a
        // real answer about the account, not a parse failure.
        return out.isEmpty ? .noPlan : .quota(out)
    }

    /// The response's *structure* — keys and value types, never values.
    ///
    /// The one thing that could not be settled by reading MiniMax's shipped code is
    /// what its server actually returns for a given account, and a parser fixed by
    /// guessing at that is the failure this whole client is written to avoid. This
    /// prints enough to correct the parser and nothing that could carry a quota
    /// figure, an account id, or a token.
    static func describeShape(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return ["root: not JSON (\(data.count) bytes)"]
        }
        return describe(object, pad: "", label: "root", depth: 0)
    }

    /// One live request whose *shape* is reported instead of its values, for
    /// `--selftest-minimax`. Separate from `fetch` so the normal path never holds a
    /// raw body longer than it takes to parse it.
    static func probeShape() async -> (host: String, lines: [String])? {
        guard let token = readToken() else { return nil }
        let headers = authHeaders(token: token)
        for host in hosts {
            guard let url = URL(string: "https://\(host)\(remainsPath)") else { continue }
            if case .ok(let data) = await LiveUsageHTTP.get(url, headers: headers) {
                return (host, describeShape(data))
            }
        }
        return nil
    }

    private static func describe(_ value: Any?, pad: String, label: String, depth: Int) -> [String] {
        switch value {
        case let dict as [String: Any]:
            var lines = ["\(pad)\(label): object"]
            for key in dict.keys.sorted() {
                lines += describe(dict[key], pad: pad + "  ", label: key, depth: depth + 1)
            }
            return lines
        case let array as [Any]:
            var lines = ["\(pad)\(label): array[\(array.count)]"]
            if let first = array.first, depth < 3 {
                lines += describe(first, pad: pad + "  ", label: "[0]", depth: depth + 1)
            }
            return lines
        case is NSNumber: return ["\(pad)\(label): number"]
        case is String: return ["\(pad)\(label): string"]
        case nil, is NSNull: return ["\(pad)\(label): null"]
        default: return ["\(pad)\(label): ?"]
        }
    }

    /// The object carrying the quota fields.
    ///
    /// MiniMax's client reads them both off the response root and off the first
    /// `model_remains` entry, so both are accepted, plus one `data` envelope of the
    /// kind its other endpoints use. Whichever actually carries a percentage wins —
    /// the shape is settled by the data rather than by an assumption about it.
    static func quotaObject(in root: [String: Any]) -> [String: Any]? {
        let envelope = (root["data"] as? [String: Any]) ?? root
        let candidates: [[String: Any]?] = [
            envelope,
            (envelope["model_remains"] as? [[String: Any]])?.first,
            (root["model_remains"] as? [[String: Any]])?.first
        ]
        return candidates.compactMap { $0 }.first { candidate in
            candidate["current_interval_remaining_percent"] != nil
                || candidate["current_weekly_remaining_percent"] != nil
        }
    }

    /// A reset time as unix seconds, or `nil` when it isn't stated.
    ///
    /// The wire format is not pinned by MiniMax's code, so all three plausible forms
    /// are accepted rather than one being assumed: seconds, milliseconds (told apart
    /// by magnitude — a seconds value that large would be in the year 33658), and an
    /// ISO-8601 string. An unparseable value yields `nil`, which renders as "no
    /// reset shown" instead of a wrong countdown.
    static func unixSeconds(_ any: Any?) -> Int64? {
        if let text = any as? String {
            if let date = ISO8601DateFormatter().date(from: text) {
                return Int64(date.timeIntervalSince1970)
            }
            guard let n = Double(text) else { return nil }
            return normalizeEpoch(n)
        }
        guard let n = LiveUsageJSON.coerceDouble(any) else { return nil }
        return normalizeEpoch(n)
    }

    private static func normalizeEpoch(_ value: Double) -> Int64? {
        guard value > 0 else { return nil }
        return Int64(value > 1_000_000_000_000 ? value / 1000 : value)
    }

    // MARK: Headless self-test

    /// Exercises the pure parser against fixtures shaped like MiniMax's own payload.
    /// Offline and side-effect-free — safe to run headlessly, like the sibling
    /// clients' self-tests.
    static func _selftest() -> Bool {
        // 1) The documented shape: remaining ⇒ used, both windows, 5h before weekly.
        let full = """
        { "model_remains": [ {
            "model_name": "MiniMax-M2",
            "current_interval_remaining_percent": 75,
            "current_interval_status": 1,
            "end_time": 1784620000,
            "current_weekly_remaining_percent": 40,
            "current_weekly_status": 1,
            "weekly_end_time": 1785000000
        } ] }
        """
        guard case .quota(let limits) = parseRemains(Data(full.utf8), capturedAt: 99),
              limits.count == 2,
              limits[0].label == "5h", limits[0].used_percent == 25,
              limits[0].window_minutes == 300,
              limits[0].resets_at_unix == 1_784_620_000,
              limits[0].captured_at_unix == 99,
              limits[0].provenance == liveProvenance,
              limits[1].label == "weekly", limits[1].used_percent == 60,
              limits[1].window_minutes == 10_080
        else { return false }

        // 2) The inversion is the whole ballgame: 100% remaining is 0% USED, and a
        //    spent window reads 100% used. Getting this backwards would show a full
        //    quota as exhausted, so it is asserted at both ends.
        let fresh = #"{"current_interval_remaining_percent":100,"current_weekly_remaining_percent":0}"#
        guard case .quota(let ends) = parseRemains(Data(fresh.utf8), capturedAt: 1),
              ends.count == 2,
              ends[0].used_percent == 0, ends[1].used_percent == 100
        else { return false }

        // 3) Absence is dropped, never zeroed — a window MiniMax didn't report must
        //    not render as a comfortable 0% used.
        let partial = #"{"current_weekly_remaining_percent":10}"#
        guard case .quota(let one) = parseRemains(Data(partial.utf8), capturedAt: 1),
              one.count == 1, one[0].label == "weekly", one[0].used_percent == 90
        else { return false }

        // 4) "Unlimited" (status 3) drops the window: a percentage of an unbounded
        //    pool is not a measurement.
        let unlimited = """
        {"current_interval_remaining_percent":50,"current_interval_status":3,
         "current_weekly_remaining_percent":50,"current_weekly_status":1}
        """
        guard case .quota(let capped) = parseRemains(Data(unlimited.utf8), capturedAt: 1),
              capped.count == 1, capped[0].label == "weekly"
        else { return false }

        // 5) An out-of-range percentage saturates rather than vanishing (over quota
        //    is a real state), and a `data` envelope is unwrapped.
        let over = #"{"data":{"current_interval_remaining_percent":-5}}"#
        guard case .quota(let sat) = parseRemains(Data(over.utf8), capturedAt: 1),
              sat.count == 1, sat[0].used_percent == 100
        else { return false }

        // 6) Reset times: seconds pass through, milliseconds are scaled, ISO-8601
        //    parses, and junk degrades to nil rather than to a wrong countdown.
        guard unixSeconds(1_784_620_000) == 1_784_620_000,
              unixSeconds(1_784_620_000_000) == 1_784_620_000,
              unixSeconds("2026-07-21T18:00:00Z") == 1_784_656_800,
              unixSeconds("not a time") == nil,
              unixSeconds(0) == nil,
              unixSeconds(nil) == nil
        else { return false }

        // 7) Garbage degrades to no reading, never to a fabricated one.
        guard parseRemains(Data("not json".utf8), capturedAt: 0) == .unrecognized,
              parseRemains(Data("{}".utf8), capturedAt: 0) == .unrecognized
        else { return false }

        // 8) The four outcomes stay distinguishable. This is the regression that
        //    actually shipped: "no Coding Plan on this account" was reported as
        //    "a shape StackPulse doesn't recognize" — true about the parser, and
        //    useless to the person reading the card.
        //
        //    An explicit (even empty) `model_remains` is MiniMax answering; a body
        //    without the key at all is a shape we failed to read.
        guard parseRemains(Data(#"{"model_remains":[]}"#.utf8), capturedAt: 0) == .noPlan,
              parseRemains(Data(#"{"data":{"model_remains":[]}}"#.utf8), capturedAt: 0) == .noPlan,
              // Every window unlimited ⇒ an answer about the account, not drift.
              parseRemains(Data(#"{"current_weekly_remaining_percent":5,"current_weekly_status":3}"#.utf8),
                           capturedAt: 0) == .noPlan
        else { return false }

        // 9) MiniMax answers 200 with the real verdict in `base_resp`, so HTTP status
        //    alone would read an auth failure as a successful empty quota. Its own
        //    message is passed through rather than replaced with a guess; code 0 is
        //    success and must NOT be treated as an error.
        guard parseRemains(Data(#"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#.utf8),
                           capturedAt: 0) == .serviceError,
              parseRemains(Data(#"{"base_resp":{"status_code":1008},"model_remains":[]}"#.utf8),
                           capturedAt: 0) == .serviceError,
              // Code 0 IS success and must not be mistaken for a failure.
              parseRemains(Data(#"{"base_resp":{"status_code":0},"model_remains":[]}"#.utf8),
                           capturedAt: 0) == .noPlan
        else { return false }

        // 10) The credential goes in a cookie, not a bearer header. MiniMax answered
        //     "cookie is missing" to the header form, so this is pinned: a future
        //     tidy-up that "restores" the conventional Authorization header would
        //     silently break every reading, and the endpoint would report success.
        let headers = authHeaders(token: "TOK")
        guard headers["Cookie"] == "_token=TOK",
              headers["Authorization"] == nil
        else { return false }

        // 11) The credit balance an account without a plan does have. It is a COUNT,
        //     not money — MiniMax labels it "Credits" and floors it — so it must
        //     carry `currency: "credits"` and must never render as dollars.
        let credits = #"{"data":{"workspaces":[{"selected":true,"opcredit_balance":1240.7}]}}"#
        guard let bal = balanceFrom(Data(credits.utf8)),
              bal.remaining_usd == 1240,          // floored, as MiniMax floors it
              bal.currency == "credits",
              Format.balanceAmount(1240, currency: bal.currency) == "1,240 credits",
              Format.balanceAmount(1, currency: "credits") == "1 credit",
              // The whole point: this number must not acquire a dollar sign.
              !Format.balanceAmount(1240, currency: bal.currency).contains("$"),
              // USD still formats as money, so the shared path didn't regress.
              Format.balanceAmount(12.5, currency: "USD") == "$12.50"
        else { return false }

        // A response with no such key yields no balance — never a zero, which would
        // read as "you're out of credits".
        guard balanceFrom(Data(#"{"data":{"workspaces":[{"selected":true}]}}"#.utf8)) == nil,
              balanceFrom(Data("not json".utf8)) == nil,
              // Found however deep MiniMax happens to put it (workspace vs membership).
              findNumber(named: "opcredit_balance", in: ["a": ["b": ["opcredit_balance": 7]]]) == 7,
              findNumber(named: "opcredit_balance", in: ["a": 1]) == nil
        else { return false }

        // 12) The shape report names structure and never carries a value — it exists
        //     to fix a parser, not to print somebody's quota.
        let shape = describeShape(Data(#"{"model_remains":[{"current_weekly_remaining_percent":37}]}"#.utf8))
        guard shape.contains(where: { $0.contains("model_remains: array[1]") }),
              shape.contains(where: { $0.contains("current_weekly_remaining_percent: number") }),
              !shape.contains(where: { $0.contains("37") })
        else { return false }

        return true
    }
}
