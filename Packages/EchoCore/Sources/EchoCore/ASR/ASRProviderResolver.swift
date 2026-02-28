import Foundation

/// Result of ASR provider resolution with optional fallback information.
public struct ASRProviderResolution: Sendable {
    public let provider: any ASRProvider
    public let usedFallback: Bool
    public let fallbackMessage: String

    public init(provider: any ASRProvider, usedFallback: Bool, fallbackMessage: String) {
        self.provider = provider
        self.usedFallback = usedFallback
        self.fallbackMessage = fallbackMessage
    }
}

/// Resolves the best available ASR provider based on user settings, API call mode,
/// and available credentials. Extracted from VoiceRecordingViewModel to be reusable
/// across both the foreground recording view and BackgroundDictationService.
public struct ASRProviderResolver: Sendable {
    private let settings: AppSettings
    private let keyStore: SecureKeyStore
    private let accessToken: String
    private let backendBaseURL: String

    public init(
        settings: AppSettings,
        keyStore: SecureKeyStore,
        accessToken: String,
        backendBaseURL: String
    ) {
        self.settings = settings
        self.keyStore = keyStore
        self.accessToken = accessToken
        self.backendBaseURL = backendBaseURL
    }

    /// Convenience initializer using EchoAuthSession values.
    /// Must be called from the MainActor since EchoAuthSession is MainActor-isolated.
    @MainActor
    public init(settings: AppSettings, keyStore: SecureKeyStore, authSession: EchoAuthSession) {
        self.settings = settings
        self.keyStore = keyStore
        self.accessToken = authSession.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.backendBaseURL = authSession.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve the best available ASR provider.
    /// Returns `nil` if no provider is available (no keys configured, no backend access).
    public func resolve() -> ASRProviderResolution? {
        let selectedId = settings.selectedASRProvider
        let mode = settings.apiCallMode

        switch mode {
        case .backendProxy:
            return resolveViaBackend(selectedId: selectedId)
        case .clientDirect:
            return resolveViaClient(selectedId: selectedId)
        }
    }

    // MARK: - Backend Proxy Mode

    /// Prefer backend proxy, fall back to client-direct.
    private func resolveViaBackend(selectedId: String) -> ASRProviderResolution? {
        if let proxyProvider = cloudProxyProvider(for: selectedId) {
            return ASRProviderResolution(provider: proxyProvider, usedFallback: false, fallbackMessage: "")
        }

        if let directProvider = clientProvider(for: selectedId), directProvider.isAvailable {
            return ASRProviderResolution(
                provider: directProvider,
                usedFallback: true,
                fallbackMessage: "fallback: backend proxy unavailable, using client-direct"
            )
        }

        if selectedId != "openai_whisper" {
            if let proxyFallback = cloudProxyProvider(for: "openai_whisper") {
                return ASRProviderResolution(
                    provider: proxyFallback,
                    usedFallback: true,
                    fallbackMessage: "fallback: using backend OpenAI proxy"
                )
            }
            let whisperFallback = OpenAIWhisperProvider(keyStore: keyStore, model: settings.openAITranscriptionModel)
            if whisperFallback.isAvailable {
                return ASRProviderResolution(
                    provider: whisperFallback,
                    usedFallback: true,
                    fallbackMessage: "fallback: using client-direct OpenAI"
                )
            }
        }

        return nil
    }

    // MARK: - Client-Direct Mode

    /// Prefer local keys, fall back to backend proxy.
    private func resolveViaClient(selectedId: String) -> ASRProviderResolution? {
        if let directProvider = clientProvider(for: selectedId), directProvider.isAvailable {
            return ASRProviderResolution(provider: directProvider, usedFallback: false, fallbackMessage: "")
        }

        if let proxyProvider = cloudProxyProvider(for: selectedId) {
            return ASRProviderResolution(
                provider: proxyProvider,
                usedFallback: true,
                fallbackMessage: "fallback: client keys unavailable, using backend proxy"
            )
        }

        if selectedId != "openai_whisper" {
            let whisperFallback = OpenAIWhisperProvider(keyStore: keyStore, model: settings.openAITranscriptionModel)
            if whisperFallback.isAvailable {
                return ASRProviderResolution(
                    provider: whisperFallback,
                    usedFallback: true,
                    fallbackMessage: "fallback: selected provider unavailable, using OpenAI"
                )
            }
            if let proxyFallback = cloudProxyProvider(for: "openai_whisper") {
                return ASRProviderResolution(
                    provider: proxyFallback,
                    usedFallback: true,
                    fallbackMessage: "fallback: using backend OpenAI proxy"
                )
            }
        }

        return nil
    }

    // MARK: - Provider Construction

    private func cloudProxyProvider(for providerId: String) -> (any ASRProvider)? {
        guard !accessToken.isEmpty, !backendBaseURL.isEmpty else { return nil }

        let model: String?
        let language: String?
        switch providerId {
        case "deepgram":
            model = settings.deepgramModel
            language = deepgramLanguageHint(from: settings.defaultInputMode)
        case "openai_whisper":
            model = settings.openAITranscriptionModel
            language = settings.defaultInputMode == "pinyin" ? "zh" : nil
        case "volcano":
            model = nil
            language = settings.defaultInputMode == "pinyin" ? "zh-CN" : nil
        default:
            return nil
        }

        let provider = BackendProxyASRProvider(
            providerId: providerId,
            backendBaseURL: backendBaseURL,
            accessToken: accessToken,
            model: model,
            language: language
        )
        return provider.isAvailable ? provider : nil
    }

    private func clientProvider(for providerId: String) -> (any ASRProvider)? {
        switch providerId {
        case "volcano":
            let provider = VolcanoASRProvider(keyStore: keyStore)
            return provider.isAvailable ? provider : nil
        case "deepgram":
            let languageHint = deepgramLanguageHint(from: settings.defaultInputMode)
            let resolvedModel = settings.deepgramModel
            let provider = DeepgramASRProvider(
                keyStore: keyStore,
                model: resolvedModel,
                language: languageHint
            )
            return provider.isAvailable ? provider : nil
        default:
            let provider = OpenAIWhisperProvider(
                keyStore: keyStore,
                model: settings.openAITranscriptionModel
            )
            return provider.isAvailable ? provider : nil
        }
    }

    private func deepgramLanguageHint(from inputMode: String) -> String? {
        switch inputMode {
        case "pinyin":
            return "zh-CN"
        default:
            return nil
        }
    }
}
