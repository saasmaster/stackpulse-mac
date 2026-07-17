import Foundation
import Testing
@testable import StackPulseApp

/// Reading Claude Desktop's token cache.
///
/// This is the fix for the failure that started it all: StackPulse read only the
/// CLI credential, which a Desktop-only machine never renews, so live limits sat
/// dead for 70 hours behind a stale "82%". Desktop's own cache was current the
/// whole time.
///
/// The selection rules are the delicate part — a cache holds several logins, and
/// picking the wrong one reports another organization's usage as yours.
@Suite("Claude Desktop auth")
struct ClaudeDesktopAuthTests {
    let org = "11111111-1111-1111-1111-111111111111"
    let otherOrg = "22222222-2222-2222-2222-222222222222"
    let production = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    let otherClient = "33333333-3333-3333-3333-333333333333"

    func key(client: String, org: String, scopes: String) -> String {
        "\(client):\(org):https://api.anthropic.com:\(scopes)"
    }
    func entry(_ token: String, expiresInHours: Double, now: Date) -> [String: Any] {
        ["token": token, "expiresAt": (now.timeIntervalSince1970 + expiresInHours * 3600) * 1000]
    }
    func token(_ r: ClaudeDesktopAuthStore.Result) -> String? {
        if case .ok(let c) = r { return c.accessToken }
        return nil
    }

    // MARK: Cache keys

