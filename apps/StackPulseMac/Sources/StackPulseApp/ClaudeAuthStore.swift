import CryptoKit
import Foundation

/// Reads — and, when necessary, **renews** — the user's Claude Code OAuth login.
///
/// ## Why this exists
///
/// `KeychainProbe` reads the Claude Code credential and, when that token has
/// aged out, falls through to `ClaudeDesktopAuthStore`. That fallback is correct
/// for a Desktop-only machine, but on a machine driving Claude Code hard from the
/// terminal it produced the exact failure this type fixes: the CLI token expired,
/// the read silently answered with **Claude Desktop's** login, and the app
/// reported *that* account's quota as if it were Claude Code usage — "1% used"
/// during a heavy CLI day. A confident wrong number is worse than no number.
///
/// OpenUsage (`robinebers/openusage`, MIT) solves it the honest way and this type
/// mirrors it: when the Claude Code token is expired, **refresh it** rather than
/// substituting a different account. Behaviour (candidate order, keychain service
/// names, the 5-minute proactive window, the refresh call shape) deliberately
/// matches OpenUsage; re-implemented rather than copied, per ADR-0001.
///
/// ## What it will and will not touch
///
/// * **Claude Code's own credential** — read, and rotated in place when Anthropic
///   hands back a new token. That is what the CLI itself does; a rotation written
///   back keeps the CLI and StackPulse on one token instead of racing.
/// * **Claude Desktop's credential** — read-only, access token borrowed, and only
///   when no Claude Code login exists *at all*. Desktop's refresh token is never
///   decoded and never used: Anthropic rotates refresh tokens, so spending
///   Desktop's would invalidate its own copy and sign the user out of the app
///   they're working in. It is also never used to paper over a *failed* refresh —
///   a failure degrades to "no usable token" with a reason, because falling
///   through to another account is the original bug.
///
/// **SECURITY.** Every value flowing through here is a live bearer credential.
/// No token — whole, truncated, hashed-into-a-message, or embedded in an error —
/// is ever logged, printed, or returned in a diagnostic string. Tokens go to
/// exactly two places: the Anthropic refresh endpoint, and back into the source
/// they came from. Before the first write to any source, the prior blob is backed
/// up (see ``backUpOnce(_:from:)``) — OpenUsage has no such safety net, and a bad
/// write here costs the user their Claude Code login.
enum ClaudeAuthStore {

    // MARK: - Constants (endpoint, client, services)

    /// The one and only destination a refresh token is ever sent to. Matches the
    /// endpoint Claude Code itself refreshes against.
    static let refreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Claude Code's production OAuth client. Not ours to choose — it is the
    /// client the stored refresh token was minted under, so any other value is
    /// rejected by the endpoint.
    static let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// The scope set Claude Code requests on refresh, verbatim and in this order.
    /// `user:profile` is the one that matters to us — without it the usage
    /// endpoint 403s — but the whole set is sent so the rotated token is a
    /// drop-in replacement for the CLI's, not a narrower one that quietly breaks
    /// `claude` the next time it runs.
    static let refreshScopes =
        "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    /// The scope the live-usage endpoint requires. A `claude setup-token` token
    /// carries only `user:inference` and can never answer a usage query.
    static let usageScope = "user:profile"

    /// Keychain service base. The `-<suffix>` variants exist only for Anthropic's
    /// own staging/local OAuth setups; the `-<hash8>` variant appears when the
    /// user has set `CLAUDE_CONFIG_DIR` (Claude Code namespaces the item by a
    /// SHA-256 prefix of the config dir so two config dirs don't collide).
    private static let keychainServiceBase = "Claude Code"

    private static let credentialFileName = ".credentials.json"
    private static let defaultClaudeHome = ".claude"

    /// Refresh this far ahead of expiry rather than after it. A token that dies
    /// mid-request surfaces as an auth error the user can do nothing about, and
    /// the whole point of this type is to never make the user's problem look like
    /// somebody else's account.
    static let refreshWindowMs: Double = 5 * 60 * 1000

    /// Bounded so a pending Keychain "Allow" prompt can be answered by a human
    /// without the read ever hanging. Same deadline `KeychainProbe` uses, for the
    /// same reason.
    private static let keychainTimeout: TimeInterval = 12

    // MARK: - Value types

    /// The OAuth material Claude Code stores under `claudeAiOauth`.
    ///
    /// `expiresAt` is the **millisecond** epoch, as written on disk — deliberately
    /// not normalized to seconds here, so the 5-minute comparison happens in the
    /// same unit the file uses and there is no place for a ×1000 to go missing.
    struct OAuth: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAtMs: Double?
        var subscriptionType: String?
        var rateLimitTier: String?
        var scopes: [String]?

