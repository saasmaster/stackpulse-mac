import Foundation
import Security

/// Secure storage for BYOK (bring-your-own-key) provider API keys, in
/// **StackPulse's own** macOS Keychain.
///
/// Because StackPulse creates every item here, reading it back never triggers
/// the interactive "allow access" prompt (there's no cross-app ACL to satisfy —
/// unlike reading Claude Code's Keychain item, see `KeychainProbe`). Items are
/// generic passwords under a single service, keyed by the provider id, with a
/// separate companion item for a provider's base URL (LiteLLM).
///
/// SECURITY:
///   • Keys are never logged, printed, or written anywhere but the Keychain.
///   • A key is only ever read into memory transiently for a single balance
///     request (see `ProviderBalanceClient`); it is never encoded into a
///     snapshot, a preference, or a URL.
///   • `hasKey(for:)` checks *presence only* (`kSecReturnData: false`), so the
///     launch-time "which providers are connected" scan never loads secrets.
enum APIKeyStore {
    /// Keychain service namespacing every StackPulse-owned API key.
    static let service = "ai.stackpulse.apikey"

    /// Keychain account suffix for a provider's companion base-URL item (LiteLLM
    /// stores `"litellm-base-url"`). The base URL is not a secret, but it lives in
    /// the Keychain beside the key so a single "connection" is stored in one place.
    private static func baseURLAccount(for providerID: String) -> String {
        "\(providerID)-base-url"
    }

    // MARK: API keys

    /// Stores (or replaces) a provider's API key. A blank value is ignored.
    static func save(key: String, for providerID: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setValue(trimmed, account: providerID)
    }

    /// Reads a provider's API key, or `nil` when none is stored. Does not prompt
    /// (StackPulse owns the item). **The returned value is a live secret** — hold
    /// it only for the duration of a request and never log it.
    static func read(for providerID: String) -> String? {
        getValue(account: providerID)
    }

    /// Removes a provider's API key (and its companion base URL, if any).
    static func delete(for providerID: String) {
        deleteValue(account: providerID)
        deleteValue(account: baseURLAccount(for: providerID))
    }

    /// Presence check only — never fetches the secret, so it never prompts and
    /// keeps no key in memory. Used to seed the connected-providers set on launch.
    static func hasKey(for providerID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: false,          // presence only
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Base URL (LiteLLM)

    /// Stores (or clears, when blank) a provider's base URL. Not a secret.
    static func saveBaseURL(_ url: String, for providerID: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteValue(account: baseURLAccount(for: providerID))
        } else {
            setValue(trimmed, account: baseURLAccount(for: providerID))
        }
    }

    /// Reads a provider's base URL, or `nil` when none is stored.
    static func readBaseURL(for providerID: String) -> String? {
        getValue(account: baseURLAccount(for: providerID))
    }

    // MARK: Keychain primitives

    private static func setValue(_ value: String, account: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update in place when the item exists; otherwise add it.
        let status = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            // Available whenever the Mac is unlocked (and after first unlock), so
            // background auto-refresh can read it. Never synced to iCloud Keychain.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func getValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func deleteValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
