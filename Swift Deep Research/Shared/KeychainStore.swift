import Foundation
import Security
import OSLog

/// Thin Keychain wrapper for API keys. Stored as kSecClassGenericPassword,
/// scoped per service name. No third-party dependency — pure Security.framework.
public actor KeychainStore {
    public static let shared = KeychainStore()

    // Derive the Keychain service from the running app's bundle id so it tracks
    // this fork ("com.linroger.Swift-Deep-Research") instead of the upstream
    // fork's hardcoded id. Falls back to the literal bundle id in the unlikely
    // event Bundle.main reports no identifier (e.g. some test hosts).
    private let service = (Bundle.main.bundleIdentifier ?? "com.linroger.Swift-Deep-Research") + ".keys"

    // The service name used by the upstream fork. Items written under this name
    // by an older build are migrated to `service` on first access (see
    // migrateLegacyItemsIfNeeded). Kept as a literal so the migration keeps
    // working even after the bundle id changes.
    private let legacyService = "com.aryamirsepasi.Swift-Deep-Research.keys"

    // UserDefaults flag guarding the one-time legacy migration, so it runs at
    // most once per install regardless of how many accounts are accessed.
    private let migrationFlagKey = "KeychainStore.legacyMigrationCompleted.v1"

    public init() {}

    public func get(_ account: KeyAccount) -> String? {
        migrateLegacyItemsIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            // Pin synchronizable=false on the lookup too, so the query matches the
            // device-only items written by set() deterministically (a query that
            // omits this attribute matches either, but keeping it explicit and
            // consistent avoids ambiguity if a synced item ever co-exists).
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            // errSecItemNotFound is the normal "no key configured" case. Anything
            // else (e.g. errSecInteractionNotAllowed when the Mac is locked) is a
            // real failure that callers otherwise can't distinguish from "missing
            // key" — log the status code (never the secret) so it's diagnosable.
            if status != errSecItemNotFound {
                Log.provider.error("Keychain read failed for \(account.rawValue, privacy: .public): OSStatus \(status)")
            }
            return nil
        }
        guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    public func set(_ value: String, for account: KeyAccount) -> Bool {
        migrateLegacyItemsIfNeeded()
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            // Pin device-only (non-syncable) so the lookup matches the items we add
            // below and so an existing synced item can never be silently updated.
            kSecAttrSynchronizable as String: false
        ]
        // These attributes are applied on BOTH the SecItemUpdate path (re-pinning
        // accessibility on every write, so an item created before this hardening
        // gets upgraded the next time it's set) and the SecItemAdd path (via the
        // merge below). AfterFirstUnlockThisDeviceOnly keeps paid-API keys
        // bound to this Mac: never iCloud-synced and not restorable to another
        // device via encrypted backup / Migration Assistant.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.provider.error("Keychain add failed for \(account.rawValue, privacy: .public): OSStatus \(addStatus)")
            }
            return addStatus == errSecSuccess
        }
        if status != errSecSuccess {
            Log.provider.error("Keychain update failed for \(account.rawValue, privacy: .public): OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: KeyAccount) -> Bool {
        migrateLegacyItemsIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            // Match the device-only items written by set() (see above).
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.provider.error("Keychain delete failed for \(account.rawValue, privacy: .public): OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    // MARK: - Legacy migration

    /// One-time copy of keys written under the upstream fork's service name into
    /// this fork's service. Runs at most once per install (guarded by a
    /// UserDefaults flag) and never throws — any per-account failure is logged
    /// and skipped so it can't block get/set/delete. The legacy items are left
    /// in place (a non-destructive copy) so a downgrade to an older build still
    /// finds its keys. If `service` already equals `legacyService` (no rename
    /// occurred) the migration is a no-op and just sets the flag.
    private func migrateLegacyItemsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        // Mark complete up front so a transient failure can't make this rescan
        // (and re-log) on every subsequent access; the copy below is best-effort.
        defaults.set(true, forKey: migrationFlagKey)

        guard service != legacyService else { return }

        for account in KeyAccount.allCases {
            // Skip if a value already exists under the new service — never
            // clobber a key the user has already configured on this build.
            let existsQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account.rawValue,
                kSecAttrSynchronizable as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if SecItemCopyMatching(existsQuery as CFDictionary, nil) == errSecSuccess {
                continue
            }

            // Read the legacy item, matching the same device-only attributes
            // older builds wrote with.
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account.rawValue,
                kSecAttrSynchronizable as String: false,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let readStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &item)
            guard readStatus == errSecSuccess,
                  let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                continue
            }

            // Write into the new service preserving the device-only,
            // non-syncable, AfterFirstUnlockThisDeviceOnly attributes.
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account.rawValue,
                kSecAttrSynchronizable as String: false,
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
                Log.provider.error("Keychain legacy migration failed for \(account.rawValue, privacy: .public): OSStatus \(addStatus)")
            }
        }
    }
}

public enum KeyAccount: String, Sendable, CaseIterable {
    case anthropic = "anthropic.api"
    case openAI    = "openai.api"
    case gemini    = "gemini.api"
    case deepseek  = "deepseek.api"
    case minimax   = "minimax.api"
    case moonshot  = "moonshot.api"
    case qwen      = "qwen.api"
    case custom    = "custom.api"
    case tavily    = "tavily.search"
    case exa       = "exa.search"
    case brave     = "brave.search"

    public var humanLabel: String {
        switch self {
        case .anthropic: "Anthropic API Key"
        case .openAI:    "OpenAI API Key"
        case .gemini:    "Google Gemini API Key"
        case .deepseek:  "DeepSeek API Key"
        case .minimax:   "MiniMax API Key"
        case .moonshot:  "Moonshot / Kimi API Key"
        case .qwen:      "Qwen (Alibaba Cloud) API Key"
        case .custom:    "Custom Endpoint API Key"
        case .tavily:    "Tavily Search API Key"
        case .exa:       "Exa Search API Key"
        case .brave:     "Brave Search API Key"
        }
    }

    public var helpURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI:    URL(string: "https://platform.openai.com/api-keys")!
        case .gemini:    URL(string: "https://aistudio.google.com/app/apikey")!
        case .deepseek:  URL(string: "https://platform.deepseek.com/api_keys")!
        case .minimax:   URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")!
        case .moonshot:  URL(string: "https://platform.moonshot.ai/console/api-keys")!
        case .qwen:      URL(string: "https://bailian.console.aliyun.com/?apiKey=1")!
        case .custom:    URL(string: "https://platform.openai.com/docs/api-reference")!
        case .tavily:    URL(string: "https://app.tavily.com/home")!
        case .exa:       URL(string: "https://dashboard.exa.ai/api-keys")!
        case .brave:     URL(string: "https://api.search.brave.com/app/keys")!
        }
    }
}
