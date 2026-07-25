import Foundation

// MARK: - Z.ai (GLM Coding Plan) live usage

/// Reads the user's Z.ai Coding Plan quota from the two endpoints Z.ai's own
/// subscription UI calls.
///
/// **Provenance, stated plainly.** Z.ai publishes no usage API. The two endpoints
/// below are the **undocumented internal** ones its subscription page uses; they
/// are stable in practice but can change without notice. Every number here is
/// *reported by Z.ai* for the key's account — nothing is inferred, priced, or
/// estimated locally. Any failure degrades to "no reading" and the card says so;
/// we never substitute a guess. A window Z.ai didn't report is **dropped**, never
/// rendered as 0%, and every reading is stamped with its capture time so a stale
/// value can't pass as current.
///
/// **Security.** Z.ai has no companion CLI that stashes a credential on disk, so
/// the key is BYOK: the user pastes it into StackPulse and it lives in
/// StackPulse's own Keychain (`APIKeyStore`, provider id `zai`). It is read into
/// memory only for the duration of a fetch, sent only to `api.z.ai` over HTTPS,
/// and never logged, printed, persisted elsewhere, or placed in a URL. Response
/// bodies are parsed, never logged.
///
/// **Auth header.** The key goes on `Authorization: Bearer <key>` — verified
/// against the reference implementation, which sends the `Bearer` prefix on both
/// endpoints. (Some Z.ai SDK samples send the raw token; we copy what the working
/// client does, not the samples.)
enum ZaiUsageClient {

    /// Same provenance tag every live reading uses: reported by the provider.
    static let liveProvenance = "provider_reported"

    /// Provider id under which the BYOK key is stored in StackPulse's Keychain.
    static let providerID = "zai"

    /// Result of a live fetch. `error` is short and user-facing (never the key or
    /// a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        /// e.g. "GLM Coding Max" — a nice-to-have, never worth failing a reading.
        var planName: String?
        var error: String?

        init(limits: [LimitWindow] = [], planName: String? = nil, error: String? = nil) {
            self.limits = limits
            self.planName = planName
            self.error = error
        }

