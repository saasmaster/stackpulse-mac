import CommonCrypto
import Foundation
import Security

/// Reads Claude **Desktop**'s OAuth token cache — the login that is actually
/// current for a Desktop user.
///
/// ## Why this exists
///
/// StackPulse read only Claude **Code**'s CLI credential. That item is rewritten
/// only when a *terminal* session refreshes it, so on a Desktop-only machine it
/// ages out and simply stays expired: observed here frozen at 2026-07-13 while
/// Desktop's own cache had been rewritten the same afternoon. Live limits were
/// dead for 70 hours with nothing to do about it but "run `claude` in Terminal" —
/// a chore the app was imposing because it was reading the wrong source.
///
/// Desktop keeps its own cache fresh as a side effect of normal use. Reading it is
/// the difference between a feature that works and one that needs a manual ritual
/// every ~12 hours.
///
/// ## What it reads, and what it refuses to touch
///
/// Claude Desktop is an Electron app: `config.json` holds the token cache
/// encrypted with a key kept in the Keychain under `Claude Safe Storage`. This
/// derives that key the same way Electron's `safeStorage` does and decrypts the
/// cache **read-only**.
///
/// **The refresh token is never decoded.** Anthropic rotates refresh tokens, so
/// using one here would invalidate Claude Desktop's own copy and could sign the
/// user out of the app they're working in. This borrows a currently-valid access
/// token and otherwise waits for Desktop to renew it — the same rule StackPulse
/// already applies to the CLI credential, now pointed at a source that stays
/// fresh. StackPulse still never writes, refreshes, or rotates anything.
///
/// **SECURITY:** the decrypted token is a live bearer credential. It is returned
/// as a value, handed to `AnthropicUsageClient` for the single Anthropic usage
/// request, and dropped. It is never logged, persisted, or printed. Nothing in
/// this file writes to disk or to the Keychain.
///
/// Behavior (cache layout, key derivation, candidate ranking) deliberately matches
/// **OpenUsage** (`robinebers/openusage`, MIT), which solved this first;
/// re-implemented rather than copied, per ADR-0001.
enum ClaudeDesktopAuthStore {
    /// Where Electron stores the safeStorage key. Claude Desktop's own item.
    private static let safeStorageService = "Claude Safe Storage"
    private static let safeStorageAccount = "Claude Key"

    private static let configRelativePath = "Library/Application Support/Claude/config.json"
    /// Both layouts exist in the wild; newer builds moved the DB under `Network/`.
    private static let cookieRelativePaths = [
        "Library/Application Support/Claude/Cookies",
        "Library/Application Support/Claude/Network/Cookies",
    ]
    private static let cacheV2Key = "oauth:tokenCacheV2"
    private static let cacheV1Key = "oauth:tokenCache"
    private static let apiHost = "https://api.anthropic.com"
    /// The scope the usage endpoint needs. An entry without it can't answer us.
    private static let usageScope = "user:profile"
    private static let inferenceScope = "user:inference"
    /// The OAuth client Claude's production login mints full-scope tokens under.
    /// Desktop's cache can hold several entries per org — partial-scope leftovers
    /// from older logins included — and this is how Desktop itself picks.
    private static let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Don't hand out a token that's about to die mid-request.
    private static let expirySafetyMarginMs: Double = 2 * 60 * 1000

    /// Why we have no Desktop token — each case is something the UI can act on,
    /// rather than one undifferentiated "no".
    enum Result {
        case ok(ClaudeCredentials)
        /// Claude Desktop isn't installed, or has never logged in.
        case notFound
        /// The item exists but macOS denied the read.
        case accessDenied
        /// Found and readable, but every entry has already expired. Desktop will
        /// renew it on next use — this is a wait, not a fault.
        case stale
        /// Decrypted but not in a shape we understand (a layout change).
        case invalid
    }

    // MARK: Entry point

    /// The current Desktop access token, or why there isn't one. Read-only.
    static func load(now: Date = Date()) -> Result {
        guard let config = readConfig() else { return .notFound }
        guard config[cacheV2Key] is String || config[cacheV1Key] is String else { return .notFound }

        let key: Data
        switch safeStorageKey() {
        case .key(let k): key = k
        case .denied: return .accessDenied
        case .absent: return .notFound
        }

        guard let org = activeOrganization(key: key) else {
            // Without the active org we cannot tell which cached login is the one
            // in use, and picking the wrong one reports somebody else's usage.
            return .invalid
        }

        let v2 = decodeCache(config[cacheV2Key], key: key)
        let v1 = decodeCache(config[cacheV1Key], key: key)
        return select(v2: v2, v1: v1, organization: org, now: now)
    }

