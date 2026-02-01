import Testing
@testable import TypelessCore

/// Mock correction provider for testing
struct MockCorrectionProvider: CorrectionProvider, @unchecked Sendable {
    let id = "mock"
    let displayName = "Mock"
    let requiresNetwork = false
    let isAvailable = true

    var correctedText: String

    func correct(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence]
    ) async throws -> CorrectionResult {
        CorrectionResult(
            originalText: rawText,
            correctedText: correctedText,
            corrections: [
                Correction(
                    original: rawText,
                    replacement: correctedText,
                    type: .homophone,
                    confidence: 0.95
                )
            ]
        )
    }
}

@Suite("CorrectionPipeline Tests")
struct CorrectionPipelineTests {

    @Test("High confidence English text skips correction")
    func skipHighConfidenceEnglish() async throws {
        let provider = MockCorrectionProvider(correctedText: "changed")
        let pipeline = CorrectionPipeline(provider: provider)

        let transcription = TranscriptionResult(
            text: "Hello world",
            language: .english,
            isFinal: true,
            wordConfidences: [
                WordConfidence(word: "Hello", confidence: 0.99),
                WordConfidence(word: "world", confidence: 0.98)
            ]
        )

        let result = try await pipeline.process(
            transcription: transcription,
            context: .empty
        )

        #expect(result.correctedText == "Hello world")
        #expect(!result.wasModified)
    }

    @Test("Chinese text always goes through correction")
    func chineseAlwaysCorrected() async throws {
        let provider = MockCorrectionProvider(correctedText: "再见")
        let pipeline = CorrectionPipeline(provider: provider)

        let transcription = TranscriptionResult(
            text: "在见",
            language: .chinese,
            isFinal: true,
            wordConfidences: [
                WordConfidence(word: "在", confidence: 0.95),
                WordConfidence(word: "见", confidence: 0.95)
            ]
        )

        let result = try await pipeline.process(
            transcription: transcription,
            context: .empty
        )

        #expect(result.wasModified)
    }

    @Test("Low confidence words trigger correction")
    func lowConfidenceTriggers() async throws {
        let provider = MockCorrectionProvider(correctedText: "corrected")
        let pipeline = CorrectionPipeline(provider: provider)

        let transcription = TranscriptionResult(
            text: "test",
            language: .english,
            isFinal: true,
            wordConfidences: [
                WordConfidence(word: "test", confidence: 0.4)
            ]
        )

        let result = try await pipeline.process(
            transcription: transcription,
            context: .empty
        )

        #expect(result.wasModified)
    }
}
