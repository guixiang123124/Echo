import Foundation

/// ASR provider using OpenAI Whisper API (batch mode, $0.006/minute)
public final class OpenAIWhisperProvider: ASRProvider, @unchecked Sendable {
    public let id = "openai_whisper"
    public let displayName = "OpenAI Whisper"
    public let supportsStreaming = false
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private let keyStore: SecureKeyStore
    private let language: String?
    private let apiKeyOverride: String?
    private let apiEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    private let model: String

    public init(
        keyStore: SecureKeyStore = SecureKeyStore(),
        language: String? = nil,
        apiKey: String? = nil,
        model: String = "whisper-1"
    ) {
        self.keyStore = keyStore
        self.language = language
        self.apiKeyOverride = apiKey
        self.model = Self.normalizeModel(model)
    }

    public var isAvailable: Bool {
        if resolveApiKey() != nil {
            return true
        }
        return false
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard let apiKey = resolveApiKey() else {
            throw ASRError.apiKeyMissing
        }

        guard !audio.isEmpty else {
            throw ASRError.noAudioData
        }

        var lastError: Error?
        for candidate in orderedModelCandidates {
            do {
                let result = try await transcribe(audio: audio, apiKey: apiKey, model: candidate)
                return result
            } catch {
                let message = (error as? ASRError).map { "\($0)" } ?? error.localizedDescription
                if candidate != "whisper-1", shouldRetryOpenAIModel(errorMessage: message) {
                    lastError = error
                    continue
                }
                throw error
            }
        }

        throw lastError ?? ASRError.transcriptionFailed("OpenAI transcribe failed")
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { $0.finish() } // Whisper API doesn't support streaming
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        throw ASRError.streamingNotSupported
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        nil
    }

    // MARK: - Private

    private var orderedModelCandidates: [String] {
        let primary = model
        if primary == "whisper-1" {
            return [primary]
        }
        return [primary, "whisper-1"]
    }

    private func transcribe(audio: AudioChunk, apiKey: String, model modelCandidate: String) async throws -> TranscriptionResult {
        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 45

        var body = Data()

        // Add file field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(AudioFormatHelper.wavData(for: audio))
        body.append("\r\n")

        // Add model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(modelCandidate)\r\n")

        // Add response format field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        let responseFormat = responseFormatForModel(modelCandidate)
        body.append("\(responseFormat)\r\n")

        // Add language field if specified
        if let language {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.append("\(language)\r\n")
        }

        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASRError.apiError("Invalid OpenAI response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = httpResponse.statusCode
            let details = parseOpenAIErrorMessage(from: data)
            let compact = details.isEmpty ? "No extra details" : details
            throw ASRError.apiError("OpenAI HTTP \(statusCode): \(compact)")
        }

        return try parseResponse(data: data, model: modelCandidate)
    }

    private func parseResponse(data: Data, model: String) throws -> TranscriptionResult {
        if model != "whisper-1", let responseText = String(data: data, encoding: .utf8) {
            let plainText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && isPlainTextResponse(responseText) {
                return TranscriptionResult(text: plainText, language: .unknown, isFinal: true)
            }
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let segmentText = parseSegmentsText(from: json["segments"])
            let wordText = parseWordsText(from: json["words"])
            let textCandidates = [json["text"] as? String, segmentText, wordText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }

            guard let text = textCandidates.first else {
                throw ASRError.transcriptionFailed("Failed to parse Whisper API response")
            }

            let language: RecognizedLanguage
            if let lang = json["language"] as? String {
                switch lang {
                case "chinese", "zh": language = .chinese
                case "english", "en": language = .english
                default: language = .unknown
                }
            } else {
                language = .unknown
            }

            // Parse word-level data if available
            var wordConfidences: [WordConfidence] = []
            if let segments = json["segments"] as? [[String: Any]] {
                for segment in segments {
                    if let words = segment["words"] as? [[String: Any]] {
                        for wordData in words {
                            if let word = wordData["word"] as? String {
                                let confidence = (wordData["probability"] as? Double) ?? 1.0
                                wordConfidences.append(
                                    WordConfidence(word: word, confidence: confidence)
                                )
                            }
                        }
                    }
                }
            }

            return TranscriptionResult(
                text: text,
                language: language,
                isFinal: true,
                wordConfidences: wordConfidences
            )
        }

        guard let rawText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else {
            throw ASRError.transcriptionFailed("Failed to parse Whisper API response")
        }
        return TranscriptionResult(text: rawText, language: .unknown, isFinal: true)
    }

    private func parseSegmentsText(from value: Any?) -> String? {
        guard let segments = value as? [[String: Any]], !segments.isEmpty else {
            return nil
        }

        let segmentTexts = segments.compactMap { segment -> String? in
            if let text = segment["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }

            if let words = segment["words"] as? [[String: Any]], !words.isEmpty {
                let parts = words.compactMap { wordData -> String? in
                    guard let word = wordData["word"] as? String else { return nil }
                    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if !parts.isEmpty {
                    return parts.joined(separator: " ")
                }
            }

            return nil
        }

        let merged = segmentTexts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return merged.isEmpty ? nil : merged
    }

    private func parseWordsText(from value: Any?) -> String? {
        guard let words = value as? [[String: Any]], !words.isEmpty else {
            return nil
        }

        let parts = words.compactMap { item -> String? in
            guard let word = item["word"] as? String else { return nil }
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let merged = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return merged.isEmpty ? nil : merged
    }

    private func responseFormatForModel(_ model: String) -> String {
        if model == "whisper-1" {
            return "verbose_json"
        }
        return "text"
    }

    private func shouldRetryOpenAIModel(errorMessage: String) -> Bool {
        let lower = errorMessage.lowercased()
        let hints = [
            "unsupported model",
            "does not exist",
            "invalid model",
            "model `",
            "response_format",
            "unsupported response format",
            "unexpected",
            "invalid_request_error",
            "bad request",
            "max_tokens",
            "internal server error"
        ]

        guard !lower.contains("empty transcription") else {
            return true
        }
        return hints.contains(where: { lower.contains($0) })
    }

    private func parseOpenAIErrorMessage(from data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8),
              !raw.isEmpty else {
            return ""
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let code = (error["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let type = (error["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let details = [message, type, code].filter { !$0.isEmpty }
            if !details.isEmpty {
                return details.joined(separator: " | ")
            }
        }

        return raw
    }

    private func isPlainTextResponse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }
        if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
            return true
        }
        return false
    }

    private static func normalizeModel(_ model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return "whisper-1"
        }

        switch normalized.lowercased() {
        case "gpt-4o", "gpt4o", "gpt4o-transcribe", "gpt-4o transcribe":
            return "gpt-4o-transcribe"
        case "gpt-4o-mini", "gpt4o-mini", "gpt4omini", "gpt-4o-mini-transcribe":
            return "gpt-4o-mini-transcribe"
        case "whisper", "whisper1":
            return "whisper-1"
        default:
            return normalized
        }
    }

    private func resolveApiKey() -> String? {
        let override = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return override
        }
        if let key = retrieveFirstAvailableKey(
            from: [id, "openai_gpt", "openai", "openai_api", "openai_key", "openai_api_key"]
        ) {
            return key
        }
        return nil
    }

    private func retrieveFirstAvailableKey(from keyIds: [String]) -> String? {
        for keyId in keyIds {
            if let key = (try? keyStore.retrieve(for: keyId))?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
        }
        return nil
    }

}

// MARK: - Data Extensions

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
