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
/// **The service name is not a constant.** Claude Code writes per-workspace items
/// (`Claude Code-credentials-<hash>`), so this matches by PREFIX and takes the
/// most recently written. This doc used to name `Claude Code-credentials` as *the*
/// service; that item still exists as a stale leftover, and reading it fed a
/// days-old token to the usage API — the fetch failed silently for 70 hours while
/// a cached "82%" kept rendering as if live.
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
    /// Prefixes of the Keychain service names Claude Code is known to use.
    ///
    /// PREFIXES, not exact names, and that distinction is the whole point. Claude
    /// Code moved to per-workspace items — `Claude Code-credentials-dc50ab7e` and
    /// hundreds of siblings — while leaving the unsuffixed `Claude Code-credentials`
    /// behind as a stale leftover. Matching the exact legacy name kept finding that
    /// leftover, reading a token last written days earlier, and failing the fetch
    /// forever. Observed live: the legacy item sat 3 days old while the real one had
    /// been rewritten minutes before.
    private static let claudeServicePrefixes = [
        "Claude Code-credentials",
        "Claude Code-local-oauth",
        "Claude Code-custom-oauth",
    ]

    static func claudeCredentialsPresent() -> Bool {
        !claudeServiceNames().isEmpty
    }

    /// Every Claude credential service on this machine, **most recently written
    /// first** — so the freshest token is tried first and a stale sibling can never
    /// shadow it.
    ///
    /// Keychain has no prefix query, so this enumerates generic-password
    /// **attributes** and filters. `kSecReturnData: false` — no secret is requested
    /// here, which is also why it never prompts. Items that aren't ours are matched
    /// against the prefixes and dropped immediately; nothing about them is read,
    /// retained, or logged.
    private static func claudeServiceNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,     // metadata only; never the secret
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }

        return items
            .compactMap { item -> (String, Date)? in
                guard let service = item[kSecAttrService as String] as? String,
                      claudeServicePrefixes.contains(where: { service.hasPrefix($0) })
                else { return nil }
                // No modification date ⇒ sort it oldest rather than guess it's new.
                let modified = item[kSecAttrModificationDate as String] as? Date ?? .distantPast
                return (service, modified)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
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
        // File first — never prompts.
        if let creds = readCredentialsFile() { return .ok(creds) }

        // Then Apple's `/usr/bin/security` tool. Granting its one-time
        // "Always Allow" is DURABLE: `security`'s code identity is stable, so the
        // grant survives StackPulse rebuilds — unlike a direct SecItemCopyMatching
        // whose grant resets on every ad-hoc re-sign. We never fall through to a
        // second (direct) read, so the user is never double-prompted.
        var pendingGrant = false
        var parseFail = false
        // Newest first, and only a few: this machine has 234 distinct Claude
        // credential services. Each read spawns `security` and can sit on an
        // "allow access" prompt, so walking them all would take minutes and could
        // prompt over and over. The freshest item is the live login by
        // construction; the extras only cover it being unreadable or foreign.
        for service in claudeServiceNames().prefix(maxCredentialReadAttempts) {
            switch readViaSecurityCLI(service: service) {
            case .data(let d):
                if let creds = parseCredentialsJSON(d) { return .ok(creds) }
                parseFail = true
            case .timedOut:
                pendingGrant = true // the "allow access" prompt is still unanswered
            case .missing:
                continue
            }
        }
        if pendingGrant { return .accessDenied }
        if parseFail { return .parseFailed }
        return .notFound
    }

    /// How many credential items to try, newest first. See the loop above: this is
    /// a bound on prompts and process spawns, not on correctness — item 1 is the
    /// live login unless it is unreadable.
    private static let maxCredentialReadAttempts = 3

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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return .missing }

        let deadline = Date().addingTimeInterval(12)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning {
            proc.terminate()
            return .timedOut
        }
        guard proc.terminationStatus == 0 else { return .missing }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return .missing }
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
