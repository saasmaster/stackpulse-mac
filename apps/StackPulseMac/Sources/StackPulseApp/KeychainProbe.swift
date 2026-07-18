import Foundation
import Security

/// macOS-specific augmentation of provider auth detection.
///
/// The portable Rust core deliberately cannot read the macOS Keychain, so it
/// only detects file-based credentials. Claude Code stores its OAuth token in the
/// Keychain, so on macOS we probe for *presence* here and merge the result into
/// the provider status. This is the platform boundary working as designed
/// (ADR-0005): the core stays portable; the Swift layer adds the native detail.
///
/// The login lives under the **unsuffixed** `Claude Code-credentials`. Do not be
/// tempted by the `Claude Code-credentials-<hash>` siblings: there are hundreds,
/// they are rewritten far more often, and they hold per-server **MCP OAuth** state
/// rather than a login — chasing them by prefix breaks live limits with a
/// `parseFailed`. The unsuffixed item's modification date only moves when a
/// *terminal* Claude Code session refreshes the token; a Desktop-only session
/// never renews it, so a lagging date means the token is going stale, which is a
/// signal to report — not to route around.
///
/// Presence detection requests attributes only, never secret data, so it does not
/// trigger the interactive "allow access" prompt. Only the opt-in live-limits read
/// asks for the secret.
/// The OAuth material for Claude Code, read only when the user has enabled live
/// limits. **SECURITY:** this value holds a live bearer token in memory. It is
/// never logged, never persisted, never encoded, and only ever handed to
/// `AnthropicUsageClient` for the single Anthropic usage request. It is a plain
/// value type held only for the duration of that request.
struct ClaudeCredentials: Sendable {
    let accessToken: String
    /// Expiry as unix **seconds** (normalized from the millisecond epoch Claude
    /// Code stores). `nil` when the source omits it.
    let expiresAtUnix: Int64?

    var isExpired: Bool {
        guard let expiresAtUnix else { return false }
        return expiresAtUnix <= Int64(Date().timeIntervalSince1970)
    }
}

enum KeychainProbe {
    /// The Keychain services holding Claude Code's **login**, in priority order.
    ///
    /// EXACT names, and deliberately so. `Claude Code-credentials-<hash>` items
    /// also exist — 234 of them on one real machine, rewritten constantly — and
    /// they are tempting because they look newer. **They are not logins.** They
    /// hold per-server MCP OAuth state (`{"mcpOAuth": {"plugin:…": {…}}}`) with no
    /// `claudeAiOauth` and no top-level `accessToken`. Matching them by prefix and
    /// taking the most recently written makes the read `parseFailed` and breaks
    /// live limits outright — verified by inspecting the real items.
    ///
    /// The login lives in the unsuffixed item. Its modification date lags (Claude
    /// Code only rewrites it when a *terminal* session refreshes the token), and
    /// that lag is a real signal — not a reason to go looking for a "fresher" item.
    private static let claudeServices = [
        "Claude Code-credentials",
        "Claude Code-local-oauth",
        "Claude Code-custom-oauth",
    ]

    static func claudeCredentialsPresent() -> Bool {
        claudeServices.contains { serviceExists($0) }
    }

    /// Presence only — `kSecReturnData: false`, so it never requests the secret and
    /// never triggers the interactive "allow access" prompt.
    private static func serviceExists(_ service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }


    // MARK: Reading the OAuth token (opt-in, live limits only)

    /// Outcome of trying to read the Claude token — lets the caller show an
    /// actionable message instead of silently displaying nothing.
    enum CredentialsResult: Sendable {
        case ok(ClaudeCredentials)
        /// No Claude login found anywhere (Keychain + file). Not worth alarming.
        case notFound
        /// The item exists but macOS denied the read (needs "Allow"/"Always
        /// Allow" on the Keychain prompt, or a prior Deny is remembered).
        case accessDenied
        /// Found + readable, but the JSON payload wasn't in a shape we understand.
        case parseFailed
        /// A login exists everywhere we look, but every token has aged out.
        ///
        /// Distinct from `notFound`: the user IS signed in, so "sign in" is the
        /// wrong advice. Reached only when neither the CLI item nor Claude
        /// Desktop's cache holds a live token.
        case expired
    }

