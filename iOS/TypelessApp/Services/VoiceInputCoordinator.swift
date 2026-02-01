import Foundation
import TypelessCore

/// Orchestrates the full voice input pipeline: Audio → ASR → LLM Correction
public actor VoiceInputCoordinator {
    private let asrFactory: ASRProviderFactory
    private let correctionPipeline: CorrectionPipeline?
    private let contextStore: ContextMemoryStore
    private let settings: AppSettings

    public init(
        asrFactory: ASRProviderFactory,
        correctionPipeline: CorrectionPipeline?,
        contextStore: ContextMemoryStore = ContextMemoryStore(),
        settings: AppSettings = AppSettings()
    ) {
        self.asrFactory = asrFactory
        self.correctionPipeline = correctionPipeline
        self.contextStore = contextStore
        self.settings = settings
    }

    /// Process audio through the full pipeline (batch mode)
    public func processAudio(_ audio: AudioChunk) async throws -> String {
        let provider = try resolveProvider()

        let transcription = try await provider.transcribe(audio: audio)
        guard !transcription.text.isEmpty else { return "" }

        let finalText = try await applyCorrection(to: transcription)
        await contextStore.addTranscription(finalText)

        return finalText
    }

    /// Start streaming voice input with an audio source
    public func startStreamingWithAudio(
        audioSource: AsyncStream<AudioChunk>,
        onPartialResult: @escaping @Sendable (String) -> Void,
        onFinalResult: @escaping @Sendable (String) -> Void,
        onAudioLevel: @escaping @Sendable (CGFloat) -> Void
    ) async throws {
        let provider = try resolveProvider(preferStreaming: true)
        let stream = provider.startStreaming()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Feed audio chunks to the ASR provider
            group.addTask {
                for await chunk in audioSource {
                    try await provider.feedAudio(chunk)
                    let level = AudioLevelCalculator.rmsLevel(from: chunk)
                    onAudioLevel(level)
                }
                _ = try? await provider.stopStreaming()
            }

            // Process ASR results
            group.addTask { [self] in
                for await result in stream {
                    if result.isFinal {
                        let finalText = try await self.applyCorrection(to: result)
                        await self.contextStore.addTranscription(finalText)
                        onFinalResult(finalText)
                    } else {
                        onPartialResult(result.text)
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    /// Start streaming without an external audio source (provider manages audio)
    public func startStreaming(
        onPartialResult: @escaping @Sendable (String) -> Void,
        onFinalResult: @escaping @Sendable (String) -> Void
    ) async throws {
        let provider = try resolveProvider(preferStreaming: true)
        let stream = provider.startStreaming()

        for await result in stream {
            if result.isFinal {
                let finalText = try await applyCorrection(to: result)
                await contextStore.addTranscription(finalText)
                onFinalResult(finalText)
            } else {
                onPartialResult(result.text)
            }
        }
    }

    // MARK: - Private

    private func resolveProvider(preferStreaming: Bool = false) throws -> any ASRProvider {
        let providerId = settings.selectedASRProvider
        guard let provider = asrFactory.provider(for: providerId)
                ?? asrFactory.bestAvailableProvider(preferStreaming: preferStreaming) else {
            throw ASRError.providerNotAvailable("No ASR provider available")
        }
        return provider
    }

    private func applyCorrection(to transcription: TranscriptionResult) async throws -> String {
        guard settings.correctionEnabled, let pipeline = correctionPipeline else {
            return transcription.text
        }

        do {
            let context = await contextStore.currentContext()
            let correctionResult = try await pipeline.process(
                transcription: transcription,
                context: context
            )
            return correctionResult.correctedText
        } catch {
            // Fallback to raw transcription if correction fails
            return transcription.text
        }
    }
}
