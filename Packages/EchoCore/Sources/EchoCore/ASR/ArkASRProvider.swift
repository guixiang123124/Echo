import Foundation

/// ASR provider using Volcano Ark API (batch transcription)
public final class ArkASRProvider: ASRProvider, @unchecked Sendable {
    public let id = "ark_asr"
    public let displayName = "Volcano Ark ASR"
    public let supportsStreaming = false
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    public static let apiKeyKeyId = "ark_asr"
    public static let modelKeyId = "ark_asr_model"
    public static let endpointKeyId = "ark_asr_endpoint"

    private let keyStore: SecureKeyStore
    private let apiKeyOverride: String?
    private let modelOverride: String?
    private let language: String?
    private let apiEndpointOverride: String?

    public init(
        keyStore: SecureKeyStore = SecureKeyStore(),
        apiKey: String? = nil,
        model: String? = nil,
        language: String? = nil,
        apiEndpoint: String? = nil
    ) {
        self.keyStore = keyStore
        self.apiKeyOverride = apiKey
        self.modelOverride = model
        self.language = language
        self.apiEndpointOverride = apiEndpoint
    }

    public var isAvailable: Bool {
        if let apiKeyOverride, !apiKeyOverride.isEmpty { return true }
        return keyStore.hasKey(for: Self.apiKeyKeyId)
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        let apiKey = try (apiKeyOverride ?? keyStore.retrieve(for: Self.apiKeyKeyId)) ?? ""
        guard !apiKey.isEmpty else { throw ASRError.apiKeyMissing }
        guard !audio.isEmpty else { throw ASRError.noAudioData }

        let resolvedModel = try resolvedModelName()
        let resolvedEndpoint = try resolvedEndpointURL()

        let boundary = UUID().uuidString
        var request = URLRequest(url: resolvedEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(AudioFormatHelper.wavData(for: audio))
        body.append("\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(resolvedModel)\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.append("json\r\n")

        if let language, !language.isEmpty {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.append("\(language)\r\n")
        }

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ASRError.apiError("Ark HTTP \(statusCode) endpoint=\(resolvedEndpoint.absoluteString) model=\(resolvedModel) body=\(body)")
        }

        return try parseResponse(data: data)
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { $0.finish() }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        throw ASRError.streamingNotSupported
    }

    public func stopStreaming() async throws -> TranscriptionResult? { nil }

    private func resolvedModelName() throws -> String {
        let model = try (modelOverride ?? keyStore.retrieve(for: Self.modelKeyId))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (model?.isEmpty == false) ? model! : "doubao-seed-asr-2-0"
    }

    private func resolvedEndpointURL() throws -> URL {
        let endpoint = try (apiEndpointOverride ?? keyStore.retrieve(for: Self.endpointKeyId))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointString = (endpoint?.isEmpty == false) ? endpoint! : "https://ark.cn-beijing.volces.com/api/v3/audio/transcriptions"
        guard let url = URL(string: endpointString) else {
            throw ASRError.apiError("Ark endpoint is invalid: \(endpointString)")
        }
        return url
    }

    private func parseResponse(data: Data) throws -> TranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ASRError.transcriptionFailed("Failed to parse Ark ASR response")
        }

        let text = (json["text"] as? String)
            ?? (json["result"] as? [String: Any])?["text"] as? String
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ASRError.transcriptionFailed("Ark returned empty transcript")
        }

        return TranscriptionResult(text: trimmed, language: .unknown, isFinal: true)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