    /// Reads the Claude Code OAuth token from the macOS Keychain, falling back to
    /// the `~/.claude/.credentials.json` file.
    ///
    /// **This actually fetches the secret** (`kSecReturnData: true`), so unlike
    /// `claudeCredentialsPresent()` it can trigger the interactive Keychain
    /// "allow access" prompt the first time (and again after each rebuild, since
    /// an ad-hoc-signed app changes identity). Call it only off the main actor
    /// and only when the user has enabled live limits. Nothing here logs or
    /// persists the token.
    static func readClaudeCredentialsResult() -> CredentialsResult {
        var pendingGrant = false
        var parseFail = false
        var expired = false

        // File first — never prompts. An expired file token is not "not found":
        // the user IS signed in, the login just needs renewal. Record that so the
        // all-expired verdict below is `.expired` ("waiting for renewal"), not
        // `.notFound` ("sign in") — the same distinction the CLI branch makes.
        if let creds = readCredentialsFile() {
            if !creds.isExpired { return .ok(creds) }
            expired = true
        }

        // Then Apple's `/usr/bin/security` tool. Granting its one-time
        // "Always Allow" is DURABLE: `security`'s code identity is stable, so the
        // grant survives StackPulse rebuilds — unlike a direct SecItemCopyMatching
        // whose grant resets on every ad-hoc re-sign. We never fall through to a
        // second (direct) read, so the user is never double-prompted.
        for service in claudeServices {
            switch readViaSecurityCLI(service: service) {
            case .data(let d):
                guard let creds = parseCredentialsJSON(d) else {
                    parseFail = true
                    continue
                }
                // An expired CLI token is not an answer — it's the state a
                // Desktop-only machine sits in permanently, because only a
                // terminal session rewrites this item. Remember it and try
                // Desktop rather than reporting "expired" as the verdict.
                if creds.isExpired { expired = true } else { return .ok(creds) }
            case .timedOut:
                pendingGrant = true // the "allow access" prompt is still unanswered
            case .missing:
                continue
            }
        }

        // Claude Desktop keeps its OWN cache current as a side effect of use. For a
        // Desktop user that is the live login and the CLI item is a fossil; asking
        // them to run `claude` in a terminal was the app compensating for reading
        // the wrong source. Consulted only after the CLI has failed to produce a
        // valid token, so a working terminal setup keeps its existing behavior.
        switch ClaudeDesktopAuthStore.load() {
        case .ok(let creds): return .ok(creds)
        case .accessDenied: return .accessDenied
        case .stale: expired = true          // Desktop will renew it on next use
        case .invalid: parseFail = true
        case .notFound: break
        }

        if pendingGrant { return .accessDenied }
        if expired { return .expired }
        if parseFail { return .parseFailed }
        return .notFound
    }

    private enum SecurityRead {
        case data(Data)
        /// Present, but the "allow access" prompt is pending (user hasn't granted).
        case timedOut
        /// `security` exited without producing the secret (item not found, etc.).
        case missing
    }

    /// Reads the item's secret by invoking `/usr/bin/security find-generic-password
    /// -s <service> -w`. A generous but bounded wait lets the user click
    /// "Always Allow" on the one-time prompt during a fetch, while still never
    /// hanging indefinitely. The token flows only through the pipe into memory —
    /// it is never logged, printed, or written to disk.
    private static func readViaSecurityCLI(service: String) -> SecurityRead {
        // A 12-second deadline: generous enough that a user clicking "Always Allow"
        // on the one-time prompt still succeeds, but the read never hangs — a
        // pending prompt is reported as `.timedOut` (→ access denied) rather than
        // parking forever. The bounded-read subtlety lives in `BoundedProcess`.
        guard let outcome = BoundedProcess.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-w"],
            timeout: 12
        ) else { return .missing }
        if outcome.timedOut { return .timedOut }
        guard let text = outcome.trimmedText else { return .missing }
        return .data(Data(text.utf8))
    }

    /// Convenience: just the credentials, or `nil`.
    static func readClaudeCredentials() -> ClaudeCredentials? {
        if case .ok(let creds) = readClaudeCredentialsResult() { return creds }
        return nil
    }

    /// File fallback: `~/.claude/.credentials.json`, same JSON shape as the
    /// Keychain blob (flat or nested under `claudeAiOauth`).
    private static func readCredentialsFile() -> ClaudeCredentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseCredentialsJSON(data)
    }

    /// Parses the credentials JSON. Handles both a flat object
    /// (`{"accessToken":…,"expiresAt":…}`) and one nested under a
    /// `claudeAiOauth` key, plus snake_case aliases for resilience. `expiresAt`
    /// is normalized from millis→seconds when it looks like a millisecond epoch.
    ///
    /// `internal` (not `private`) so it is reachable from the headless parser
    /// self-test; it still never logs the token.
    static func parseCredentialsJSON(_ data: Data) -> ClaudeCredentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Prefer the nested `claudeAiOauth` object when present, else the root.
        let obj = (root["claudeAiOauth"] as? [String: Any]) ?? root

        guard
            let token = (obj["accessToken"] as? String) ?? (obj["access_token"] as? String),
            !token.isEmpty
        else { return nil }

        let rawExpiry = numeric(obj["expiresAt"]) ?? numeric(obj["expires_at"])
        let expiresAtUnix = rawExpiry.map { raw -> Int64 in
            // > ~year 33658 in seconds ⇒ it's really a millisecond epoch.
            raw > 1_000_000_000_000 ? Int64(raw / 1000.0) : Int64(raw)
        }
        return ClaudeCredentials(accessToken: token, expiresAtUnix: expiresAtUnix)
    }

    /// Coerces a JSON scalar (NSNumber or numeric String) to `Double`.
    private static func numeric(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
