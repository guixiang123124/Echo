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
        confidence: [WordConfidence],
        options: CorrectionOptions
    ) async throws -> CorrectionResult {
        guard let apiKey = try keyStore.retrieve(for: id) else {
            throw CorrectionError.apiKeyMissing
        }

        let prompt = buildPrompt(rawText: rawText, context: context, confidence: confidence, options: options)

        let requestBody: [String: Any] = [
            "model": "doubao-pro-32k",
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
        你是一个语音转文字纠错助手。你的任务是在保持原意和风格的前提下修正识别错误。

        规则：
        1. 只修正明确的错误，不要改变原文的意思或风格。
        2. 只返回修正后的文本，不要返回任何其他内容。
        3. 如果文本已经正确，原样返回。
        """

        if options.enableHomophones {
            prompt += "\n4. 特别注意中文同音字纠正（的/得/地、在/再、做/作等）。"
        } else {
            prompt += "\n4. 不要根据同音字修改用词。"
        }

        if options.enablePunctuation {
            prompt += "\n5. 补充或修正明显缺失/错误的标点符号。"
        } else {
            prompt += "\n5. 不要添加或修改标点。"
        }

        if options.enableFormatting {
            prompt += "\n6. 必要时优化句子分割或格式，但仅在明显需要时进行。"
        } else {
            prompt += "\n6. 不要改变格式或句子分割。"
        }

        if options.enableRemoveFillerWords {
            prompt += "\n7. 删除无意义语气词与口头禅（如 嗯、啊、那个、就是）。"
        }

        if options.enableRemoveRepetitions {
            prompt += "\n8. 删除明显的重复词或重复短语。"
        }

        switch options.rewriteIntensity {
        case .off:
            prompt += "\n9. 尽量保持原句结构。"
        case .light:
            prompt += "\n9. 允许轻度改写，提升清晰度但保持原语气。"
        case .medium:
            prompt += "\n9. 允许中度改写，提升条理和可读性。"
        case .strong:
            prompt += "\n9. 允许较强改写，但必须保留原意与关键事实。"
        }

        if options.enableTranslation {
            switch options.translationTargetLanguage {
            case .keepSource:
                prompt += "\n10. 保持原语言输出。"
            case .english:
                prompt += "\n10. 最终文本输出为英文。"
            case .chineseSimplified:
                prompt += "\n10. 最终文本输出为简体中文。"
            }
        } else {
            prompt += "\n10. 不要翻译，保持原语言。"
        }

        switch options.structuredOutputStyle {
        case .off:
            prompt += "\n11. 保持自然段落结构，除非其他规则需要调整。"
        case .conciseParagraphs:
            prompt += "\n11. 将结果整理为简洁段落。"
        case .bulletList:
            prompt += "\n11. 将结果整理为要点列表（项目符号）。"
        case .actionItems:
            prompt += "\n11. 将结果整理为行动项列表（项目符号）。"
        }

        return prompt
    }

    private func buildPrompt(
        rawText: String,
        context: ConversationContext,
        confidence: [WordConfidence],
        options: CorrectionOptions
    ) -> String {
        let allowedTypes = [
            options.enableHomophones ? "同音字" : nil,
            options.enablePunctuation ? "标点" : nil,
            options.enableFormatting ? "格式/分句" : nil
        ].compactMap { $0 }

        var prompt = "请修正以下语音识别文本。\n"
        prompt += "允许的修正类型：\(allowedTypes.isEmpty ? "无" : allowedTypes.joined(separator: "、"))。\n"
        prompt += "详细开关：\(options.summary)。\n\n"
        if options.rewriteIntensity != .off {
            prompt += "改写强度：\(options.rewriteIntensity.displayName)。\n"
        }
        if options.structuredOutputStyle != .off {
            prompt += "结构化输出：\(options.structuredOutputStyle.displayName)。\n"
        }
        prompt += "文本：\(rawText)\n"

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
