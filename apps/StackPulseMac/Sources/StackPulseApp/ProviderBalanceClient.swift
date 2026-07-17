import Foundation

// MARK: - API-key provider catalog

/// One BYOK-capable provider StackPulse can store an API key for. `id` matches
/// the core's snapshot provider id where one exists (`open_router`, `zai`) so a
/// fetched balance can be folded onto that provider's card; the rest are storage
/// + Settings-only until the core (or a future fetcher) surfaces them. Pure data
/// (no SwiftUI / Security) so it also compiles into the headless parser self-test.
struct APIKeyProviderInfo: Identifiable, Sendable, Equatable {
    /// Stable id — used as the Keychain account and to match snapshot providers.
    let id: String
    let displayName: String
    /// Only LiteLLM: needs a user-supplied base URL alongside the key.
    let needsBaseURL: Bool
    /// True when StackPulse can fetch a real, verified balance for this provider
    /// (OpenRouter, LiteLLM, DeepSeek). For the rest the key is stored and usable,
    /// but there is no balance endpoint to read — reported plainly, never as a
    /// promise (see `APIKeyProviders.noBalanceNote`).
    let hasLiveBalance: Bool
    /// A masked-field placeholder hinting at the key format.
    let placeholder: String
}

/// The curated list of BYOK providers, in display order. Extend this to add a
/// provider; wire an actual fetcher in `ProviderBalanceClient.fetchBalance`.
enum APIKeyProviders {
    static let all: [APIKeyProviderInfo] = [
        .init(id: "open_router", displayName: "OpenRouter", needsBaseURL: false,
              hasLiveBalance: true, placeholder: "sk-or-v1-…"),
        .init(id: "litellm", displayName: "LiteLLM", needsBaseURL: true,
              hasLiveBalance: true, placeholder: "sk-…"),
        .init(id: "openai", displayName: "OpenAI", needsBaseURL: false,
              hasLiveBalance: false, placeholder: "sk-…"),
        .init(id: "zai", displayName: "Z.ai", needsBaseURL: false,
              hasLiveBalance: false, placeholder: "…"),
        .init(id: "mistral", displayName: "Mistral", needsBaseURL: false,
              hasLiveBalance: false, placeholder: "…"),
        .init(id: "deepseek", displayName: "DeepSeek", needsBaseURL: false,
              hasLiveBalance: true, placeholder: "sk-…"),
        .init(id: "perplexity", displayName: "Perplexity", needsBaseURL: false,
              hasLiveBalance: false, placeholder: "pplx-…"),
        .init(id: "groq", displayName: "Groq", needsBaseURL: false,
              hasLiveBalance: false, placeholder: "gsk_…"),
    ]

    static let allIDs: [String] = all.map(\.id)

    static func info(for id: String) -> APIKeyProviderInfo? {
        all.first { $0.id == id }
    }

    static func displayName(for id: String) -> String {
        info(for: id)?.displayName ?? id
    }

    /// The honest statement for a provider StackPulse can store a key for but has
    /// no way to read a balance from.
    ///
    /// This replaced "balance coming soon" — a promise the app has no plan to keep
    /// and, for most of these providers, no public endpoint that would let it. A
    /// standing "coming soon" is a small lie that never resolves; this states the
    /// fact instead. The key is genuinely saved and usable (the provider reads as
    /// Connected), so the note leads with what *is* true.
    static func noBalanceNote(for id: String) -> String {
        "Key saved. \(displayName(for: id)) has no balance StackPulse can read, so none is shown."
    }

    /// The short chip label for the same state.
    static let noBalanceLabel = "No balance readout"
}

// MARK: - Balance fetcher

/// Per-provider credit-balance fetchers for BYOK connections.
///
/// SECURITY (this whole type is the network boundary, mirroring
/// `AnthropicUsageClient`):
///   • The API key is passed in, held only in a local, sent ONLY to the exact
///     provider endpoint over HTTPS as a `Bearer` header, and dropped. It is
///     never logged, never persisted, never printed.
///   • The raw HTTP response body is never logged — only parsed. Every failure
///     degrades to an empty balance plus a short, generic error string (never
///     the key or the response body).
///   • A provider with no key is never contacted — the caller (`SnapshotStore`)
///     only invokes this for ids that have a saved key.
///
/// All entry points are `nonisolated`/`static` and return `Sendable` values, so
/// they compose cleanly with Swift 6 strict concurrency: read key → fetch →
/// parse → hand a `ProviderBalance` to the store. The parsers are pure and are
/// exercised directly by `_selftest()`.
enum ProviderBalanceClient {
    /// Result of a balance fetch. `error` is a short, user-facing note (never the
    /// key or raw response); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var balance: ProviderBalance?
        var error: String?

