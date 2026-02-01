import Foundation

/// ASR provider using OpenAI Whisper API (batch mode, $0.006/minute)
public final class OpenAIWhisperProvider: ASRProvider, @unchecked Sendable {
    public let id = "openai_whisper"
    public let displayName = "OpenAI Whisper"
    public let supportsStreaming = false
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private let keyStore: SecureKeyStore
    private let apiEndpoint = "https://api.openai.com/v1/audio/transcriptions"

    public init(keyStore: SecureKeyStore = SecureKeyStore()) {
        self.keyStore = keyStore
    }

    public var isAvailable: Bool {
        keyStore.hasKey(for: id)
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard let apiKey = try keyStore.retrieve(for: id) else {
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
        body.append(createWavHeader(for: audio))
        body.append(audio.data)
        body.append("\r\n")

        // Add model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("whisper-1\r\n")

        // Add response format field (verbose JSON for word timestamps)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.append("verbose_json\r\n")

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

    /// Create a minimal WAV header for the audio data
    private func createWavHeader(for audio: AudioChunk) -> Data {
        var header = Data()
        let dataSize = UInt32(audio.data.count)
        let sampleRate = UInt32(audio.format.sampleRate)
        let channels = UInt16(audio.format.channelCount)
        let bitsPerSample = UInt16(audio.format.bitsPerSample)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        header.append("RIFF")
        header.appendLittleEndian(UInt32(36 + dataSize))
        header.append("WAVE")
        header.append("fmt ")
        header.appendLittleEndian(UInt32(16)) // Subchunk1 size
        header.appendLittleEndian(UInt16(1))  // PCM format
        header.appendLittleEndian(channels)
        header.appendLittleEndian(sampleRate)
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)
        header.append("data")
        header.appendLittleEndian(dataSize)

        return header
    }
}

// MARK: - Data Extensions

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<T>.size))
    }
}
