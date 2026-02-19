import Foundation
import EchoCore

/// Resolves a CorrectionProvider from a settings ID string
enum CorrectionProviderResolver {
    /// Map the selected provider ID to a concrete CorrectionProvider instance
    /// Returns nil if the provider is not available (e.g., no API key configured)
    static func resolve(
        for providerId: String,
        keyStore: SecureKeyStore = SecureKeyStore()
    ) -> (any CorrectionProvider)? {
        let provider: any CorrectionProvider
        switch providerId {
        case "openai_gpt":
            provider = OpenAICorrectionProvider(keyStore: keyStore)
        case "claude":
            provider = ClaudeCorrectionProvider(keyStore: keyStore)
        case "doubao":
            provider = DoubaoCorrectionProvider(keyStore: keyStore)
        case "qwen":
            provider = QwenCorrectionProvider(keyStore: keyStore)
        default:
            return nil
        }
        return provider.isAvailable ? provider : nil
    }

    /// Get the first available correction provider from the configured list
    static func firstAvailable(
        keyStore: SecureKeyStore = SecureKeyStore()
    ) -> (any CorrectionProvider)? {
        let providerIds = ["openai_gpt", "claude", "doubao", "qwen"]
        for id in providerIds {
            if let provider = resolve(for: id, keyStore: keyStore) {
                return provider
            }
        }
        return nil
    }
}
