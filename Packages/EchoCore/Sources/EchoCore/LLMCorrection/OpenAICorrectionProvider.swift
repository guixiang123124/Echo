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
        return keyStore.hasKey(for: id)
    }

    public func correct(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence]
    ) async throws -> CorrectionResult {
        guard let apiKey = try (apiKeyOverride ?? keyStore.retrieve(for: id)) else {
            throw CorrectionError.apiKeyMissing
        }

        let prompt = buildPrompt(rawText: rawText, context: context, confidence: confidence)

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
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

    private var systemPrompt: String {
        """
        You are a speech-to-text error correction assistant. Your job is to fix transcription errors, \
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