        static let empty = Outcome(balance: nil, error: nil)
    }

    // MARK: Public entry point

    /// Fetches the credit balance for a provider that has a stored key. Providers
    /// without a balance endpoint return a note-only balance that states so plainly
    /// — nothing is fabricated, and the connection still reads as saved. Never throws.
    static func fetchBalance(providerID: String, key: String, baseURL: String?) async -> Outcome {
        switch providerID {
        case "open_router":
            return await fetchOpenRouter(key: key)
        case "litellm":
            return await fetchLiteLLM(key: key, baseURL: baseURL)
        case "deepseek":
            return await fetchDeepSeek(key: key)
        default:
            // Stored, but no balance endpoint here — say so; do NOT invent one and
            // do NOT promise one.
            return Outcome(
                balance: ProviderBalance(note: APIKeyProviders.noBalanceNote(for: providerID)),
                error: nil
            )
        }
    }

    // MARK: OpenRouter

    /// `GET https://openrouter.ai/api/v1/credits` (Bearer key) → `{ data: {
    /// total_credits, total_usage } }`. Falls back to the older `/auth/key`
    /// shape `{ data: { limit?, usage } }` when `/credits` returns 404.
    private static func fetchOpenRouter(key: String) async -> Outcome {
        let base = "https://openrouter.ai/api/v1/"

        // 1) Modern /credits endpoint.
        switch await request(URL(string: base + "credits")!, key: key) {
        case .ok(let data):
            if let bal = parseOpenRouter(data) { return Outcome(balance: bal, error: nil) }
            return Outcome(balance: nil, error: "OpenRouter balance: unexpected response.")
        case .unauthorized:
            return Outcome(balance: nil, error: "Check your OpenRouter API key.")
        case .notFound:
            break   // fall through to /auth/key
        case .httpError(let code):
            return Outcome(balance: nil, error: "OpenRouter balance unavailable (HTTP \(code)).")
        case .failure:
            return Outcome(balance: nil, error: "OpenRouter balance unavailable (offline?).")
        }

        // 2) Legacy /auth/key fallback.
        switch await request(URL(string: base + "auth/key")!, key: key) {
        case .ok(let data):
            if let bal = parseOpenRouter(data) { return Outcome(balance: bal, error: nil) }
            return Outcome(balance: nil, error: "OpenRouter balance: unexpected response.")
        case .unauthorized:
            return Outcome(balance: nil, error: "Check your OpenRouter API key.")
        case .notFound, .httpError, .failure:
            return Outcome(balance: nil, error: "OpenRouter balance unavailable.")
        }
    }

    // MARK: LiteLLM

    /// `GET <base>/key/info` (Bearer key), where `<base>` is the user's LiteLLM
    /// host with any trailing `/v1` stripped → `{ info: { spend, max_budget } }`.
    private static func fetchLiteLLM(key: String, baseURL: String?) async -> Outcome {
        guard let url = liteLLMKeyInfoURL(baseURL) else {
            return Outcome(balance: nil, error: "Set your LiteLLM base URL.")
        }
        switch await request(url, key: key) {
        case .ok(let data):
            if let bal = parseLiteLLM(data) { return Outcome(balance: bal, error: nil) }
            return Outcome(balance: nil, error: "LiteLLM balance: unexpected response.")
        case .unauthorized:
            return Outcome(balance: nil, error: "Check your LiteLLM key.")
        case .notFound:
            return Outcome(balance: nil, error: "LiteLLM /key/info not found — check the base URL.")
        case .httpError(let code):
            return Outcome(balance: nil, error: "LiteLLM balance unavailable (HTTP \(code)).")
        case .failure:
            return Outcome(balance: nil, error: "LiteLLM balance unavailable (offline?).")
        }
    }

    // MARK: DeepSeek

    /// `GET https://api.deepseek.com/user/balance` (Bearer key) → `{ "balance_infos":
    /// [{ "currency", "total_balance", "granted_balance", "topped_up_balance" }] }`.
    /// Amounts are strings. `total_balance` is what's left to spend; there's no
    /// clean "limit" so we show remaining (+ a granted-credit note).
    private static func fetchDeepSeek(key: String) async -> Outcome {
        switch await request(URL(string: "https://api.deepseek.com/user/balance")!, key: key) {
        case .ok(let data):
            if let bal = parseDeepSeek(data) { return Outcome(balance: bal, error: nil) }
            return Outcome(balance: nil, error: "DeepSeek balance: unexpected response.")
        case .unauthorized:
            return Outcome(balance: nil, error: "Check your DeepSeek API key.")
        case .notFound, .httpError, .failure:
            return Outcome(balance: nil, error: "DeepSeek balance unavailable.")
        }
    }

    /// Parses DeepSeek's `/user/balance`. Prefers the USD entry when several
    /// currencies are present. Pure and side-effect-free.
    static func parseDeepSeek(_ data: Data) -> ProviderBalance? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let infos = root["balance_infos"] as? [[String: Any]], !infos.isEmpty
        else { return nil }

        let info = infos.first { ($0["currency"] as? String)?.uppercased() == "USD" } ?? infos[0]
        guard let total = coerceDouble(info["total_balance"]) else { return nil }
        let currency = (info["currency"] as? String) ?? "USD"
        let granted = coerceDouble(info["granted_balance"]) ?? 0
        let note = granted > 0 ? String(format: "Includes $%.2f granted credit", granted) : nil
        return ProviderBalance(
            remaining_usd: total,
            used_usd: nil,
            limit_usd: nil,
            currency: currency,
            note: note
        )
    }

    // MARK: Networking

    private enum HTTPOutcome {
        case ok(Data)
        case unauthorized       // 401 / 403
        case notFound           // 404
        case httpError(Int)     // any other non-200
        case failure            // offline / TLS / timeout / non-HTTP
    }

    /// A single GET with the key on the `Authorization: Bearer` header and
    /// nowhere else. Never logs the key, the URL's credentials, or the body.
    private static func request(_ url: URL, key: String) async -> HTTPOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        // The key goes out on THIS header, to THIS endpoint, and nowhere else.
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

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
            // Report the category, never the details.
            return .failure
        }
    }

    // MARK: Parsing (pure, headless-testable)

    /// Parses an OpenRouter balance payload, tolerating BOTH shapes:
    ///   • `/credits`  → `{ "data": { "total_credits": D, "total_usage": D } }`
    ///   • `/auth/key` → `{ "data": { "limit": D?, "usage": D } }` (limit null =
    ///     unlimited ⇒ remaining unknown)
    /// Pure and side-effect-free — never touches the network, Keychain, or disk.
    static func parseOpenRouter(_ data: Data) -> ProviderBalance? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let obj = root["data"] as? [String: Any]
        else { return nil }

        // /credits shape.
        if let total = coerceDouble(obj["total_credits"]) {
            let usage = coerceDouble(obj["total_usage"]) ?? 0
            return ProviderBalance(
                remaining_usd: total - usage,
                used_usd: usage,
                limit_usd: total,
                currency: "USD",
                note: nil
            )
        }

        // /auth/key shape.
        if obj["usage"] != nil || obj.keys.contains("limit") {
            let usage = coerceDouble(obj["usage"]) ?? 0
            let limit = coerceDouble(obj["limit"])            // nil ⇒ unlimited
            let remaining = limit.map { $0 - usage }
            return ProviderBalance(
                remaining_usd: remaining,
                used_usd: usage,
                limit_usd: limit,
                currency: "USD",
                note: nil
            )
        }

        return nil
    }

    /// Parses a LiteLLM `/key/info` payload: `{ "info": { "spend": D,
    /// "max_budget": D? } }` (fields also tolerated at the root). `max_budget`
    /// may be null (no budget ⇒ remaining unknown). Pure and side-effect-free.
    static func parseLiteLLM(_ data: Data) -> ProviderBalance? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let info = (root["info"] as? [String: Any]) ?? root
        let spend = coerceDouble(info["spend"])
        let maxBudget = coerceDouble(info["max_budget"])
        guard spend != nil || maxBudget != nil else { return nil }

        let remaining: Double?
        if let m = maxBudget, let s = spend { remaining = m - s } else { remaining = nil }
        return ProviderBalance(
            remaining_usd: remaining,
            used_usd: spend,
            limit_usd: maxBudget,
            currency: "USD",
            note: nil
        )
    }

    /// Normalizes a user-entered LiteLLM base URL into the `/key/info` URL:
    /// adds a scheme when missing, strips trailing slashes and a trailing `/v1`,
    /// then appends `key/info`. Pure — exercised by `_selftest()`. Returns `nil`
    /// for empty/invalid input.
    static func liteLLMKeyInfoURL(_ raw: String?) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }

        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        guard let base = URL(string: s) else { return nil }
        return base.appendingPathComponent("key/info")
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

    /// Exercises the pure parsers against embedded fixtures, returning `true`
    /// when every assertion holds. Pure and offline — safe to run headlessly (it
    /// never touches the Keychain or network). Kept in the shipping binary (not
    /// behind `#if DEBUG`) so it can be compiled + run standalone for
    /// verification, exactly like `AnthropicUsageClient._selftest`.
    ///
    /// Fixtures validated against:
    ///
    /// OpenRouter `/credits`:
    /// ```json
    /// { "data": { "total_credits": 20.0, "total_usage": 7.5 } }
    /// ```
    /// → remaining 12.5, used 7.5, limit 20.
    ///
    /// OpenRouter `/auth/key` (legacy, with a null unlimited limit variant):
    /// ```json
    /// { "data": { "limit": 10.0, "usage": 3.0 } }
    /// { "data": { "limit": null, "usage": 3.0 } }
    /// ```
    /// → remaining 7 / nil.
    ///
    /// LiteLLM `/key/info` (with a missing-budget variant):
    /// ```json
    /// { "info": { "spend": 4.25, "max_budget": 50.0 } }
    /// { "info": { "spend": 4.25 } }
    /// ```
    /// → remaining 45.75 / nil.
    static func _selftest() -> Bool {
        func approx(_ a: Double?, _ b: Double) -> Bool {
            guard let a else { return false }
            return abs(a - b) < 0.0001
        }

        // 1) OpenRouter /credits.
        let credits = """
        { "data": { "total_credits": 20.0, "total_usage": 7.5 } }
        """
        guard let c = parseOpenRouter(Data(credits.utf8)),
              approx(c.remaining_usd, 12.5),
              approx(c.used_usd, 7.5),
              approx(c.limit_usd, 20.0),
              c.currency == "USD",
              c.note == nil,
              c.hasAmounts
        else { return false }

        // 2) OpenRouter /auth/key with a finite limit.
        let authKey = """
        { "data": { "limit": 10.0, "usage": 3.0 } }
        """
        guard let a = parseOpenRouter(Data(authKey.utf8)),
              approx(a.remaining_usd, 7.0),
              approx(a.used_usd, 3.0),
              approx(a.limit_usd, 10.0)
        else { return false }

        // 3) OpenRouter /auth/key with a null (unlimited) limit → remaining unknown.
        let unlimited = """
        { "data": { "limit": null, "usage": 3.0 } }
        """
        guard let u = parseOpenRouter(Data(unlimited.utf8)),
              u.remaining_usd == nil,
              approx(u.used_usd, 3.0),
              u.limit_usd == nil
        else { return false }

        // 4) LiteLLM /key/info with a budget.
        let litellm = """
        { "info": { "spend": 4.25, "max_budget": 50.0 } }
        """
        guard let l = parseLiteLLM(Data(litellm.utf8)),
              approx(l.used_usd, 4.25),
              approx(l.limit_usd, 50.0),
              approx(l.remaining_usd, 45.75)
        else { return false }

        // 5) LiteLLM with no budget → remaining unknown, spend still shown.
        let litellmNoBudget = """
        { "info": { "spend": 4.25 } }
        """
        guard let ln = parseLiteLLM(Data(litellmNoBudget.utf8)),
              approx(ln.used_usd, 4.25),
              ln.limit_usd == nil,
              ln.remaining_usd == nil
        else { return false }

        // 6) LiteLLM base-URL normalization: scheme added, trailing /v1 + slashes
        //    stripped, /key/info appended.
        guard liteLLMKeyInfoURL("https://litellm.example.com/v1")?.absoluteString
                == "https://litellm.example.com/key/info",
              liteLLMKeyInfoURL("litellm.example.com/")?.absoluteString
                == "https://litellm.example.com/key/info",
              liteLLMKeyInfoURL("http://localhost:4000/v1/")?.absoluteString
                == "http://localhost:4000/key/info",
              liteLLMKeyInfoURL("")  == nil,
              liteLLMKeyInfoURL(nil) == nil,
              liteLLMKeyInfoURL("   ") == nil
        else { return false }

        // 7) DeepSeek /user/balance (string amounts; prefers the USD entry).
        let deepseek = """
        { "is_available": true, "balance_infos": [
          { "currency": "USD", "total_balance": "8.80", "granted_balance": "0.00", "topped_up_balance": "8.80" },
          { "currency": "CNY", "total_balance": "60.00", "granted_balance": "0.00", "topped_up_balance": "60.00" } ] }
        """
        guard let ds = parseDeepSeek(Data(deepseek.utf8)),
              approx(ds.remaining_usd, 8.80),
              ds.currency == "USD",
              ds.used_usd == nil
        else { return false }

        // 8) Garbage / empty inputs degrade to nil.
        guard parseOpenRouter(Data("not json".utf8)) == nil,
              parseOpenRouter(Data("{}".utf8)) == nil,
              parseOpenRouter(Data(#"{"data":{}}"#.utf8)) == nil,
              parseLiteLLM(Data("not json".utf8)) == nil,
              parseLiteLLM(Data("{}".utf8)) == nil
        else { return false }

        return true
    }
}
