import Foundation

/// ASR provider using ByteDance Volcano Engine BigModel API (batch mode)
public final class VolcanoASRProvider: ASRProvider, @unchecked Sendable {
    public let id = "volcano"
    public let displayName = "Volcano Engine (火山引擎)"
    public let supportsStreaming = false
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private let appId: String
    private let accessKey: String
    private let apiEndpoint = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
    private let resourceId = "volc.bigasr.auc_turbo"

    public init(appId: String, accessKey: String) {
        self.appId = appId
        self.accessKey = accessKey
    }

    public var isAvailable: Bool {
        !appId.isEmpty && !accessKey.isEmpty
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard !audio.isEmpty else { throw ASRError.noAudioData }

        let requestId = UUID().uuidString
        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.timeoutInterval = 30

        let wavData = AudioFormatHelper.wavData(for: audio)
        let base64Audio = wavData.base64EncodedString()

        let requestInfo: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true
        ]

        let payload: [String: Any] = [
            "user": ["uid": requestId],
            "audio": ["data": base64Audio],
            "request": requestInfo
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

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
            throw ASRError.transcriptionFailed("Failed to parse Volcano API response")
        }

        let code = json["code"] as? Int ?? -1
        if code != 1000 {
            let message = json["message"] as? String ?? "Unknown error"
            throw ASRError.apiError("Volcano: \(message)")
        }

        guard let result = json["result"] as? [String: Any],
              let text = result["text"] as? String else {
            throw ASRError.transcriptionFailed("Volcano response missing text")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ASRError.transcriptionFailed("Volcano returned empty transcription")
        }

        return TranscriptionResult(
            text: trimmed,
            language: .unknown,
            isFinal: true
        )
    }
}
