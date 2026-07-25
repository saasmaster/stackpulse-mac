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
/// trigger the interactive "allow access" prompt.
///
/// **Presence is all this type does.** It once also read the token, classified the
/// failure modes, and remembered which source answered — all of which
/// ``ClaudeAuthStore`` now owns, including the refresh and write-back it grew when
/// the credential chain was hardened. The copy here was left behind, diverging and
/// unreferenced, which is worse than absent: a second implementation of a Keychain
/// read is a coin flip for whoever greps for one next.

/// The OAuth material for Claude Code. **SECURITY:** this value holds a live bearer
/// token in memory. It is never logged, never persisted, never encoded, and is held
/// only for the duration of the request that needs it.
///
/// Declared here for historical reasons; its only remaining producer is
/// ``ClaudeDesktopAuthStore``.
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

}
