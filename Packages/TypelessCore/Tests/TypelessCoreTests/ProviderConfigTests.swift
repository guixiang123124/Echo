import Testing
@testable import TypelessCore

@Suite("ProviderConfig Tests")
struct ProviderConfigTests {

    @Test("Creates provider config with defaults")
    func createConfig() {
        let config = ProviderConfig(
            id: "test",
            displayName: "Test Provider",
            type: .asr
        )

        #expect(config.id == "test")
        #expect(config.displayName == "Test Provider")
        #expect(config.type == .asr)
        #expect(!config.isEnabled)
        #expect(config.requiresApiKey)
    }

    @Test("withEnabled returns new config (immutable)")
    func withEnabled() {
        let original = ProviderConfig(
            id: "test",
            displayName: "Test",
            type: .asr,
            isEnabled: false
        )

        let updated = original.withEnabled(true)

        #expect(!original.isEnabled) // Original unchanged
        #expect(updated.isEnabled)
        #expect(updated.id == original.id) // Other fields preserved
    }

    @Test("Available ASR providers list is populated")
    func availableASR() {
        #expect(!AvailableProviders.asrProviders.isEmpty)

        let appleSpeech = AvailableProviders.asrProviders.first {
            $0.id == "apple_speech"
        }
        #expect(appleSpeech != nil)
        #expect(appleSpeech?.requiresApiKey == false)
        #expect(appleSpeech?.isEnabled == true) // Default enabled
    }

    @Test("Available correction providers list is populated")
    func availableCorrection() {
        #expect(!AvailableProviders.correctionProviders.isEmpty)

        let openai = AvailableProviders.correctionProviders.first {
            $0.id == "openai_gpt"
        }
        #expect(openai != nil)
        #expect(openai?.requiresApiKey == true)
    }
}

@Suite("ASRProviderFactory Tests")
struct ASRProviderFactoryTests {

    @Test("Registers and retrieves providers")
    func registerAndRetrieve() {
        let provider = MockASRProvider(id: "test")
        let factory = ASRProviderFactory(providers: [provider])

        let retrieved = factory.provider(for: "test")
        #expect(retrieved?.id == "test")
    }

    @Test("Returns nil for unknown provider")
    func unknownProvider() {
        let factory = ASRProviderFactory(providers: [])

        #expect(factory.provider(for: "nonexistent") == nil)
    }

    @Test("Filters available providers")
    func availableProviders() {
        let available = MockASRProvider(id: "a", available: true)
        let unavailable = MockASRProvider(id: "b", available: false)
        let factory = ASRProviderFactory(providers: [available, unavailable])

        #expect(factory.availableProviders.count == 1)
    }

    @Test("Filters offline providers")
    func offlineProviders() {
        let offline = MockASRProvider(id: "a", requiresNetwork: false)
        let online = MockASRProvider(id: "b", requiresNetwork: true)
        let factory = ASRProviderFactory(providers: [offline, online])

        #expect(factory.offlineProviders.count == 1)
    }
}

// MARK: - Mock

struct MockASRProvider: ASRProvider {
    let id: String
    var displayName: String { "Mock \(id)" }
    var supportsStreaming: Bool = false
    var requiresNetwork: Bool = false
    var supportedLanguages: Set<String> = ["en", "zh-Hans"]
    var isAvailable: Bool = true

    init(id: String, requiresNetwork: Bool = false, available: Bool = true) {
        self.id = id
        self.requiresNetwork = requiresNetwork
        self.isAvailable = available
    }

    func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        TranscriptionResult(text: "mock", language: .english, isFinal: true)
    }

    func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { $0.finish() }
    }

    func feedAudio(_ chunk: AudioChunk) async throws {}

    func stopStreaming() async throws -> TranscriptionResult? { nil }
}