        static let empty = Outcome()
    }

    // MARK: Credential (StackPulse's own Keychain)

    /// The user's Z.ai API key, or `nil` when they haven't connected Z.ai. Reading
    /// StackPulse's own Keychain item never prompts (we created it).
    static func readAPIKey() -> String? {
        guard let key = APIKeyStore.read(for: providerID)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return nil }
        return key
    }

    // MARK: Endpoints

    /// Plan name only. Best-effort: a failure here must never blank the meters.
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    /// The quota meters. Required for a usable reading.
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    /// Fetch the current quota. Returns `.empty` (no error) when Z.ai simply isn't
    /// connected on this Mac — that's an absence, not a failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let key = readAPIKey() else { return .empty }
        let capturedAt = Int64(now.timeIntervalSince1970)

        switch await get(quotaURL, apiKey: key) {
        case .ok(let data):
            // A valid key on an account with no Coding Plan gets a 2xx carrying
            // `success:false`. Say that plainly instead of showing blank meters
            // that don't explain themselves.
            if isNoCodingPlan(data) {
                return Outcome(error: "No active Z.ai Coding Plan on this account.")
            }
            var outcome = parseQuota(data, capturedAt: capturedAt)
            guard !outcome.limits.isEmpty else {
                return Outcome(error: "Z.ai returned no usable quota right now.")
            }
            if case .ok(let planData) = await get(subscriptionURL, apiKey: key) {
                outcome.planName = parsePlanName(planData)
            }
            return outcome
        case .unauthorized:
            return Outcome(error: "Z.ai key rejected — check it in Settings.")
        case .notFound, .httpError, .failure:
            return Outcome(error: "Z.ai usage unavailable right now.")
        }
    }

    // MARK: Parsing (pure, headless-testable)

    /// True when a 2xx quota body is the "valid key, no Coding Plan" signal:
    /// `{"success":false,"code":500,"msg":"…coding plan…"}` with no `data`.
    /// Matched on the structured `success:false` *plus* the ASCII phrase the
    /// message carries, so an unrelated business failure can't trip it.
    static func isNoCodingPlan(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["success"] as? Bool) == false
        else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    /// Parse `/api/monitor/usage/quota/limit`.
    ///
    /// The payload's `data.limits[]` (Z.ai has also shipped the container at the
    /// root, so both are honored) carries:
    ///   • `TOKENS_LIMIT` entries, split by their own `(unit, number)` window — a
    ///     sub-daily window is the session meter, a multi-day window is weekly. The
    ///     window travels with the reading, so the cadence tracks the plan instead
    ///     of a hardcoded constant.
    ///   • a `TIME_LIMIT` entry — the monthly web-search / reader call count.
    /// Anything missing or unrecognized drops its meter rather than reporting 0%.
    static func parseQuota(_ data: Data, capturedAt: Int64) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }

        let container: [String: Any]
        if let nested = root["data"] as? [String: Any] {
            container = nested
        } else if root["data"] != nil {
            return .empty            // `data` present but not an object ⇒ drift.
        } else {
            container = root
        }
        guard let entries = container["limits"] as? [[String: Any]] else { return .empty }

        var limits: [LimitWindow] = []
        for entry in entries where isType(entry, "TOKENS_LIMIT") {
            guard let minutes = windowMinutes(entry),
                  let percent = LiveUsageJSON.coerceDouble(entry["percentage"]), percent.isFinite
            else { continue }
            // Named after the duration Z.ai reported, not bucketed by it: the old
            // `< 24h ⇒ "5h"` split presented a 12-hour token window as a 5-hour
            // session and a 30-day one as weekly, with the truth visible only in
            // `window_minutes`, which no surface prints.
            limits.append(LimitWindow(
                label: LiveUsageJSON.windowLabel(minutes: minutes),
                used_percent: LiveUsageJSON.clampPercent(percent),
                window_minutes: minutes,
                resets_at_unix: resetSeconds(entry),
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            ))
        }
        if let web = entries.first(where: { isType($0, "TIME_LIMIT") }),
           let used = LiveUsageJSON.coerceDouble(web["currentValue"]),
           let limit = LiveUsageJSON.coerceDouble(web["usage"]),
           used >= 0, limit > 0 {
            limits.append(LimitWindow(
                label: "web searches",
                used_percent: LiveUsageJSON.clampPercent(used / limit * 100),
                window_minutes: 30 * 24 * 60,
                resets_at_unix: resetSeconds(web),
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            ))
        }
        return Outcome(limits: limits)
    }

    /// `productName` of the first subscription entry (e.g. "GLM Coding Max").
    static func parsePlanName(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]],
              let name = list.first?["productName"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return name
    }

    // MARK: Small pure helpers

    /// Z.ai has labelled a limit's kind under `type` on some revisions and `name`
    /// on others; both are accepted.
    private static func isType(_ entry: [String: Any], _ kind: String) -> Bool {
        (entry["type"] as? String) == kind || (entry["name"] as? String) == kind
    }

    /// The entry's own window in minutes, from Z.ai's `(unit, number)` encoding:
    /// unit 3 = hours, 4 = days, 5 = months, 6 = weeks. An unknown unit returns
    /// `nil`, which drops that meter — a future window we can't read must not be
    /// silently mislabelled as one we can.
    static func windowMinutes(_ entry: [String: Any]) -> Int? {
        guard let unit = LiveUsageJSON.coerceDouble(entry["unit"]),
              let number = LiveUsageJSON.coerceDouble(entry["number"]), number > 0
        else { return nil }
        let unitMinutes: Double
        switch Int(unit) {
        case 3: unitMinutes = 60
        case 4: unitMinutes = 24 * 60
        case 5: unitMinutes = 30 * 24 * 60
        case 6: unitMinutes = 7 * 24 * 60
        default: return nil
        }
        let total = unitMinutes * number
        guard total >= 1, total < Double(Int.max) else { return nil }
        return Int(total)
    }

    /// `nextResetTime` arrives as epoch **milliseconds**; we store seconds.
    private static func resetSeconds(_ entry: [String: Any]) -> Int64? {
        guard let ms = LiveUsageJSON.coerceDouble(entry["nextResetTime"]), ms > 0 else { return nil }
        return Int64(ms / 1000)
    }

    // MARK: Networking

    private static func get(_ url: URL, apiKey: String) async -> LiveUsageHTTP.Outcome {
        await LiveUsageHTTP.get(url, headers: LiveUsageHTTP.bearerJSON(apiKey))
    }

    // MARK: Headless self-test

    /// Exercises the pure parsers against fixtures shaped like Z.ai's responses.
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

        // 1) A full payload: 5-hour session, 1-week weekly, monthly web searches.
        let full = """
        { "success": true, "data": { "limits": [
            { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 42.5,
              "nextResetTime": 1770648402389 },
            { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 88.0,
              "nextResetTime": 1771000000000 },
            { "type": "TIME_LIMIT", "unit": 5, "number": 1, "currentValue": 250,
              "usage": 1000, "nextResetTime": 1772000000000 } ] } }
        """
        let out = parseQuota(Data(full.utf8), capturedAt: 1_752_000_000)
        guard out.limits.count == 3,
              let session = find(out, "5h"),
              approx(session.used_percent, 42.5),
              session.window_minutes == 300,
              session.resets_at_unix == 1_770_648_402,
              session.captured_at_unix == 1_752_000_000,
              session.provenance == liveProvenance,
              let weekly = find(out, "weekly"),
              approx(weekly.used_percent, 88.0),
              weekly.window_minutes == 10_080,
              let web = find(out, "web searches"),
              approx(web.used_percent, 25.0)
        else { return false }

        // 2) A meter Z.ai didn't report is DROPPED, never rendered as 0%: only the
        //    session entry is present, so only the session meter comes back.
        let partial = """
        { "limits": [ { "name": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 7 } ] }
        """
        let p = parseQuota(Data(partial.utf8), capturedAt: 1)
        guard p.limits.count == 1, p.limits[0].label == "5h",
              p.limits[0].resets_at_unix == nil
        else { return false }

        // 3) An unknown window unit drops that meter rather than mislabelling it,
        //    and a zero web-search limit is not turned into a percentage.
        let odd = """
        { "limits": [ { "type": "TOKENS_LIMIT", "unit": 99, "number": 1, "percentage": 50 },
                      { "type": "TIME_LIMIT", "currentValue": 0, "usage": 0 } ] }
        """
        guard parseQuota(Data(odd.utf8), capturedAt: 0).limits.isEmpty,
              windowMinutes(["unit": 6, "number": 1]) == 10_080,
              windowMinutes(["unit": 3, "number": 0]) == nil
        else { return false }

        // 3b) A window that is neither 5h nor weekly is named after its real duration
        //     instead of being bucketed into one of the two familiar labels: a
        //     12-hour token window is "12h", a 30-day one is "30d". Getting this
        //     wrong also splits one quota into two rows, since SnapshotStore dedups
        //     by label and the Rust core labels by duration.
        let unusual = """
        { "limits": [ { "type": "TOKENS_LIMIT", "unit": 3, "number": 12, "percentage": 20 },
                      { "type": "TOKENS_LIMIT", "unit": 5, "number": 1, "percentage": 30 } ] }
        """
        let u = parseQuota(Data(unusual.utf8), capturedAt: 0)
        guard u.limits.count == 2,
              u.limits[0].label == "12h", u.limits[0].window_minutes == 720,
              u.limits[1].label == "30d", u.limits[1].window_minutes == 43_200
        else { return false }

        // 4) Percentages are clamped into 0…100, never trusted blindly.
        let hot = """
        { "limits": [ { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 143 } ] }
        """
        guard approx(parseQuota(Data(hot.utf8), capturedAt: 0).limits.first?.used_percent, 100)
        else { return false }

        // 5) The "valid key, no Coding Plan" signal is recognized, and an ordinary
        //    failure body is not mistaken for it.
        let none = #"{"success":false,"code":500,"msg":"user has no coding plan"}"#
        guard isNoCodingPlan(Data(none.utf8)),
              !isNoCodingPlan(Data(#"{"success":false,"msg":"rate limited"}"#.utf8)),
              !isNoCodingPlan(Data(#"{"success":true}"#.utf8))
        else { return false }

        // 6) Plan name.
        guard parsePlanName(Data(#"{"data":[{"productName":"GLM Coding Max"}]}"#.utf8))
                == "GLM Coding Max",
              parsePlanName(Data(#"{"data":[]}"#.utf8)) == nil
        else { return false }

        // 7) Garbage degrades to empty, never to a fabricated reading.
        guard parseQuota(Data("not json".utf8), capturedAt: 0).limits.isEmpty,
              parseQuota(Data("{}".utf8), capturedAt: 0).limits.isEmpty,
              parseQuota(Data(#"{"data":"nope"}"#.utf8), capturedAt: 0).limits.isEmpty
        else { return false }

        return true
    }
}
