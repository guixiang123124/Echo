import Foundation

/// LLM correction provider using Anthropic Claude API
public final class ClaudeCorrectionProvider: CorrectionProvider, @unchecked Sendable {
    public let id = "claude"
    public let displayName = "Claude"
    public let requiresNetwork = true

    private let keyStore: SecureKeyStore
    private let apiEndpoint = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-20250514"

    public init(keyStore: SecureKeyStore = SecureKeyStore()) {
        self.keyStore = keyStore
    }

    public var isAvailable: Bool {
        keyStore.hasKey(for: id)
    }

    public func correct(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence],
        options: CorrectionOptions
    ) async throws -> CorrectionResult {
        guard let apiKey = try keyStore.retrieve(for: id) else {
            throw CorrectionError.apiKeyMissing
        }

        let prompt = buildPrompt(rawText: rawText, context: context, confidence: confidence, options: options)

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ],
            "system": systemPrompt(options: options)
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CorrectionError.apiError("HTTP \(statusCode)")
        }

        return try parseResponse(data: data, originalText: rawText)
    }

    // MARK: - Private

    private func systemPrompt(options: CorrectionOptions) -> String {
        var prompt = """
        You are a speech-to-text error correction assistant. Fix transcription errors while preserving meaning and style.

        Rules:
        1. Only fix clear errors. Do not change meaning or style.
        2. Return ONLY the corrected text, nothing else.
        3. If the text is already correct, return it unchanged.
        """

        if options.enableHomophones {
            prompt += "\n4. Pay special attention to Chinese homophones (的/得/地, 在/再, 做/作, etc.)."
        } else {
            prompt += "\n4. Do NOT change words based on homophones."
        }

        if options.enablePunctuation {
            prompt += "\n5. Add or fix punctuation where clearly missing or wrong."
        } else {
            prompt += "\n5. Do NOT add or change punctuation."
        }

        if options.enableFormatting {
            prompt += "\n6. Improve sentence segmentation or formatting only when it is clearly needed."
        } else {
            prompt += "\n6. Do NOT change formatting or sentence segmentation."
        }

        if options.enableRemoveFillerWords {
            prompt += "\n7. Remove obvious filler words and disfluencies when they do not add meaning."
        }

        if options.enableRemoveRepetitions {
            prompt += "\n8. Remove accidental repeated words or repeated short phrases."
        }

        switch options.rewriteIntensity {
        case .off:
            prompt += "\n9. Keep original sentence structure as much as possible."
        case .light:
            prompt += "\n9. Allow light rewrite for clarity while keeping tone."
        case .medium:
            prompt += "\n9. Allow moderate rewrite for clarity and flow."
        case .strong:
            prompt += "\n9. Strong rewrite allowed, but preserve intent and key facts."
        }

        if options.enableTranslation {
            switch options.translationTargetLanguage {
            case .keepSource:
                prompt += "\n10. Keep source language."
            case .english:
                prompt += "\n10. Output final text in English."
            case .chineseSimplified:
                prompt += "\n10. Output final text in Simplified Chinese."
            }
        } else {
            prompt += "\n10. Keep source language and do not translate."
        }

        switch options.structuredOutputStyle {
        case .off:
            prompt += "\n11. Keep natural prose structure unless other enabled fixes require adjustments."
        case .conciseParagraphs:
            prompt += "\n11. Restructure output into concise paragraphs."
        case .bulletList:
            prompt += "\n11. Restructure output into a compact bullet list."
        case .actionItems:
            prompt += "\n11. Restructure output into clear action-item bullets."
        }

        return prompt
    }

    private func buildPrompt(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence],
        options: CorrectionOptions
    ) -> String {
        var prompt = "Please correct this speech-to-text transcription.\n"
        prompt += "Allowed fixes: \(options.summary).\n\n"
        if options.rewriteIntensity != .off {
            prompt += "Rewrite intensity: \(options.rewriteIntensity.displayName).\n"
        }
        if options.structuredOutputStyle != .off {
            prompt += "Structured output: \(options.structuredOutputStyle.displayName).\n"
        }
        prompt += "Text: \(rawText)\n"

        let contextInfo = context.compactForPrompt(
            focusText: rawText,
            maxRecent: 3,
            maxChars: 800,
            maxUserTerms: 48
        )
        if !contextInfo.isEmpty {
            prompt += "\n\(contextInfo)\n"
        }

        let lowConfidence = confidence.filter(\.isLowConfidence)
        if !lowConfidence.isEmpty {
            let words = lowConfidence.map { "\($0.word) (\(String(format: "%.0f%%", $0.confidence * 100)))" }
            prompt += "\nLow confidence words: \(words.joined(separator: ", "))\n"
        }

        return prompt
    }

    private func parseResponse(data: Data, originalText: String) throws -> CorrectionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw CorrectionError.correctionFailed("Failed to parse API response")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return CorrectionResult(
            originalText: originalText,
            correctedText: trimmed
        )
    }
}
