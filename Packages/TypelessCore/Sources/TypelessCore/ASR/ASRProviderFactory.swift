import Foundation

/// Registry and factory for ASR providers
public final class ASRProviderFactory: Sendable {
    private let providers: [String: any ASRProvider]

    public init(providers: [any ASRProvider]) {
        var registry: [String: any ASRProvider] = [:]
        for provider in providers {
            registry[provider.id] = provider
        }
        self.providers = registry
    }

    /// Get a provider by its ID
    public func provider(for id: String) -> (any ASRProvider)? {
        providers[id]
    }

    /// Get all registered providers
    public var allProviders: [any ASRProvider] {
        Array(providers.values)
    }

    /// Get all available providers (API key configured, model ready, etc.)
    public var availableProviders: [any ASRProvider] {
        providers.values.filter(\.isAvailable)
    }

    /// Get providers that work offline (no network required)
    public var offlineProviders: [any ASRProvider] {
        providers.values.filter { !$0.requiresNetwork }
    }

    /// Get providers that support streaming
    public var streamingProviders: [any ASRProvider] {
        providers.values.filter(\.supportsStreaming)
    }

    /// Get providers that support a specific language
    public func providers(supporting language: String) -> [any ASRProvider] {
        providers.values.filter { $0.supportedLanguages.contains(language) }
    }

    /// Get the best available provider, preferring on-device, then streaming, then any
    public func bestAvailableProvider(
        for language: String? = nil,
        preferStreaming: Bool = true
    ) -> (any ASRProvider)? {
        let candidates: [any ASRProvider]
        if let language {
            candidates = providers(supporting: language).filter(\.isAvailable)
        } else {
            candidates = availableProviders
        }

        // Prefer on-device first
        if let onDevice = candidates.first(where: { !$0.requiresNetwork }) {
            return onDevice
        }

        // Then prefer streaming
        if preferStreaming, let streaming = candidates.first(where: \.supportsStreaming) {
            return streaming
        }

        return candidates.first
    }
}
