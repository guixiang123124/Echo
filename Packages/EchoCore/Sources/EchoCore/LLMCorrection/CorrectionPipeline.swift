import Foundation

/// 3-stage correction pipeline inspired by 豆包输入法 and RLLM-CF framework
///
/// Stage 1: Pre-Detection - Flag low-confidence words, potential homophones
/// Stage 2: LLM Correction - Send tagged text + context + confidence to LLM
/// Stage 3: Verification - Accept high-confidence corrections only
public actor CorrectionPipeline {
    private let provider: any CorrectionProvider
    private let minConfidenceThreshold: Double
    private let correctionConfidenceThreshold: Double

    public init(
        provider: any CorrectionProvider,
        minConfidenceThreshold: Double = 0.7,
        correctionConfidenceThreshold: Double = 0.8
    ) {
        self.provider = provider
        self.minConfidenceThreshold = minConfidenceThreshold
        self.correctionConfidenceThreshold = correctionConfidenceThreshold
    }

    /// Run the full 3-stage correction pipeline
    public func process(
        transcription: TranscriptionResult,
        context: ConversationContext,
        options: CorrectionOptions = .default
    ) async throws -> CorrectionResult {
        // Stage 1: Pre-Detection
        let needsCorrection = preDetect(transcription: transcription, options: options)

        guard needsCorrection else {
            return .unchanged(transcription.text)
        }

        // Stage 2: LLM Correction
        let rawResult = try await provider.correct(
            rawText: transcription.text,
            context: context,
            confidence: transcription.wordConfidences,
            options: options
        )

        // Stage 3: Verification
        let verified = verify(result: rawResult)

        return verified
    }

    // MARK: - Stage 1: Pre-Detection

    /// Determine if the transcription needs LLM correction
    private func preDetect(transcription: TranscriptionResult, options: CorrectionOptions) -> Bool {
        guard options.isEnabled else { return false }

        // Always correct if there are low-confidence words
        if !transcription.lowConfidenceWords.isEmpty {
            return true
        }

        // If user explicitly enabled formatting, always run correction for
        // non-trivial utterances so stream-final polish has a visible effect.
        if options.enableFormatting,
           transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16 {
            return true
        }

        // Always correct Chinese text (homophones are common)
        if options.enableHomophones,
           transcription.language == .chinese || transcription.language == .mixed {
            return true
        }

        // Skip correction only when we truly have high-confidence word-level ASR.
        // Stream providers often omit word confidences, which previously forced
        // averageConfidence=1.0 and caused false "no-op polish" behavior.
        if !transcription.wordConfidences.isEmpty,
           transcription.averageConfidence > 0.95,
           transcription.language == .english {
            return false
        }

        // Default: correct
        return true
    }

    // MARK: - Stage 3: Verification

    /// Verify corrections and only keep high-confidence ones
    private func verify(result: CorrectionResult) -> CorrectionResult {
        guard result.wasModified else {
            return result
        }

        // Providers currently return corrected full text without granular diff spans.
        // In that case, trust the model output instead of reverting to original text.
        if result.corrections.isEmpty {
            return result
        }

        let verifiedCorrections = result.corrections.filter { correction in
            correction.confidence >= correctionConfidenceThreshold
        }

        // If all corrections were filtered out, return original text
        guard !verifiedCorrections.isEmpty else {
            return .unchanged(result.originalText)
        }

        // Apply only verified corrections
        var text = result.originalText
        for correction in verifiedCorrections.reversed() {
            if let range = text.range(of: correction.original) {
                text = text.replacingCharacters(in: range, with: correction.replacement)
            }
        }

        return CorrectionResult(
            originalText: result.originalText,
            correctedText: text,
            corrections: verifiedCorrections
        )
    }
}
