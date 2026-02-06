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
        self.model = model
    }

    public var isAvailable: Bool {
        if let apiKeyOverride, !apiKeyOverride.isEmpty {
            return true
        }
        return keyStore.hasKey(for: id)
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard let apiKey = try (apiKeyOverride ?? keyStore.retrieve(for: id)) else {
            throw ASRError.apiKeyMissing
        }

        guard !audio.isEmpty else {
            throw ASRError.noAudioData
        }

        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 30

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
        body.append("\(model)\r\n")

        // Add response format field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        let responseFormat = responseFormatForModel(model)
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

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ASRError.apiError("HTTP \(statusCode)")
        }

        return try parseResponse(data: data)
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

    private func parseResponse(data: Data) throws -> TranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
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

    private func responseFormatForModel(_ model: String) -> String {
        if model.hasPrefix("gpt-4o-transcribe") || model.hasPrefix("gpt-4o-mini-transcribe") {
            return "json"
        }
        return "verbose_json"
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