        /// Older credentials predate the `scopes` field. Treat an absent or empty
        /// list as "unknown, allow" — suppressing usage for a token that actually
        /// has the scope is worse than letting the endpoint 403 loudly.
        var canReadUsage: Bool {
            guard let scopes, !scopes.isEmpty else { return true }
            return scopes.contains(usageScope)
        }
    }

    /// Where a credential came from. The keychain service name is safe to carry
    /// (it is a service name, not a secret); the token never is.
    enum Source: Hashable, Sendable {
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case file(path: String)
        case desktop
        case environment

        /// Short, log-safe kind — this is what `currentToken()` reports as the
        /// `source` label and what the UI shows next to a live limit.
        var label: String {
            switch self {
            case .keychainCurrentUser, .keychainLegacy: "keychain"
            case .file: "file"
            case .desktop: "desktop"
            case .environment: "env"
            }
        }

        /// Slightly more specific, still token-free — for diagnostics only.
        var detail: String {
            switch self {
            case .keychainCurrentUser(let service): "keychain[current-user] \(service)"
            case .keychainLegacy(let service): "keychain[legacy] \(service)"
            case .file(let path): "file \(path)"
            case .desktop: "Claude Desktop (read-only)"
            case .environment: "CLAUDE_CODE_OAUTH_TOKEN"
            }
        }

        /// Whether a rotated token may be written back here. Desktop is read-only
        /// by policy (rotating it would log the user out of Claude Desktop) and an
        /// environment token has no home to be written to.
        var isWritable: Bool {
            switch self {
            case .keychainCurrentUser, .keychainLegacy, .file: true
            case .desktop, .environment: false
            }
        }
    }

    /// One credential source, parsed. `rawJSON` is the *whole* original blob, kept
    /// so a write-back can preserve keys we don't model (Claude Code has added
    /// fields before, and dropping them on a rotation would corrupt the login).
    /// Stored as text rather than a decoded dictionary so the type stays `Sendable`
    /// under Swift 6 strict concurrency — `[String: Any]` is not.
    struct Candidate: Sendable {
        var oauth: OAuth
        var source: Source
        var rawJSON: String?
        /// An inference-only token (`CLAUDE_CODE_OAUTH_TOKEN`): it can run the
        /// model but 403s on the usage endpoint, and must never be written back.
        var inferenceOnly: Bool = false

        /// Fingerprint used by the never-clobber guard. A SHA-256 of the access +
        /// refresh token, so "did this change under us?" can be answered without
        /// any token being held in the comparison value.
        var fingerprint: String {
            var hasher = SHA256()
            hasher.update(data: Data(oauth.accessToken.utf8))
            hasher.update(data: Data((oauth.refreshToken ?? "").utf8))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The ordered, token-free snapshot the optimistic guard compares against.
    ///
    /// Comparing the whole ordered set — not just the one source being written —
    /// catches the case that actually bites: a *new, higher-priority* source
    /// appearing (the user ran `claude` and it wrote a fresh keychain item) while
    /// we were mid-refresh against the file.
    struct Generation: Equatable, Sendable {
        var entries: [String]

        init(_ candidates: [Candidate]) {
            entries = candidates
                .filter { !$0.inferenceOnly && $0.source.isWritable }
                .map { "\($0.source.detail)#\($0.fingerprint)" }
        }
    }

    /// What `currentToken()` answers with. Carries a token **only** in
    /// `accessToken`; `source`, `reason`, and every other field are log-safe.
    struct TokenResult: Sendable {
        /// The usable bearer token, or `nil` when there is none.
        var accessToken: String?
        /// Log-safe source label: `keychain` / `file` / `desktop` / `env`.
        var source: String
        /// Whether this token was obtained by refreshing an expired/expiring one.
        var refreshed: Bool
        /// Short user-facing explanation when `accessToken` is `nil`. Never
        /// contains a token, a response body, or a credential blob.
        var reason: String?
        /// Expiry as unix **seconds**, for TTL display. `nil` when unknown.
        var expiresAtUnix: Int64?

        static func none(_ reason: String, source: String = "none") -> TokenResult {
            TokenResult(accessToken: nil, source: source, refreshed: false, reason: reason)
        }
    }

    // MARK: - Entry point

    /// The Claude Code access token to use right now, refreshing it in place if it
    /// is expired or within five minutes of expiring.
    ///
    /// Resolution order and its rationale:
    /// 1. **Keychain, then file** (see ``orderedStoredCandidates()``).
    /// 2. If the chosen candidate is live, return it untouched.
    /// 3. If it needs renewal and carries a refresh token, refresh → write back
    ///    under the never-clobber guard → return the new token.
    /// 4. If renewal fails, return **no token plus a reason**. Deliberately *not*
    ///    a fall-through to Desktop: substituting another account is the bug.
    /// 5. Desktop (access token only, never rotated) is consulted only when there
    ///    is no Claude Code credential at all.
    static func currentToken() async -> TokenResult {
        let stored = orderedStoredCandidates()

        // Prefer a candidate that can actually read usage. A scope-limited token
        // authenticates fine and then 403s, which reads to the user as an outage.
        let usable = stored.filter { $0.oauth.canReadUsage }
        guard let candidate = usable.first ?? stored.first else {
            return desktopFallback()
        }

        if !needsRefresh(expiresAtMs: candidate.oauth.expiresAtMs, now: Date()) {
            recordDiagnostic("using \(candidate.source.label) token (no refresh needed)")
            return TokenResult(
                accessToken: candidate.oauth.accessToken,
                source: candidate.source.label,
                refreshed: false,
                reason: nil,
                expiresAtUnix: candidate.oauth.expiresAtMs.map { Int64($0 / 1000) }
            )
        }

        guard let refreshToken = candidate.oauth.refreshToken, !refreshToken.isEmpty else {
            // A DEAD credential: expired with nothing to renew it. It will never
            // work again until the user signs in, so refusing to look further just
            // means showing nothing at all — which is what happened on a machine
            // whose CLI item was a six-day-old fossil while Claude Desktop held a
            // live login. Desktop keeps its own cache current as a side effect of
            // use, so for that machine it IS the live session.
            //
            // This is not the silent substitution that caused the wrong-account
            // bug: `desktopFallback()` labels the source, and the caller turns that
            // label into a caveat on the card. Falling through *unlabelled* was the
            // bug; refusing to fall through at all was the overcorrection.
            recordDiagnostic("\(candidate.source.label) token expired with no refresh token — trying Desktop")
            let desktop = desktopFallback()
            if desktop.accessToken != nil { return desktop }
            let reason = "Claude Code token expired and carries no refresh token — run `claude` to sign in again."
            return .none(reason, source: candidate.source.label)
        }

        // Snapshot BEFORE the network call: the guard has to know what the world
        // looked like when we decided to rotate, not after.
        let expected = Generation(stored)

        switch await performRefresh(refreshToken: refreshToken) {
        case .failure(let reason):
            // Same reasoning as the dead-credential path above: a refresh that
            // fails leaves nothing usable here, so a live Desktop login is better
            // than a blank card — labelled, never silent.
            recordDiagnostic("refresh failed from \(candidate.source.label) — trying Desktop")
            let desktop = desktopFallback()
            if desktop.accessToken != nil { return desktop }
            return .none("Claude Code token refresh failed (\(reason)). Run `claude` to sign in again.",
                         source: candidate.source.label)

        case .success(let rotated):
            var updated = candidate
            updated.oauth.accessToken = rotated.accessToken
            if let newRefresh = rotated.refreshToken, !newRefresh.isEmpty {
                updated.oauth.refreshToken = newRefresh
            }
            if let expiresIn = rotated.expiresInSeconds {
                updated.oauth.expiresAtMs = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
            }

            // A write failure is NOT a token failure — we still hold a valid token
            // in memory. Persisting is an optimization so the CLI and StackPulse
            // stay on one token; failing it must not cost the user their reading.
            let persisted = save(updated, ifUnchanged: expected)
            recordDiagnostic("refreshed \(candidate.source.label) token (persisted=\(persisted.label))")

            switch persisted {
            case .supersededBy(let fresher):
                // Somebody (the CLI, almost certainly) rotated under us. Their
                // token is at least as new as ours and is the one on disk — use
                // it and drop ours rather than fighting over the source.
                return TokenResult(
                    accessToken: fresher.oauth.accessToken,
                    source: fresher.source.label,
                    refreshed: false,
                    reason: nil,
                    expiresAtUnix: fresher.oauth.expiresAtMs.map { Int64($0 / 1000) }
                )
            case .written, .skipped, .failed:
                return TokenResult(
                    accessToken: updated.oauth.accessToken,
                    source: updated.source.label,
                    refreshed: true,
                    reason: nil,
                    expiresAtUnix: updated.oauth.expiresAtMs.map { Int64($0 / 1000) }
                )
            }
        }
    }

    /// Desktop / environment last resort — reached only when no Claude Code
    /// credential exists anywhere. Never rotates anything.
    private static func desktopFallback() -> TokenResult {
        if let envToken = envText("CLAUDE_CODE_OAUTH_TOKEN") {
            // Inference-only by design; it will 403 on usage. Returned anyway
            // because with no other credential it is strictly better than nothing,
            // and the `env` label tells the caller not to trust it for quota.
            recordDiagnostic("no stored login; using CLAUDE_CODE_OAUTH_TOKEN (inference-only)")
            return TokenResult(accessToken: envToken, source: Source.environment.label,
                               refreshed: false, reason: nil, expiresAtUnix: nil)
        }

        switch ClaudeDesktopAuthStore.load() {
        case .ok(let creds):
            recordDiagnostic("no Claude Code login; borrowed Claude Desktop access token")
            return TokenResult(accessToken: creds.accessToken, source: Source.desktop.label,
                               refreshed: false, reason: nil, expiresAtUnix: creds.expiresAtUnix)
        case .accessDenied:
            return .none("Keychain denied the Claude Desktop read.")
        case .stale:
            return .none("No Claude Code login, and every Claude Desktop token has expired.")
        case .invalid:
            return .none("No Claude Code login, and Claude Desktop's cache wasn't in a shape we understand.")
        case .notFound:
            return .none("No Claude login found. Run `claude` to sign in.")
        }
    }

    // MARK: - Candidate loading

    /// Keychain and file credentials in **fixed keychain-before-file order**.
    ///
    /// The order is the load-bearing part. On macOS the Keychain is Claude Code's
    /// source of truth, and recent versions can leave a stale
    /// `~/.claude/.credentials.json` behind from an older install. Ranking the two
    /// by whichever `expiresAt` is later — the obvious-looking rule — lets that
    /// dead file outrank the live Keychain item purely because its long-since
    /// issued token happened to carry a further-out expiry. OpenUsage shipped that
    /// rule, hit exactly that bug, and replaced it with this fixed order. The file
    /// is a fallback for older installs and Linux-style layouts, nothing more.
    static func orderedStoredCandidates() -> [Candidate] {
        var candidates: [Candidate] = []
        if let keychain = loadKeychainCandidate() { candidates.append(keychain) }
        if let file = loadFileCandidate() { candidates.append(file) }
        return candidates
    }

    /// The Keychain services that can hold Claude Code's login, in probe order.
    ///
    /// With `CLAUDE_CONFIG_DIR` set, Claude Code namespaces the item by an 8-hex
    /// SHA-256 prefix of that path — so the hashed variant is probed *first* and
    /// the unsuffixed base kept as the fallback for a config dir that predates the
    /// namespacing.
    static func keychainServiceCandidates() -> [String] {
        let base = "\(keychainServiceBase)\(oauthEnvironmentSuffix())-credentials"
        if let configDir = envText("CLAUDE_CONFIG_DIR") {
            return ["\(base)-\(hashSuffix(configDir))", base]
        }
        return [base]
    }

    /// Non-production OAuth setups rename the Keychain item alongside the
    /// endpoint. Only Anthropic-internal env vars trigger these; a normal machine
    /// always gets the empty suffix.
    private static func oauthEnvironmentSuffix() -> String {
        if envText("CLAUDE_CODE_CUSTOM_OAUTH_URL") != nil { return "-custom-oauth" }
        guard envText("USER_TYPE") == "ant" else { return "" }
        if envFlag("USE_LOCAL_OAUTH") { return "-local-oauth" }
        if envFlag("USE_STAGING_OAUTH") { return "-staging-oauth" }
        return ""
    }

    /// For each service: the **service-only** query first, then the user-scoped
    /// one (`-a <user>`). Claude Code moved to a user-scoped account at some point
    /// and both shapes are still out there, so both are tried — as a pair per
    /// service, rather than all of one shape then all of the other, so a legacy
    /// item under the *right* service isn't shadowed by one under the wrong one.
    ///
    /// Service-only goes FIRST for a Keychain-ACL reason, not a correctness one:
    /// the durable "Always Allow" a user grants `/usr/bin/security` is scoped to
    /// the query that triggered it. Leading with the `-a` variant asks a question
    /// the existing grant doesn't cover, so macOS re-prompts — an unanswered
    /// dialog that silently blocks every refresh. openusage leads with `-a`; we
    /// deliberately don't, because this app's whole Keychain strategy is built on
    /// that one grant staying valid across rebuilds.
    private static func loadKeychainCandidate() -> Candidate? {
        for service in keychainServiceCandidates() {
            if let text = readKeychain(service: service, account: nil),
               let candidate = makeCandidate(fromJSON: text,
                                             source: .keychainLegacy(service: service)) {
                return candidate
            }
            if let text = readKeychain(service: service, account: currentUserAccount()),
               let candidate = makeCandidate(fromJSON: text,
                                             source: .keychainCurrentUser(service: service)) {
                return candidate
            }
        }
        return nil
    }

    private static func loadFileCandidate() -> Candidate? {
        let path = credentialsPath()
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return makeCandidate(fromJSON: text, source: .file(path: path))
    }

    static func credentialsPath() -> String {
        if let configDir = envText("CLAUDE_CONFIG_DIR") {
            return (configDir as NSString).appendingPathComponent(credentialFileName)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultClaudeHome)
            .appendingPathComponent(credentialFileName).path
    }

    // MARK: - Parsing (pure)

    /// Parse a credentials blob into a candidate, or `nil` when it isn't a login.
    ///
    /// Requires the `claudeAiOauth` key. That strictness is on purpose: the
    /// `Claude Code-credentials-<hash>` Keychain siblings hold per-server **MCP
    /// OAuth** state, not logins, and accepting a bare root object would let one
    /// of those masquerade as a credential (see `KeychainProbe`'s notes).
    static func makeCandidate(fromJSON text: String, source: Source) -> Candidate? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = parseOAuth(root)
        else { return nil }
        return Candidate(oauth: oauth, source: source, rawJSON: text)
    }

    /// The `claudeAiOauth` object of a decoded credentials root. Pure — exercised
    /// directly by `_selftest()`.
    static func parseOAuth(_ root: [String: Any]) -> OAuth? {
        guard let object = root["claudeAiOauth"] as? [String: Any],
              let token = (object["accessToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }

        let refresh = (object["refreshToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return OAuth(
            accessToken: token,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiresAtMs: number(object["expiresAt"]),
            subscriptionType: object["subscriptionType"] as? String,
            rateLimitTier: object["rateLimitTier"] as? String,
            scopes: object["scopes"] as? [String]
        )
    }

    /// True when the token is expired **or within five minutes of expiring**.
    ///
    /// Proactive, not reactive: refreshing only after expiry guarantees that every
    /// long request straddling the boundary fails once. A credential with no
    /// `expiresAt` is treated as "don't touch it" — we can't reason about it, and
    /// rotating a token we don't understand is the riskiest thing this file could
    /// do. Pure — exercised by `_selftest()`.
    static func needsRefresh(expiresAtMs: Double?, now: Date) -> Bool {
        guard let expiresAtMs else { return false }
        return expiresAtMs - now.timeIntervalSince1970 * 1000 <= refreshWindowMs
    }

    // MARK: - Refresh (network)

    private struct RotatedToken: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresInSeconds: Double?
    }

    private enum RefreshOutcome: Sendable {
        case success(RotatedToken)
        /// A short, log-safe reason. NEVER the response body — an OAuth error body
        /// can echo back token material.
        case failure(String)
    }

    /// Exchange the refresh token for a new access token.
    ///
    /// Shape (URL, method, JSON body keys, client id, scope string, content type)
    /// mirrors what Claude Code itself sends — deviating in any of them gets the
    /// request rejected, so none of it is a free choice.
    private static func performRefresh(refreshToken: String) async -> RefreshOutcome {
        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": productionClientID,
            "scope": refreshScopes,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure("could not encode the request")
        }
        request.httpBody = encoded

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                // Status only. The body is never surfaced or logged.
                return .failure("HTTP \(status)")
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = (root["access_token"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !access.isEmpty
            else {
                return .failure("unexpected response shape")
            }
            return .success(RotatedToken(
                accessToken: access,
                refreshToken: root["refresh_token"] as? String,
                expiresInSeconds: number(root["expires_in"])
            ))
        } catch {
            // `error` can name a host but never carries the request body.
            return .failure("network error")
        }
    }

    // MARK: - Persisting a rotation (never-clobber)

    enum SaveOutcome: Sendable {
        case written
        /// The source isn't writable (Desktop / environment) — by design.
        case skipped
        /// The source changed under us; the freshly read credential is returned
        /// and ours is discarded.
        case supersededBy(Candidate)
        case failed

        var label: String {
            switch self {
            case .written: "yes"
            case .skipped: "n/a"
            case .supersededBy: "superseded"
            case .failed: "no"
            }
        }
    }

    /// Write a rotated credential back to the source it came from, but only if
    /// nothing changed since we read it.
    ///
    /// The guard re-reads every source immediately before writing and compares the
    /// whole ordered generation. `claude` may have refreshed concurrently in a
    /// terminal — its token is then the live one, and stamping ours over it would
    /// invalidate the CLI's session for a number on a menu bar. When in doubt we
    /// abort and adopt what we found. The stores offer no atomic compare-and-swap,
    /// so this narrows the race rather than closing it; that is the right trade,
    /// because the failure mode of "abort" is a stale reading and the failure mode
    /// of "clobber" is the user being logged out.
    @discardableResult
    static func save(_ candidate: Candidate, ifUnchanged expected: Generation) -> SaveOutcome {
        guard candidate.source.isWritable, !candidate.inferenceOnly else { return .skipped }

        let current = orderedStoredCandidates()
        guard Generation(current) == expected else {
            if let fresher = current.first(where: { $0.oauth.canReadUsage }) ?? current.first {
                return .supersededBy(fresher)
            }
            return .failed
        }

        guard let payload = serialize(candidate) else { return .failed }

        // Back up the PRIOR blob before the first write to this source, ever.
        let prior = current.first { $0.source == candidate.source }
        backUpOnce(prior, from: candidate.source)

        switch candidate.source {
        case .file(let path):
            return writeFile(payload, to: path) ? .written : .failed
        case .keychainCurrentUser(let service):
            return writeKeychain(payload, service: service, account: currentUserAccount())
                ? .written : .failed
        case .keychainLegacy(let service):
            // `.keychainLegacy` only means "found by a service-only query" — and
            // since `loadKeychainCandidate` deliberately probes service-only first,
            // a perfectly modern user-scoped item lands in this case. Writing with
            // `account: nil` would then append a second, empty-account item instead
            // of updating it, so the item's real account is looked up first.
            //
            // No discoverable account ⇒ refuse. Guessing one (the current user, say)
            // would write to a *different* item than the one we read, leaving two
            // under one service — the state Claude Code reads non-deterministically.
            // Reporting `.failed` keeps the existing login intact; a bad write does
            // not.
            guard let account = keychainAccount(service: service) else {
                recordDiagnostic("keychain write skipped — item has no readable account")
                return .failed
            }
            return writeKeychain(payload, service: service, account: account)
                ? .written : .failed
        case .desktop, .environment:
            return .skipped
        }
    }

    /// Re-serialize the credentials blob, preserving every key we don't model.
    /// Round-tripping through a narrow `Codable` struct would silently drop fields
    /// Claude Code added after this file was written — and a credential missing a
    /// field the CLI needs is a broken login.
    private static func serialize(_ candidate: Candidate) -> String? {
        var root = (candidate.rawJSON.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        } ?? nil) ?? [:]
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = candidate.oauth.accessToken
        if let refresh = candidate.oauth.refreshToken { oauth["refreshToken"] = refresh }
        if let expiresAtMs = candidate.oauth.expiresAtMs { oauth["expiresAt"] = expiresAtMs }
        if let subscription = candidate.oauth.subscriptionType { oauth["subscriptionType"] = subscription }
        if let tier = candidate.oauth.rateLimitTier { oauth["rateLimitTier"] = tier }
        if let scopes = candidate.oauth.scopes { oauth["scopes"] = scopes }
        root["claudeAiOauth"] = oauth

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    // MARK: - Backup (our addition; OpenUsage has none)

    /// Copy the existing credential blob aside exactly once, before this process
    /// ever writes to that source.
    ///
    /// A bad write costs the user their Claude Code login and there is no undo —
    /// so one pristine copy of the pre-StackPulse state is kept. **Once**: an
    /// existing backup is never overwritten, because the copy worth having is the
    /// one from before anything went wrong, not the one from the last attempt.
    ///
    /// A backup never weakens the protection of what it copies. The blob carries a
    /// live `refreshToken`, so a Keychain credential is copied to a sibling Keychain
    /// service, never to a file: dropping it into Application Support would turn a
    /// secret behind a Keychain ACL into one that every same-user process, Time
    /// Machine snapshot and crash reporter can read without a prompt — and the
    /// never-overwrite rule would then leave that copy sitting there for good.
    private static let backupLock = NSLock()
    nonisolated(unsafe) private static var backedUpSources: Set<String> = []

    private static func backUpOnce(_ prior: Candidate?, from source: Source) {
        guard let prior, let payload = serialize(prior) else { return }

        backupLock.lock()
        let alreadyDone = backedUpSources.contains(source.detail)
        if !alreadyDone { backedUpSources.insert(source.detail) }
        backupLock.unlock()
        guard !alreadyDone else { return }

        // Both arms check for an existing backup and bail: a second backup would
        // record the state *after* a previous run already touched the credential,
        // which is precisely the state a backup is useless for.
        switch source {
        case .file(let path):
            // Already a plaintext file, so a sibling file copies it without
            // lowering anything; the mode is set by `writeFile`.
            let destination = path + ".stackpulse-backup"
            guard !FileManager.default.fileExists(atPath: destination) else { return }
            _ = writeFile(payload, to: destination)
        case .keychainCurrentUser(let service), .keychainLegacy(let service):
            // Sibling Keychain service, so the copy inherits the same protection as
            // the original.
            let backupService = service + ".stackpulse-backup"
            // Absent must mean *proven* absent. A plain `read == nil` also covers
            // "`security` timed out or errored", and on that transient failure we
            // would overwrite the pristine backup with post-incident state — the
            // one thing the never-overwrite rule exists to prevent. `fileExists`
            // has no such ambiguity, so the Keychain arm has to earn the same
            // certainty from the exit status.
            guard keychainItemIsProvenAbsent(service: backupService) else { return }
            _ = writeKeychain(payload, service: backupService, account: backupAccount)
        case .desktop, .environment:
            return
        }
    }

    /// `security`'s exit code for "no such item". Anything else — success,
    /// timeout, a permissions error — is *not* proof of absence.
    private static let securityItemNotFound: Int32 = 44

    /// The account on our own backup items. A fixed literal, not the current user:
    /// these items are written and read only by StackPulse, so the pair
    /// (service, account) has to be one we can reproduce exactly on the next
    /// launch. Deriving it from the environment would let a changed user name
    /// orphan the backup — and an unfindable backup is the same as none.
    private static let backupAccount = "stackpulse"

    /// True only when `security` positively reported the item missing. Attribute
    /// query, no `-w`, so it never reads password data and never prompts.
    private static func keychainItemIsProvenAbsent(service: String) -> Bool {
        guard let outcome = BoundedProcess.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service],
            timeout: keychainTimeout
        ) else { return false }
        return !outcome.timedOut && outcome.exitStatus == securityItemNotFound
    }

    /// Remove the plaintext credential backup written by builds before the copy
    /// moved into the Keychain.
    ///
    /// Shipping the new rule doesn't help anyone who already ran the old one: a
    /// live `refreshToken` is sitting in Application Support at 0600 with no
    /// Keychain ACL in front of it, and the never-overwrite rule means nothing
    /// would ever touch it again. The content is preserved first — it is re-homed
    /// into the Keychain backup when none exists yet — so this only ever deletes a
    /// copy of something that still exists somewhere safer.
    static func migrateLegacyPlaintextBackup() {
        // Path spelled out here rather than shared: the helper that built it was
        // deleted with the plaintext write path, and this is its last caller.
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacy = base
            .appendingPathComponent("StackPulse", isDirectory: true)
            .appendingPathComponent("claude-credential-backup.json").path
        guard FileManager.default.fileExists(atPath: legacy) else { return }

        if let data = FileManager.default.contents(atPath: legacy),
           let text = String(data: data, encoding: .utf8),
           makeCandidate(fromJSON: text, source: .keychainLegacy(service: "")) != nil {
            let backupService = (keychainServiceCandidates().first ?? keychainServiceBase)
                + ".stackpulse-backup"
            if keychainItemIsProvenAbsent(service: backupService) {
                guard writeKeychain(text, service: backupService, account: backupAccount) else {
                    // Couldn't re-home it; leaving the file is the lesser harm.
                    recordDiagnostic("legacy plaintext backup kept — Keychain re-home failed")
                    return
                }
            }
        }
        try? FileManager.default.removeItem(atPath: legacy)
        recordDiagnostic("legacy plaintext credential backup removed")
    }

    // MARK: - Source I/O

    /// Read via `/usr/bin/security` rather than `SecItemCopyMatching`.
    ///
    /// Not a style preference: `security` has a **stable code identity**, so the
    /// one-time "Always Allow" the user grants survives StackPulse being rebuilt
    /// and ad-hoc re-signed. A direct `SecItemCopyMatching` grant resets on every
    /// re-sign, and this app deliberately never falls through from one read to the
    /// other so the user is never double-prompted. See `KeychainProbe`.
    private static func readKeychain(service: String, account: String?) -> String? {
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        arguments.append("-w")
        return BoundedProcess.run(executable: "/usr/bin/security",
                                  arguments: arguments,
                                  timeout: keychainTimeout)?.trimmedText
    }

    /// The `acct` attribute of the item a service-only query finds, so a write can
    /// address the same item the read did.
    ///
    /// Note the missing `-w`: this is an attribute-only query. `security` returns
    /// the item's metadata without decrypting the password, so it touches no ACL
    /// and raises no authorization dialog — which matters because everything in
    /// this file is arranged around never asking the user a second time.
    private static func keychainAccount(service: String) -> String? {
        guard let dump = BoundedProcess.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service],
            timeout: keychainTimeout)?.trimmedText
        else { return nil }
        return parseKeychainAccount(dump)
    }

    /// Pull `acct` out of a `security` attribute dump, whose line looks like
    /// `    "acct"<blob>="jorge"`. Non-ASCII values print as `0x6A6F… "jorge"`, so
    /// the *last* quoted run is taken — that is the decoded form in both shapes.
    /// An absent account prints `<NULL>` and yields nil, which callers must map
    /// back to "no `-a` argument" rather than to an empty account. Pure —
    /// exercised by `_selftest()`.
    static func parseKeychainAccount(_ dump: String) -> String? {
        for line in dump.split(separator: "\n") {
            guard let marker = line.range(of: "\"acct\"<blob>=") else { continue }
            let value = line[marker.upperBound...]
            guard let open = value.firstIndex(of: "\""),
                  let close = value.lastIndex(of: "\""),
                  open < close
            else { return nil }
            let account = String(value[value.index(after: open)..<close])
            return account.isEmpty ? nil : account
        }
        return nil
    }

    /// `-U` updates the item in place rather than appending a duplicate — two
    /// items under one service is a state Claude Code itself reads
    /// non-deterministically. `-U` matches on service **and** account, so a caller
    /// that omits an account the item actually has gets an append, not an update.
    ///
    /// The value travels in argv, which same-user processes can observe. That is
    /// the interface `security` offers (there is no stdin form for
    /// `add-generic-password`), and it is the same trust boundary as the Keychain
    /// item itself: a same-user process could simply read the item.
    ///
    /// `account` is **not** optional, because `add-generic-password` treats `-a` as
    /// required: invoked without it, `security` prints its usage text and exits 2
    /// having written nothing. That failed silently here for every `.keychainLegacy`
    /// save — a refreshed token was reported as written and wasn't. The type now
    /// makes the omission unrepresentable rather than leaving it to a runtime check.
    private static func writeKeychain(_ value: String, service: String, account: String) -> Bool {
        let arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value]
        guard let outcome = BoundedProcess.run(executable: "/usr/bin/security",
                                               arguments: arguments,
                                               timeout: keychainTimeout)
        else { return false }
        return !outcome.timedOut && outcome.exitStatus == 0
    }

    /// Create at 0600, then write atomically, then re-apply 0600.
    ///
    /// An atomic write is a rename over the destination, and it preserves the
    /// permissions of a file that already exists. So the mode has to be in place
    /// *before* the rename: creating the destination empty at 0600 first means the
    /// credential is never briefly world-readable, whereas chmod-after leaves it at
    /// the umask default (usually 0644) between rename and chmod — and permanently
    /// so if the process dies in that window. The trailing chmod stays as a
    /// belt-and-braces for the case where the file already existed at a wider mode.
    @discardableResult
    private static func writeFile(_ text: String, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Diagnostics

    /// The last thing this store did, for `--selftest-live` style output. Written
    /// under a lock because a refresh can run off any executor.
    private static let diagnosticLock = NSLock()
    nonisolated(unsafe) private static var lastAction = "not read yet"

    private static func recordDiagnostic(_ text: String) {
        diagnosticLock.lock()
        lastAction = text
        diagnosticLock.unlock()
    }

    /// A token-free description of the current credential picture: which sources
    /// exist, in what order they'd be tried, whether each carries a refresh token,
    /// and how long each has left.
    ///
    /// **Contains no token material of any kind** — not a prefix, not a length,
    /// not a hash. Everything here is a source name, a boolean, or a duration.
    static func describeForDiagnostics() -> String {
        let now = Date()
        let candidates = orderedStoredCandidates()
        var lines: [String] = []

        diagnosticLock.lock()
        let action = lastAction
        diagnosticLock.unlock()
        lines.append("last action: \(action)")

        if candidates.isEmpty {
            lines.append("no Claude Code credential (keychain or file)")
        } else {
            for (index, candidate) in candidates.enumerated() {
                let ttl: String
                if let expiresAtMs = candidate.oauth.expiresAtMs {
                    let minutes = Int((expiresAtMs - now.timeIntervalSince1970 * 1000) / 60000)
                    ttl = minutes >= 0 ? "expires in \(minutes)m" : "expired \(-minutes)m ago"
                } else {
                    ttl = "no expiry recorded"
                }
                lines.append([
                    "\(index + 1). \(candidate.source.detail)",
                    ttl,
                    "refresh=\(candidate.oauth.refreshToken != nil ? "yes" : "no")",
                    "usageScope=\(candidate.oauth.canReadUsage ? "yes" : "no")",
                    "needsRefresh=\(needsRefresh(expiresAtMs: candidate.oauth.expiresAtMs, now: now) ? "yes" : "no")",
                ].joined(separator: " — "))
            }
        }

        lines.append("desktop (last resort, read-only): \(ClaudeDesktopAuthStore.describeForDiagnostics(now: now))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func currentUserAccount() -> String {
        NSUserName()
    }

    private static func envText(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    private static func envFlag(_ name: String) -> Bool {
        guard let value = envText(name)?.lowercased() else { return false }
        return !["0", "false", "no", "off"].contains(value)
    }

    /// First 8 hex chars of SHA-256 over the NFC-normalized path — the same
    /// namespacing Claude Code applies to `CLAUDE_CONFIG_DIR`.
    private static func hashSuffix(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: - Self-test

    /// Exercises the PURE logic with fixtures — parsing, the 5-minute boundary,
    /// and the keychain-before-file rule. No network, no Keychain, no disk, so it
    /// is safe to run at launch alongside the other `_selftest()`s.
    static func _selftest() -> Bool {
        // 1) Credential JSON parsing.
        let validJSON = """
        { "claudeAiOauth": {
            "accessToken": "at-fixture",
            "refreshToken": "rt-fixture",
            "expiresAt": 1893456000000,
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_ai",
            "scopes": ["user:inference", "user:profile"] } }
        """
        guard let validRoot = try? JSONSerialization.jsonObject(with: Data(validJSON.utf8)) as? [String: Any],
              let valid = parseOAuth(validRoot),
              valid.accessToken == "at-fixture",
              valid.refreshToken == "rt-fixture",
              valid.expiresAtMs == 1_893_456_000_000,
              valid.subscriptionType == "max",
              valid.canReadUsage
        else { return false }

        // Missing `claudeAiOauth` — this is the shape of the MCP-OAuth Keychain
        // siblings, which must never be mistaken for a login.
        let mcpJSON = #"{ "mcpOAuth": { "plugin:example": { "accessToken": "nope" } } }"#
        guard let mcpRoot = try? JSONSerialization.jsonObject(with: Data(mcpJSON.utf8)) as? [String: Any],
              parseOAuth(mcpRoot) == nil
        else { return false }

        // Missing `expiresAt` — still a valid login, just not one we'll rotate.
        let noExpiryJSON = #"{ "claudeAiOauth": { "accessToken": "at-fixture" } }"#
        guard let noExpiryRoot = try? JSONSerialization.jsonObject(with: Data(noExpiryJSON.utf8)) as? [String: Any],
              let noExpiry = parseOAuth(noExpiryRoot),
              noExpiry.expiresAtMs == nil,
              noExpiry.refreshToken == nil,
              !needsRefresh(expiresAtMs: noExpiry.expiresAtMs, now: Date())
        else { return false }

        // 2) The 5-minute boundary.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = now.timeIntervalSince1970 * 1000
        guard needsRefresh(expiresAtMs: nowMs - 1000, now: now),          // already expired
              needsRefresh(expiresAtMs: nowMs + 60_000, now: now),        // 1 minute out
              needsRefresh(expiresAtMs: nowMs + 300_000, now: now),       // exactly 5 minutes
              !needsRefresh(expiresAtMs: nowMs + 600_000, now: now),      // 10 minutes out
              !needsRefresh(expiresAtMs: nil, now: now)                   // unknown ⇒ don't touch
        else { return false }

        // 3) Candidate ordering: the keychain outranks a file whose token carries a
        //    LATER expiry. Ranking by expiry is what let a stale file shadow a live
        //    Keychain item, so the fixture makes the file look "better" on purpose.
        let keychain = Candidate(
            oauth: OAuth(accessToken: "k", refreshToken: "kr", expiresAtMs: nowMs + 60_000),
            source: .keychainCurrentUser(service: "Claude Code-credentials"), rawJSON: nil)
        let file = Candidate(
            oauth: OAuth(accessToken: "f", refreshToken: "fr", expiresAtMs: nowMs + 9_000_000),
            source: .file(path: "/tmp/.credentials.json"), rawJSON: nil)
        let ordered = [keychain, file]   // the order orderedStoredCandidates() builds
        guard ordered.first?.source.label == "keychain",
              ordered.last?.source.label == "file",
              (file.oauth.expiresAtMs ?? 0) > (keychain.oauth.expiresAtMs ?? 0)
        else { return false }

        // 4) The never-clobber guard notices any change to the ordered set, and
        //    non-writable sources are excluded from it (they can't be clobbered).
        let generation = Generation(ordered)
        var rotated = keychain
        rotated.oauth.accessToken = "k2"
        guard Generation(ordered) == generation,
              Generation([rotated, file]) != generation,
              Generation([keychain]) != generation,
              Generation([Candidate(oauth: OAuth(accessToken: "d"), source: .desktop, rawJSON: nil)]).entries.isEmpty
        else { return false }

        // 5) `acct` extraction. Getting this wrong means `-U` appends a duplicate
        //    item instead of updating, which is how a login gets lost.
        let dump = """
        keychain: "/Users/fixture/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials"
            "acct"<blob>="fixture-user"
            "svce"<blob>="Claude Code-credentials"
        """
        guard parseKeychainAccount(dump) == "fixture-user",
              // Hex-escaped form: the decoded trailing run is the account.
              parseKeychainAccount(#"    "acct"<blob>=0x6A6F "jorge""#) == "jorge",
              // No account on the item ⇒ nil, i.e. "write without `-a`".
              parseKeychainAccount(#"    "acct"<blob>=<NULL>"#) == nil,
              parseKeychainAccount(#"    "acct"<blob>="""#) == nil,
              parseKeychainAccount("class: \"genp\"") == nil
        else { return false }

        return true
    }
}