    /// One line for `--selftest-live` describing WHICH state Desktop is in, so a
    /// live-limits failure can be diagnosed without guessing. States only — never
    /// the token, never the key, never a decrypted payload.
    static func describeForDiagnostics(now: Date = Date()) -> String {
        guard hasCredentialMaterial() else { return "no Desktop login material" }
        switch load(now: now) {
        case .ok(let creds):
            let ttl = creds.expiresAtUnix.map {
                " (expires in \(max(0, $0 - Int64(now.timeIntervalSince1970)) / 60)m)"
            } ?? ""
            return "ok — usable token read from Claude Desktop\(ttl)"
        case .notFound: return "material present but no matching entry"
        case .accessDenied: return "Keychain denied the Claude Safe Storage read"
        case .stale: return "every Desktop entry has expired"
        case .invalid: return "decrypted but not in a shape we understand"
        }
    }

    /// Cheap, prompt-free evidence that a Desktop login exists — safe to call for
    /// detection because it never asks the Keychain for the secret.
    static func hasCredentialMaterial() -> Bool {
        guard let config = readConfig(),
              config[cacheV2Key] is String || config[cacheV1Key] is String
        else { return false }
        return cookieRelativePaths.contains { FileManager.default.fileExists(atPath: home($0)) }
    }

    // MARK: Selection

    /// One decrypted cache entry, with what we need to rank it.
    private struct Candidate {
        let credentials: ClaudeCredentials
        let clientID: String
        let scopes: [String]
        let expiresAtMs: Double

        /// Mirrors Desktop's own resolution rather than raw expiry: the production
        /// client with full scopes first, then any full-scope entry over a bare
        /// `user:profile` leftover, then scope richness, with expiry only as the
        /// final tiebreak. A stale wrong-tier token with a longer TTL must not
        /// outrank the login actually in use.
        var rank: (Int, Int, Int, Double) {
            let full = scopes.contains(usageScope) && scopes.contains(inferenceScope)
            let production = clientID == productionClientID
            return (production && full ? 1 : 0, full ? 1 : 0, scopes.count, expiresAtMs)
        }
    }

    /// v2 wins outright; v1 is consulted only for keys v2 doesn't have, so a stale
    /// v1 leftover can never shadow the current entry.
    static func select(v2: [String: Any]?, v1: [String: Any]?,
                       organization: String, now: Date) -> Result {
        let two = candidates(in: v2, organization: organization, now: now)
        if let best = two.available.max(by: { $0.rank < $1.rank }) { return .ok(best.credentials) }

        let v2Keys = Set(v2?.keys ?? [:].keys)
        let one = candidates(in: v1?.filter { !v2Keys.contains($0.key) },
                             organization: organization, now: now)
        if let best = one.available.max(by: { $0.rank < $1.rank }) { return .ok(best.credentials) }

        if two.sawStale || one.sawStale { return .stale }
        if two.sawInvalid || one.sawInvalid { return .invalid }
        return .notFound
    }

