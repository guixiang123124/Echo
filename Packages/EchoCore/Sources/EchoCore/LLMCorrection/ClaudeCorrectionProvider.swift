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
        confidence: [WordConfidence]
    ) async throws -> CorrectionResult {
        guard let apiKey = try keyStore.retrieve(for: id) else {
            throw CorrectionError.apiKeyMissing
        }

        let prompt = buildPrompt(rawText: rawText, context: context, confidence: confidence)

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": prompt
                ]
            ],
            "system": systemPrompt
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

    private var systemPrompt: String {
        """
        You are a speech-to-text error correction assistant. Fix transcription errors, \
        especially Chinese homophone errors (同音字), punctuation, and grammar issues.

        Rules:
        1. Only fix clear errors. Do not change meaning or style.
        2. Pay special attention to Chinese homophones (的/得/地, 在/再, 做/作, etc.)
        3. Add proper punctuation if missing.
        4. Fix sentence segmentation if needed.
        5. Return ONLY the corrected text, nothing else.
        6. If the text is already correct, return it unchanged.
        """
    }

    private func buildPrompt(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence]
    ) -> String {
        var prompt = "Please correct this speech-to-text transcription:\n\n"
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