    @Test("a cache key yields its client, org, host and scopes")
    func parseKey() throws {
        let k = try #require(ClaudeDesktopAuthStore.parseCacheKey(
            key(client: production, org: org, scopes: "user:profile user:inference")))
        #expect(k.clientID == production)
        #expect(k.organization == org)
        #expect(k.apiHost == "https://api.anthropic.com")
        #expect(k.scopes == ["user:profile", "user:inference"])
    }

    /// Both ids must be real UUIDs — that is what separates a key from a
    /// coincidentally colon-shaped string.
    @Test("a key without real UUIDs is not a key")
    func rejectsNonUUIDKeys() {
        #expect(ClaudeDesktopAuthStore.parseCacheKey("notauuid:\(org):https://api.anthropic.com:user:profile") == nil)
        #expect(ClaudeDesktopAuthStore.parseCacheKey("\(production):notanorg:https://api.anthropic.com:user:profile") == nil)
        #expect(ClaudeDesktopAuthStore.parseCacheKey("garbage") == nil)
        #expect(ClaudeDesktopAuthStore.parseCacheKey("") == nil)
    }

    // MARK: Selection

    /// THE rule that protects correctness: a token minted for another organization
    /// must never be used. Reporting someone else's usage as yours is worse than
    /// reporting none.
    @Test("a token for another organization is never selected")
    func neverCrossesOrganizations() {
        let now = Date()
        let cache: [String: Any] = [
            key(client: production, org: otherOrg, scopes: "user:profile user:inference"):
                entry("OTHER-ORG", expiresInHours: 10, now: now)
        ]
        let r = ClaudeDesktopAuthStore.select(v2: cache, v1: nil, organization: org, now: now)
        #expect(token(r) == nil)
        if case .notFound = r {} else { Issue.record("expected notFound, got \(r)") }
    }

    /// Desktop's own resolution order — not raw expiry. A longer-lived leftover
    /// from a partial-scope login must not outrank the login actually in use.
    @Test("the production full-scope login wins over a longer-lived leftover")
    func productionFullScopeWins() {
        let now = Date()
        let cache: [String: Any] = [
            key(client: otherClient, org: org, scopes: "user:profile"):
                entry("LEFTOVER", expiresInHours: 100, now: now),
            key(client: production, org: org, scopes: "user:profile user:inference"):
                entry("CURRENT", expiresInHours: 1, now: now),
        ]
        #expect(token(ClaudeDesktopAuthStore.select(v2: cache, v1: nil, organization: org, now: now)) == "CURRENT")
    }

    /// v1 is a legacy cache. It may only answer for keys v2 doesn't have, or a
    /// stale leftover could shadow the current login.
    @Test("v2 wins outright; v1 only fills gaps")
    func v2Wins() {
        let now = Date()
        let k = key(client: production, org: org, scopes: "user:profile user:inference")
        let v2: [String: Any] = [k: entry("FROM-V2", expiresInHours: 2, now: now)]
        let v1: [String: Any] = [k: entry("FROM-V1", expiresInHours: 99, now: now)]
        #expect(token(ClaudeDesktopAuthStore.select(v2: v2, v1: v1, organization: org, now: now)) == "FROM-V2")

        // ...but a key only v1 has is still usable.
        #expect(token(ClaudeDesktopAuthStore.select(v2: [:], v1: v1, organization: org, now: now)) == "FROM-V1")
    }

    /// An entry without the usage scope cannot answer the usage endpoint, so it is
    /// not a candidate at all.
    @Test("an entry lacking the usage scope is skipped")
    func requiresUsageScope() {
        let now = Date()
        let cache: [String: Any] = [
            key(client: production, org: org, scopes: "user:inference"):
                entry("NO-PROFILE-SCOPE", expiresInHours: 10, now: now)
        ]
        #expect(token(ClaudeDesktopAuthStore.select(v2: cache, v1: nil, organization: org, now: now)) == nil)
    }

    /// Expired ⇒ `.stale`, which is a WAIT (Desktop renews on next use), not a
    /// fault — and must never be reported as "no login".
    @Test("an expired entry reports stale, not notFound")
    func expiredIsStale() {
        let now = Date()
        let cache: [String: Any] = [
            key(client: production, org: org, scopes: "user:profile user:inference"):
                entry("DEAD", expiresInHours: -1, now: now)
        ]
        let r = ClaudeDesktopAuthStore.select(v2: cache, v1: nil, organization: org, now: now)
        if case .stale = r {} else { Issue.record("expected stale, got \(r)") }
    }

    /// A token expiring inside the safety margin would die mid-request and surface
    /// as an auth error — treat it as stale rather than hand it out.
    @Test("a token inside the expiry safety margin is not handed out")
    func safetyMargin() {
        let now = Date()
        let cache: [String: Any] = [
            key(client: production, org: org, scopes: "user:profile user:inference"):
                entry("ABOUT-TO-DIE", expiresInHours: 0.01, now: now) // ~36s
        ]
        let r = ClaudeDesktopAuthStore.select(v2: cache, v1: nil, organization: org, now: now)
        if case .stale = r {} else { Issue.record("expected stale, got \(r)") }
    }

    /// A malformed entry is `.invalid` — a shape change we should report, not a
    /// silent skip that looks like "you're not signed in".
    @Test("a malformed entry reports invalid")
    func malformedIsInvalid() {
        let now = Date()
        let cache: [String: Any] = [
            key(client: production, org: org, scopes: "user:profile user:inference"):
                ["token": "", "expiresAt": 0]
        ]
        let r = ClaudeDesktopAuthStore.select(v2: cache, v1: nil, organization: org, now: now)
        if case .invalid = r {} else { Issue.record("expected invalid, got \(r)") }
    }

    @Test("an empty cache is notFound")
    func emptyIsNotFound() {
        let r = ClaudeDesktopAuthStore.select(v2: nil, v1: nil, organization: org, now: Date())
        if case .notFound = r {} else { Issue.record("expected notFound, got \(r)") }
    }

    // MARK: Crypto

    /// Chromium's `OSCrypt` scheme, which Electron inherits. These constants are
    /// not tunable — they are what the ciphertext was produced with, so a "tidy-up"
    /// that changes them silently breaks every read.
    @Test("key derivation is deterministic and 16 bytes")
    func deriveKeyShape() throws {
        let a = try #require(ClaudeDesktopAuthStore.deriveKey(password: "hunter2"))
        let b = try #require(ClaudeDesktopAuthStore.deriveKey(password: "hunter2"))
        #expect(a.count == 16)
        #expect(a == b)
        #expect(a != ClaudeDesktopAuthStore.deriveKey(password: "hunter3"))
    }

    /// Anything without the `v10` prefix is not this scheme; decrypting it would
    /// produce plausible garbage rather than an error.
    @Test("ciphertext without the v10 prefix is refused")
    func requiresV10() throws {
        let key = try #require(ClaudeDesktopAuthStore.deriveKey(password: "k"))
        #expect(ClaudeDesktopAuthStore.decrypt(Data("nope".utf8), key: key) == nil)
        #expect(ClaudeDesktopAuthStore.decrypt(Data(), key: key) == nil)
        #expect(ClaudeDesktopAuthStore.decrypt(Data("v10".utf8), key: key) == nil)
    }

    @Test("a wrong-sized key is refused rather than used")
    func requiresAES128Key() {
        #expect(ClaudeDesktopAuthStore.decrypt(Data("v10ciphertexthere".utf8),
                                               key: Data(repeating: 0, count: 8)) == nil)
    }

    // MARK: Org extraction

    /// The cookie may carry a binary prefix, so the UUID is pulled out by shape.
    @Test("the active org UUID is found inside a noisy cookie value")
    func findsUUID() {
        #expect(ClaudeDesktopAuthStore.firstUUID(in: "\u{01}\u{02}junk11111111-1111-1111-1111-111111111111trailing")
                == "11111111-1111-1111-1111-111111111111")
        #expect(ClaudeDesktopAuthStore.firstUUID(in: "no uuid here") == nil)
        #expect(ClaudeDesktopAuthStore.firstUUID(in: "") == nil)
    }
}
