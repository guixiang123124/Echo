import Foundation

/// LLM correction provider using OpenAI GPT-4o API
public final class OpenAICorrectionProvider: CorrectionProvider, @unchecked Sendable {
    public let id = "openai_gpt"
    public let displayName = "OpenAI GPT-4o"
    public let requiresNetwork = true

    private let keyStore: SecureKeyStore
    private let apiKeyOverride: String?
    private let apiEndpoint = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o"

    public init(keyStore: SecureKeyStore = SecureKeyStore(), apiKey: String? = nil) {
        self.keyStore = keyStore
        self.apiKeyOverride = apiKey
    }

    public var isAvailable: Bool {
        if let apiKeyOverride, !apiKeyOverride.isEmpty {
            return true
        }
        // Prefer the dedicated Auto Edit key, but allow reusing the Whisper key
        // so users don't have to enter the same OpenAI API key twice.
        return keyStore.hasKey(for: id) || keyStore.hasKey(for: "openai_whisper")
    }

    public func correct(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence],
        options: CorrectionOptions
    ) async throws -> CorrectionResult {
        let apiKey = try (apiKeyOverride
            ?? keyStore.retrieve(for: id)
            ?? keyStore.retrieve(for: "openai_whisper"))

        guard let apiKey, !apiKey.isEmpty else {
            throw CorrectionError.apiKeyMissing
        }

        let prompt = buildPrompt(rawText: rawText, context: context, confidence: confidence, options: options)

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt(options: options)
                ],
                [
                    "role": "user",
                    "content": prompt
                ]
            ],
            "temperature": 0.1,
            "max_tokens": 1024
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        You are a speech-to-text error correction assistant. Your job is to fix transcription errors while preserving meaning and style.

        Rules:
        1. Do not change factual meaning.
        2. Return ONLY the corrected text, nothing else.
        3. If the text is already correct, return it unchanged.
        4. Never output prompt metadata labels or reference blocks (for example: Recent context, User dictionary terms, Low confidence words, REFERENCE_CONTEXT_DO_NOT_OUTPUT).
        """

        if options.enableHomophones {
            prompt += "\n5. Pay special attention to Chinese homophones (的/得/地, 在/再, 做/作, etc.)."
        } else {
            prompt += "\n5. Do NOT change words based on homophones."
        }

        if options.enablePunctuation {
            prompt += "\n6. Add or fix punctuation where clearly missing or wrong."
        } else {
            prompt += "\n6. Do NOT add or change punctuation."
        }

        if options.enableFormatting {
            prompt += "\n7. Improve readability with natural sentence segmentation and light formatting."
            prompt += "\n8. Keep meaning unchanged, but you may split run-on text into clear sentence boundaries."
        } else {
            prompt += "\n7. Do NOT change formatting or sentence segmentation."
        }

        if options.enableRemoveFillerWords {
            prompt += "\n9. Remove obvious filler words and disfluencies (um/uh/you know/那个/就是) when they do not add meaning."
        }

        if options.enableRemoveRepetitions {
            prompt += "\n10. Remove accidental repeated words or repeated short phrases."
        }

        switch options.rewriteIntensity {
        case .off:
            prompt += "\n11. Keep original sentence structure as much as possible."
        case .light:
            prompt += "\n11. Allow light rewrite for clarity; keep original tone and sentence order when possible."
        case .medium:
            prompt += "\n11. Allow moderate rewrite to improve clarity and flow, while preserving intent and key terms."
        case .strong:
            prompt += "\n11. You may strongly rewrite for clarity and structure, but preserve intent and core facts."
        }

        if options.enableTranslation {
            switch options.translationTargetLanguage {
            case .keepSource:
                prompt += "\n12. Keep source language."
            case .english:
                prompt += "\n12. Output final text in English."
            case .chineseSimplified:
                prompt += "\n12. Output final text in Simplified Chinese."
            }
        } else {
            prompt += "\n12. Keep source language and do not translate."
        }

        switch options.structuredOutputStyle {
        case .off:
            prompt += "\n13. Keep natural prose structure unless other enabled fixes require small adjustments."
        case .conciseParagraphs:
            prompt += "\n13. Restructure the final output into concise paragraphs with clear sentence boundaries."
        case .bulletList:
            prompt += "\n13. Restructure the final output into a short bullet list in the same language."
        case .actionItems:
            prompt += "\n13. Restructure into clear action items using concise bullet points."
        }

        return prompt
    }

    private func buildPrompt(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence],
        options: CorrectionOptions
    ) -> String {
        var prompt = """
        Please correct the transcript enclosed in <TRANSCRIPT>.
        Return only the corrected transcript content (no labels/explanations).
        Allowed fixes: \(options.summary).

        """
        if options.enableFormatting {
            prompt += "When formatting is enabled, actively improve punctuation and sentence boundaries for readability.\n\n"
        }
        if options.rewriteIntensity != .off {
            prompt += "Rewrite intensity: \(options.rewriteIntensity.rawValue).\n"
        }
        if options.enableTranslation {
            prompt += "Translate target: \(options.translationTargetLanguage.displayName).\n"
        }
        if options.structuredOutputStyle != .off {
            prompt += "Structured output: \(options.structuredOutputStyle.displayName).\n"
        }
        prompt += "\n<TRANSCRIPT>\n\(rawText)\n</TRANSCRIPT>\n"

        let contextInfo = context.compactForPrompt(
            focusText: rawText,
            maxRecent: 4,
            maxChars: 900,
            maxUserTerms: 64
        )
        if !contextInfo.isEmpty {
            prompt += """
            \n<REFERENCE_CONTEXT_DO_NOT_OUTPUT>
            \(contextInfo)
            </REFERENCE_CONTEXT_DO_NOT_OUTPUT>
            \n
            """
        }

        let lowConfidence = confidence.filter(\.isLowConfidence)
        if !lowConfidence.isEmpty {
            let words = lowConfidence.map { "\($0.word) (\(String(format: "%.0f%%", $0.confidence * 100)))" }
            prompt += """
            \n<LOW_CONFIDENCE_HINTS_DO_NOT_OUTPUT>
            \(words.joined(separator: ", "))
            </LOW_CONFIDENCE_HINTS_DO_NOT_OUTPUT>
            \n
            """
        }

        return prompt
    }

    private func parseResponse(data: Data, originalText: String) throws -> CorrectionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let correctedText = message["content"] as? String else {
            throw CorrectionError.correctionFailed("Failed to parse API response")
        }

        let trimmed = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)

        return CorrectionResult(
            originalText: originalText,
            correctedText: trimmed
        )
    }
}