    private static func candidates(in cache: [String: Any]?, organization: String,
                                   now: Date) -> (available: [Candidate], sawStale: Bool, sawInvalid: Bool) {
        guard let cache else { return ([], false, false) }
        var available: [Candidate] = []
        var sawStale = false
        var sawInvalid = false

        for (rawKey, rawEntry) in cache {
            guard let key = parseCacheKey(rawKey),
                  key.organization == organization,
                  key.apiHost == apiHost,
                  key.scopes.contains(usageScope)
            else { continue }
            guard !(rawEntry is NSNull) else { continue }
            guard let entry = rawEntry as? [String: Any],
                  let token = (entry["token"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
                  let expiresAtMs = number(entry["expiresAt"]), expiresAtMs.isFinite
            else {
                sawInvalid = true
                continue
            }
            // Margin, not just `> now`: a token that dies during the request is a
            // failure we'd report as an auth problem.
            guard expiresAtMs > now.timeIntervalSince1970 * 1000 + expirySafetyMarginMs else {
                sawStale = true
                continue
            }
            available.append(Candidate(
                credentials: ClaudeCredentials(accessToken: token,
                                               expiresAtUnix: Int64(expiresAtMs / 1000)),
                clientID: key.clientID,
                scopes: key.scopes,
                expiresAtMs: expiresAtMs
            ))
        }
        return (available, sawStale, sawInvalid)
    }

    struct CacheKey: Equatable {
        let clientID: String
        let organization: String
        let apiHost: String
        let scopes: [String]
    }

    /// Cache keys read `<clientUUID>:<orgUUID>:<apiHost>:<space-separated scopes>`.
    /// Both ids must be real UUIDs — that's what separates a key from a coincidence.
    static func parseCacheKey(_ value: String) -> CacheKey? {
        let marker = ":\(apiHost):"
        guard let markerRange = value.range(of: marker) else { return nil }
        let prefix = value[..<markerRange.lowerBound]
        guard let firstColon = prefix.firstIndex(of: ":") else { return nil }
        let clientID = String(prefix[..<firstColon])
        let organization = String(prefix[prefix.index(after: firstColon)...]).lowercased()
        guard UUID(uuidString: clientID) != nil, UUID(uuidString: organization) != nil else { return nil }
        let scopes = value[markerRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return CacheKey(clientID: clientID, organization: organization, apiHost: apiHost, scopes: scopes)
    }

    // MARK: Crypto (Electron safeStorage)

    /// PBKDF2-HMAC-SHA1, salt `saltysalt`, 1003 iterations, 16-byte AES-128 key.
    /// These constants are Chromium's `OSCrypt` scheme, which Electron inherits —
    /// they are not tunable, they are what the ciphertext was produced with.
    static func deriveKey(password: String) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let count = key.count
        let salt = Data("saltysalt".utf8)
        let pw = Data(password.utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            pw.withUnsafeBytes { pwBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBytes.bindMemory(to: Int8.self).baseAddress, pw.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, count
                    )
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// AES-128-CBC, IV of 16 spaces, `v10` version prefix — again Chromium's
    /// scheme, not a choice.
    static func decrypt(_ blob: Data, key: Data) -> Data? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128 else { return nil }
        let payload = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let capacity = out.count
        var written = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, payload.count,
                                outBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    /// The outcome of asking for Desktop's safeStorage key. "Denied" and "absent"
    /// are different answers to the user, so they are different values here.
    private enum KeyLookup {
        case key(Data)
        case denied
        case absent
    }

    private static func safeStorageKey() -> KeyLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: safeStorageService,
            kSecAttrAccount as String: safeStorageAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data,
                  let password = String(data: data, encoding: .utf8), !password.isEmpty,
                  let key = deriveKey(password: password)
            else { return .absent }
            return .key(key)
        case errSecItemNotFound:
            return .absent
        default:
            // Denied, cancelled, or an error we can't classify. All of them mean
            // "we could not read it", which is actionable — unlike "not there".
            return .denied
        }
    }

    // MARK: Sources

    private static func home(_ relative: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative).path
    }

    private static func readConfig() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: home(configRelativePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    private static func decodeCache(_ stored: Any?, key: Data) -> [String: Any]? {
        guard let base64 = stored as? String,
              let blob = Data(base64Encoded: base64),
              let plaintext = decrypt(blob, key: key),
              let root = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        else { return nil }
        return root
    }

    /// The org Desktop is currently signed into, from its own cookie store.
    ///
    /// Needed because the cache is keyed per organization and a user can have
    /// several: without it we'd be guessing which login is live, and reporting
    /// another org's limits is worse than reporting none.
    private static func activeOrganization(key: Data) -> String? {
        for relative in cookieRelativePaths {
            let path = home(relative)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            for host in [".claude.ai", "claude.ai"] {
                // Newer Chromium encrypts `value` and leaves `encrypted_value`; older
                // builds do the reverse. Ask for both and decide from what came back.
                let sql = """
                SELECT CASE WHEN length(value) > 0 THEN 'plain:' || hex(CAST(value AS BLOB)) \
                ELSE 'encrypted:' || hex(encrypted_value) END FROM cookies \
                WHERE name = 'lastActiveOrg' AND host_key = '\(host)' \
                ORDER BY last_update_utc DESC LIMIT 1;
                """
                guard let encoded = sqliteQuery(path: path, sql: sql),
                      let sep = encoded.firstIndex(of: ":") else { continue }
                let mode = String(encoded[..<sep])
                guard let stored = Data(hexString: String(encoded[encoded.index(after: sep)...]))
                else { continue }

                let value: Data?
                if mode == "plain" {
                    value = stored
                } else {
                    // A cookie encrypted with the SAME safeStorage key. Chromium
                    // prefixes 32 bytes of SHA256(domain) on newer versions; the
                    // value is a UUID either way, so pull it out by shape rather
                    // than by guessing the header length.
                    value = decrypt(stored, key: key)
                }
                guard let value, let text = String(data: value, encoding: .utf8) ?? String(data: value, encoding: .isoLatin1)
                else { continue }
                if let uuid = firstUUID(in: text) { return uuid.lowercased() }
            }
        }
        return nil
    }

    /// The first UUID in `text`, or nil. Used because an encrypted cookie may carry
    /// a binary prefix — the UUID is the part we can positively identify.
    static func firstUUID(in text: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text)
        else { return nil }
        return String(text[r])
    }

    /// One value out of a SQLite DB via Apple's `/usr/bin/sqlite3`.
    ///
    /// A subprocess rather than a linked SQLite: the portable Rust core must stay
    /// free of C dependencies (a Windows-cross CI gate enforces that), and this is
    /// macOS-only glue. Read-only (`file:...?mode=ro`) so Desktop's own DB can
    /// never be touched, and bounded so a locked DB can't hang a refresh.
    private static func sqliteQuery(path: String, sql: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = ["-readonly", path, sql]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        // Drain while it runs: waiting for exit first deadlocks past the pipe
        // buffer (the same trap that made a Keychain read look like a denial).
        var data = Data()
        let handle = out.fileHandleForReading
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { data.append(handle.availableData) }
        if proc.isRunning { proc.terminate(); return nil }
        data.append(handle.readDataToEndOfFile())
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
}

extension Data {
    /// Bytes from a hex string, or nil if it isn't clean hex.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }
}
