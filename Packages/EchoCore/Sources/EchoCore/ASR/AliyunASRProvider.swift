import Foundation

/// ASR provider using Alibaba Cloud NLS short speech RESTful API (batch mode)
public final class AliyunASRProvider: ASRProvider, @unchecked Sendable {
    public let id = "aliyun"
    public let displayName = "Alibaba Cloud NLS"
    public let supportsStreaming = false
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private let appKey: String
    private let token: String
    private let apiEndpoint = "https://nls-gateway.cn-shanghai.aliyuncs.com/stream/v1/asr"

    public init(appKey: String, token: String) {
        self.appKey = appKey
        self.token = token
    }

    public var isAvailable: Bool {
        !appKey.isEmpty && !token.isEmpty
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard !audio.isEmpty else { throw ASRError.noAudioData }

        var components = URLComponents(string: apiEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "appkey", value: appKey),
            URLQueryItem(name: "format", value: "pcm"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "enable_punctuation_prediction", value: "true"),
            URLQueryItem(name: "enable_inverse_text_normalization", value: "true")
        ]

        guard let url = components?.url else {
            throw ASRError.apiError("Invalid NLS endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-NLS-Token")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio.data
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ASRError.apiError("HTTP \(statusCode)")
        }

        return try parseResponse(data: data)
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { $0.finish() }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        throw ASRError.streamingNotSupported
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        nil
    }

    // MARK: - Private

    private func parseResponse(data: Data) throws -> TranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ASRError.transcriptionFailed("Failed to parse Alibaba NLS response")
        }

        let status = json["status"] as? Int ?? -1
        if status != 20000000 {
            let message = json["message"] as? String
                ?? json["error"] as? String
                ?? "Unknown error"
            throw ASRError.apiError("Alibaba NLS: \(message)")
        }

        guard let text = (json["result"] as? String) ?? (json["text"] as? String) else {
            throw ASRError.transcriptionFailed("Alibaba NLS response missing text")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ASRError.transcriptionFailed("Alibaba NLS returned empty transcription")
        }

        return TranscriptionResult(
            text: trimmed,
            language: .unknown,
            isFinal: true
        )
    }
}
