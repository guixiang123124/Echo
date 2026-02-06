import Foundation

/// LLM correction provider using Alibaba Cloud Qwen (OpenAI-compatible) API
public final class QwenCorrectionProvider: CorrectionProvider, @unchecked Sendable {
    public let id = "qwen"
    public let displayName = "Alibaba Qwen"
    public let requiresNetwork = true

    private let keyStore: SecureKeyStore
    private let apiKeyOverride: String?
    private let apiEndpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    private let model = "qwen-plus"

    public init(keyStore: SecureKeyStore = SecureKeyStore(), apiKey: String? = nil) {
        self.keyStore = keyStore
        self.apiKeyOverride = apiKey
    }

    public var isAvailable: Bool {
        if let apiKeyOverride, !apiKeyOverride.isEmpty {
            return true
        }
        return keyStore.hasKey(for: id)
    }

    public func correct(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence],
        options: CorrectionOptions
    ) async throws -> CorrectionResult {
        guard let apiKey = try (apiKeyOverride ?? keyStore.retrieve(for: id)) else {
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
        prompt += "Text: \(rawText)\n"

        let contextInfo = context.formatForPrompt()
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
