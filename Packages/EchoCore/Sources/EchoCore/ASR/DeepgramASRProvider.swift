import Foundation

/// ASR provider using Deepgram API (Nova).
/// Supports both batch transcription and WebSocket streaming.
public final class DeepgramASRProvider: ASRProvider, @unchecked Sendable {
    public let id = "deepgram"
    public let displayName = "Deepgram Nova"
    public let supportsStreaming = true
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private let keyStore: SecureKeyStore
    private let apiKeyOverride: String?

    // Batch endpoint
    private let apiEndpoint = "https://api.deepgram.com/v1/listen"
    private let wsEndpoint = "wss://api.deepgram.com/v1/listen"

    private let model: String
    private let language: String?
    private let punctuate: Bool
    private let smartFormat: Bool

    private var webSocketTask: URLSessionWebSocketTask?
    private var streamContinuation: AsyncStream<TranscriptionResult>.Continuation?
    private var streamingSession: URLSession?
    private var latestFinal: TranscriptionResult?

    public init(
        keyStore: SecureKeyStore = SecureKeyStore(),
        apiKey: String? = nil,
        model: String = "nova-3",
        language: String? = nil,
        punctuate: Bool = true,
        smartFormat: Bool = true
    ) {
        self.keyStore = keyStore
        self.apiKeyOverride = apiKey
        self.model = model
        self.language = language
        self.punctuate = punctuate
        self.smartFormat = smartFormat
    }

    public var isAvailable: Bool {
        if let apiKeyOverride, !apiKeyOverride.isEmpty { return true }
        return keyStore.hasKey(for: id)
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        let apiKey = try (apiKeyOverride ?? keyStore.retrieve(for: id)) ?? ""
        guard !apiKey.isEmpty else { throw ASRError.apiKeyMissing }
        guard !audio.isEmpty else { throw ASRError.noAudioData }

        let wavData = AudioFormatHelper.wavData(for: audio)

        var components = URLComponents(string: apiEndpoint)!
        var q: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "punctuate", value: punctuate ? "true" : "false"),
            URLQueryItem(name: "smart_format", value: smartFormat ? "true" : "false")
        ]
        if let language, !language.isEmpty {
            q.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = q

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = wavData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ASRError.apiError("Deepgram HTTP \(statusCode) \(body)")
        }

        return try parseBatchResponse(data: data)
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            Task {
                do {
                    let apiKey = try (apiKeyOverride ?? keyStore.retrieve(for: id)) ?? ""
                    guard !apiKey.isEmpty else {
                        continuation.finish()
                        return
                    }

                    var components = URLComponents(string: wsEndpoint)!
                    var q: [URLQueryItem] = [
                        URLQueryItem(name: "model", value: model),
                        URLQueryItem(name: "punctuate", value: punctuate ? "true" : "false"),
                        URLQueryItem(name: "smart_format", value: smartFormat ? "true" : "false"),
                        URLQueryItem(name: "interim_results", value: "true"),
                        URLQueryItem(name: "encoding", value: "linear16"),
                        URLQueryItem(name: "sample_rate", value: "16000"),
                        URLQueryItem(name: "channels", value: "1")
                    ]
                    if let language, !language.isEmpty {
                        q.append(URLQueryItem(name: "language", value: language))
                    }
                    components.queryItems = q

                    guard let url = components.url else {
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: url)
                    request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

                    let session = URLSession(configuration: .default)
                    let task = session.webSocketTask(with: request)

                    self.streamingSession = session
                    self.webSocketTask = task
                    self.streamContinuation = continuation
                    self.latestFinal = nil

                    task.resume()
                    self.receiveLoop(task: task)
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        guard let task = webSocketTask else {
            throw ASRError.streamingNotSupported
        }
        guard !chunk.isEmpty else { return }
        try await task.send(.data(chunk.data))
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        // Ask Deepgram to flush/finalize.
        if let task = webSocketTask {
            if let closeData = "{\"type\":\"CloseStream\"}".data(using: .utf8) {
                try? await task.send(.data(closeData))
            }
            task.cancel(with: .normalClosure, reason: nil)
        }

        let final = latestFinal
        streamContinuation?.finish()
        streamContinuation = nil
        webSocketTask = nil
        streamingSession?.invalidateAndCancel()
        streamingSession = nil

        return final
    }

    // MARK: - Private

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure:
                self.streamContinuation?.finish()
            case .success(let message):
                self.handleWebSocketMessage(message)
                self.receiveLoop(task: task)
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Typical payload contains:
        // {"is_final":bool,"channel":{"alternatives":[{"transcript":"..."}]}}
        let isFinal = (json["is_final"] as? Bool) ?? false

        let transcript: String = {
            if let channel = json["channel"] as? [String: Any],
               let alternatives = channel["alternatives"] as? [[String: Any]],
               let text = alternatives.first?["transcript"] as? String {
                return text
            }

            if let results = json["results"] as? [String: Any],
               let channels = results["channels"] as? [[String: Any]],
               let alternatives = channels.first?["alternatives"] as? [[String: Any]],
               let text = alternatives.first?["transcript"] as? String {
                return text
            }

            return ""
        }()

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let result = TranscriptionResult(text: trimmed, language: .unknown, isFinal: isFinal)
        if isFinal {
            latestFinal = result
        }
        streamContinuation?.yield(result)
    }

    private func parseBatchResponse(data: Data) throws -> TranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ASRError.transcriptionFailed("Failed to parse Deepgram response")
        }

        guard let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let firstChannel = channels.first,
              let alternatives = firstChannel["alternatives"] as? [[String: Any]],
              let firstAlt = alternatives.first,
              let transcript = firstAlt["transcript"] as? String else {
            throw ASRError.transcriptionFailed("Deepgram response missing transcript")
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ASRError.transcriptionFailed("Deepgram returned empty transcript")
        }

        var wordConfidences: [WordConfidence] = []
        if let words = firstAlt["words"] as? [[String: Any]] {
            for w in words {
                if let word = w["word"] as? String {
                    let confidence = (w["confidence"] as? Double) ?? 1.0
                    wordConfidences.append(WordConfidence(word: word, confidence: confidence))
                }
            }
        }

        return TranscriptionResult(
            text: trimmed,
            language: .unknown,
            isFinal: true,
            wordConfidences: wordConfidences
        )
    }
}
