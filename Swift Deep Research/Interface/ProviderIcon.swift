import SwiftUI

/// Brand icon for an LLM provider, backed by the bundled asset catalogue
/// (`provider-<name>` imagesets generated from the AI brand SVGs). Colour logos
/// render as-is; monochrome logos are template assets that tint with the current
/// foreground style. Providers without a brand asset fall back to an SF Symbol.
struct ProviderIcon: View {
    let provider: ProviderRegistry.ProviderID
    var size: CGFloat = 16

    var body: some View {
        if let asset = Self.assetName(for: provider) {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: Self.fallbackSymbol(for: provider))
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
        }
    }

    /// Asset-catalogue image name, or `nil` to use the SF Symbol fallback.
    static func assetName(for provider: ProviderRegistry.ProviderID) -> String? {
        switch provider {
        case .anthropic:        "provider-anthropic"
        case .openai:           "provider-openai"
        case .gemini:           "provider-gemini"
        case .deepseek:         "provider-deepseek"
        case .minimax:          "provider-minimax"
        case .kimi:             "provider-kimi"
        case .qwen:             "provider-qwen"
        case .lmstudio:         "provider-lmstudio"
        case .ollama:           "provider-ollama"
        case .mlx, .foundationmodels: "provider-apple"
        case .custom:           nil
        }
    }

    static func fallbackSymbol(for provider: ProviderRegistry.ProviderID) -> String {
        switch provider {
        case .custom: "link"
        default:      "cpu"
        }
    }
}
