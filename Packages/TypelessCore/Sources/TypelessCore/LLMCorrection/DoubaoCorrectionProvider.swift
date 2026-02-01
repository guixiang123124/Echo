import Foundation

/// LLM correction provider using ByteDance Doubao (豆包) API via Volcano Engine
public final class DoubaoCorrectionProvider: CorrectionProvider, @unchecked Sendable {
    public let id = "doubao"
    public let displayName = "Doubao (豆包)"
    public let requiresNetwork = true

    private let keyStore: SecureKeyStore
    private let apiEndpoint = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"

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
            "model": "doubao-pro-32k",
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
        你是一个语音转文字纠错助手。你的任务是修正语音识别中的错误，\
        特别是中文同音字错误、标点符号和语法问题。

        规则：
        1. 只修正明确的错误，不要改变原文的意思或风格。
        2. 特别注意同音字纠正（的/得/地、在/再、做/作等）
        3. 补充遗漏的标点符号。
        4. 修正句子分割问题。
        5. 只返回修正后的文本，不要返回任何其他内容。
        6. 如果文本已经正确，原样返回。
        """
    }

    private func buildPrompt(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence]
    ) -> String {
        var prompt = "请修正以下语音识别文本：\n\n"
        prompt += "文本：\(rawText)\n"

        let contextInfo = context.formatForPrompt()
        if !contextInfo.isEmpty {
            prompt += "\n\(contextInfo)\n"
        }

        let lowConfidence = confidence.filter(\.isLowConfidence)
        if !lowConfidence.isEmpty {
            let words = lowConfidence.map { "\($0.word)（\(String(format: "%.0f%%", $0.confidence * 100))）" }
            prompt += "\n低置信度词语：\(words.joined(separator: "、"))\n"
        }

        return prompt
    }

    private func parseResponse(data: Data, originalText: String) throws -> CorrectionResult {
        // Doubao API follows OpenAI-compatible format
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
