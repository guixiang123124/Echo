import Foundation

/// Resolves a correction provider from a settings provider identifier.
///
/// Exposed from the shared package so both the main app and keyboard background
/// dictation service can share the same resolution logic.
public enum CorrectionProviderResolver {
    /// Map the selected provider ID to a concrete `CorrectionProvider` instance.
    /// Returns `nil` if the provider is not available (for example, API key missing).
    public static func resolve(
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

    /// Return the first available correction provider from the default preference list.
    public static func firstAvailable(
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
