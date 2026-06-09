import Foundation
import Security

/// Thin Keychain wrapper for API keys. Stored as kSecClassGenericPassword,
/// scoped per service name. No third-party dependency — pure Security.framework.
public actor KeychainStore {
    public static let shared = KeychainStore()

    private let service = "com.aryamirsepasi.Swift-Deep-Research.keys"

    public init() {}

    public func get(_ account: KeyAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    public func set(_ value: String, for account: KeyAccount) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    public func delete(_ account: KeyAccount) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
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
    case zep       = "zep.api"

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
        case .zep:       "Zep Cloud API Key (Forecast graph)"
        }
    }

    public var helpURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI:    URL(string: "https://platform.openai.com/api-keys")!
        case .gemini:    URL(string: "https://aistudio.google.com/app/apikey")!
        case .deepseek:  URL(string: "https://platform.deepseek.com/api_keys")!
        case .minimax:   URL(string: "https://www.minimax.io/platform/user-center/basic-information")!
        case .moonshot:  URL(string: "https://platform.moonshot.ai/console/api-keys")!
        case .qwen:      URL(string: "https://bailian.console.aliyun.com/?apiKey=1")!
        case .custom:    URL(string: "https://platform.openai.com/docs/api-reference")!
        case .tavily:    URL(string: "https://app.tavily.com/home")!
        case .exa:       URL(string: "https://dashboard.exa.ai/api-keys")!
        case .brave:     URL(string: "https://api.search.brave.com/app/keys")!
        case .zep:       URL(string: "https://app.getzep.com/")!
        }
    }
}
