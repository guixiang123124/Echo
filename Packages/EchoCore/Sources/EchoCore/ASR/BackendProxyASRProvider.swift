import Foundation

/// ASR provider that proxies transcription through Echo backend.
/// This keeps third-party provider API keys on the server side.
public final class BackendProxyASRProvider: ASRProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportsStreaming = true
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private let providerId: String
    private let backendBaseURL: String
    private let accessToken: String
    private let model: String?
    private let language: String?
    private let streamStateLock = NSLock()
    private var streamTask: Task<Void, Never>?
    private var streamIsActive = false
    private var streamChunks: [AudioChunk] = []
    private var streamLatestResultText = ""
    private var streamLatestLanguage = RecognizedLanguage.unknown
    private var streamContinuation: AsyncStream<TranscriptionResult>.Continuation?
    private var streamLastRequestAt = Date.distantPast
    private let streamRequestInterval: TimeInterval = 0.75

    public init(
        providerId: String,
        backendBaseURL: String,
        accessToken: String,
        model: String? = nil,
        language: String? = nil
    ) {
        self.providerId = providerId
        self.backendBaseURL = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = providerId
        self.displayName = "\(providerId) (Backend Proxy)"
    }

    public var isAvailable: Bool {
        !backendBaseURL.isEmpty && !accessToken.isEmpty
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard isAvailable else {
            throw ASRError.providerNotAvailable(displayName)
        }
        guard !audio.isEmpty else {
            throw ASRError.noAudioData
        }

        guard let endpoints = buildEndpoints(), !endpoints.isEmpty else {
            throw ASRError.apiError("Backend ASR proxy URL is invalid")
        }

        let wavData = AudioFormatHelper.wavData(for: audio)
        let body = ProxyRequest(
            provider: providerId,
            audioBase64: wavData.base64EncodedString(),
            audioMimeType: "audio/wav",
            model: normalizedOptional(model),
            language: normalizedOptional(language)
        )

        let encodedBody = try JSONEncoder().encode(body)
        var lastRouteMissMessage: String?

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = encodedBody

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ASRError.apiError("Invalid backend response")
            }

            if (200..<300).contains(httpResponse.statusCode) {
                if let decoded = try? JSONDecoder().decode(ProxyResponse.self, from: data) {
                    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        throw ASRError.transcriptionFailed("Backend returned empty transcription")
                    }

                    return TranscriptionResult(
                        text: text,
                        language: mapLanguage(decoded.language),
                        isFinal: true
                    )
                }

                let raw = String(data: data, encoding: .utf8) ?? ""
                if looksLikeRouteMismatch(raw) {
                    lastRouteMissMessage = compactErrorMessage(raw)
                    continue
                }
                throw ASRError.apiError("Backend returned unexpected response format")
            }

            let message = extractErrorMessage(data: data) ?? "Backend HTTP \(httpResponse.statusCode)"
            if shouldTryNextEndpoint(statusCode: httpResponse.statusCode, message: message) {
                lastRouteMissMessage = compactErrorMessage(message)
                continue
            }
            throw ASRError.apiError(message)
        }

        let suffix = lastRouteMissMessage ?? "Cannot find supported ASR proxy endpoint."
        throw ASRError.apiError("Backend ASR proxy endpoint mismatch. Verify Cloud API URL and backend deployment. \(suffix)")
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            if !startStreamSession(with: continuation) {
                continuation.finish()
                return
            }

            let task = Task {
                await self.runStreamingLoop(continuation: continuation)
            }
            setStreamTask(task)

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.stopStreamSession()
                }
            }
        }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        guard !chunk.isEmpty else { return }
        guard isStreamActive() else {
            throw ASRError.streamingNotSupported
        }
        appendStreamChunk(chunk)
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        let finalChunk = finalizeStreamSession()
        await stopStreamSession()

        guard let finalChunk else {
            return nil
        }

        do {
            let result = try await transcribe(audio: finalChunk)
            return TranscriptionResult(
                text: result.text,
                language: result.language,
                isFinal: true,
                wordConfidences: result.wordConfidences
            )
        } catch {
            return makeFinalStreamingResultFromLatest()
        }
    }

    private func buildEndpoints() -> [URL]? {
        let normalized: String
        if backendBaseURL.hasPrefix("http://") || backendBaseURL.hasPrefix("https://") {
            normalized = backendBaseURL
        } else {
            normalized = "https://\(backendBaseURL)"
        }

        guard let baseURL = URL(string: normalized) else {
            return nil
        }

        var endpoints: [URL] = []
        func append(_ candidate: URL?) {
            guard let candidate else { return }
            if !endpoints.contains(candidate) {
                endpoints.append(candidate)
            }
        }

        append(URL(string: "/v1/asr/transcribe", relativeTo: baseURL))
        append(URL(string: "/api/v1/asr/transcribe", relativeTo: baseURL))
        append(URL(string: "/api/asr/transcribe", relativeTo: baseURL))

        let scopedBaseRaw = normalized.hasSuffix("/") ? normalized : normalized + "/"
        if let scopedBaseURL = URL(string: scopedBaseRaw) {
            append(URL(string: "v1/asr/transcribe", relativeTo: scopedBaseURL))
            append(URL(string: "api/v1/asr/transcribe", relativeTo: scopedBaseURL))
            append(URL(string: "asr/transcribe", relativeTo: scopedBaseURL))
        }

        return endpoints
    }

    private func shouldTryNextEndpoint(statusCode: Int, message: String) -> Bool {
        if statusCode == 404 || statusCode == 405 {
            return true
        }
        return looksLikeRouteMismatch(message)
    }

    private func looksLikeRouteMismatch(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("cannot post")
            || lower.contains("not found")
            || lower.contains("route")
            || lower.contains("<!doctype html")
    }

    private func compactErrorMessage(_ value: String, limit: Int = 180) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "..."
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func extractErrorMessage(data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
        }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            return raw
        }
        return nil
    }

    private func mapLanguage(_ value: String?) -> RecognizedLanguage {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.hasPrefix("zh") {
            return .chinese
        }
        if normalized.hasPrefix("en") {
            return .english
        }
        if normalized.contains("mixed") || normalized.contains("mix") {
            return .mixed
        }
        return .unknown
    }

    private func startStreamSession(
        with continuation: AsyncStream<TranscriptionResult>.Continuation
    ) -> Bool {
        withStreamState {
            guard !streamIsActive else { return false }
            streamIsActive = true
            streamChunks.removeAll()
            streamLatestResultText = ""
            streamLatestLanguage = .unknown
            streamLastRequestAt = Date.distantPast
            streamContinuation = continuation
            return true
        }
    }

    private func stopStreamSession() async {
        let continuation = withStreamState {
            let currentContinuation = streamContinuation
            streamContinuation = nil
            streamIsActive = false
            return currentContinuation
        }
        setStreamTask(nil)
        continuation?.finish()
    }

    private func finalizeStreamSession() -> AudioChunk? {
        withStreamState {
            let chunk = makeCombinedChunk(streamChunks)
            if !streamChunks.isEmpty {
                streamChunks.removeAll()
            }
            streamLastRequestAt = Date.distantPast
            return chunk
        }
    }

    private func runStreamingLoop(continuation: AsyncStream<TranscriptionResult>.Continuation) async {
        while isStreamActive() {
            guard let snapshot = pollStreamAudioSnapshot() else {
                await continueAfterStreamInterval(reason: nil)
                continue
            }

            do {
                let response = try await transcribe(audio: snapshot.chunk)
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    await continueAfterStreamInterval(reason: "empty-result")
                    continue
                }

                let latestTextChanged = withStreamState {
                    let changed = streamLatestResultText != text
                    if changed {
                        streamLatestResultText = text
                        streamLatestLanguage = response.language
                    }
                    return changed
                }

                if latestTextChanged {
                    continuation.yield(
                        TranscriptionResult(
                            text: text,
                            language: response.language,
                            isFinal: false,
                            wordConfidences: response.wordConfidences
                        )
                    )
                }
            } catch {
                // Keep streaming alive if backend hiccups; finalization will fall back.
            }
        }
    }

    private func continueAfterStreamInterval(reason: String?) async {
        _ = reason
        try? await Task.sleep(for: .milliseconds(180))
    }

    private func pollStreamAudioSnapshot() -> (chunk: AudioChunk, text: String)? {
        withStreamState {
            guard streamIsActive else { return nil }
            if !isReadyForNextStreamRequest() {
                return nil
            }

            let nextChunk = makeCombinedChunk(streamChunks)
            guard let chunk = nextChunk else { return nil }

            streamLastRequestAt = Date()
            return (chunk: chunk, text: streamLatestResultText)
        }
    }

    private func makeFinalStreamingResultFromLatest() -> TranscriptionResult? {
        let text = withStreamState {
            let latest = streamLatestResultText
            let language = streamLatestLanguage
            return latest.isEmpty ? nil : TranscriptionResult(
                text: latest,
                language: language,
                isFinal: true
            )
        }
        return text
    }

    private func isReadyForNextStreamRequest() -> Bool {
        if streamChunks.isEmpty {
            return false
        }
        if Date().timeIntervalSince(streamLastRequestAt) < streamRequestInterval {
            return false
        }
        return true
    }

    private func appendStreamChunk(_ chunk: AudioChunk) {
        withStreamState {
            guard streamIsActive else { return }
            streamChunks.append(chunk)
        }
    }

    private func setStreamTask(_ task: Task<Void, Never>?) {
        let old = withStreamState { () -> Task<Void, Never>? in
            let current = streamTask
            streamTask = task
            return current
        }
        old?.cancel()
    }

    private func isStreamActive() -> Bool {
        withStreamState { streamIsActive }
    }

    private func withStreamState<T>(_ operation: () -> T) -> T {
        streamStateLock.lock()
        defer { streamStateLock.unlock() }
        return operation()
    }

    private func makeCombinedChunk(_ chunks: [AudioChunk]) -> AudioChunk? {
        guard !chunks.isEmpty else { return nil }

        let data = chunks.reduce(Data()) { partial, chunk in
            partial + chunk.data
        }
        guard !data.isEmpty else { return nil }
        let format = chunks.first?.format ?? .default
        let duration = chunks.reduce(0.0) { total, chunk in total + chunk.duration }
        return AudioChunk(data: data, format: format, duration: duration)
    }
}

private struct ProxyRequest: Encodable {
    let provider: String
    let audioBase64: String
    let audioMimeType: String
    let model: String?
    let language: String?
}

private struct ProxyResponse: Decodable {
    let provider: String?
    let mode: String?
    let model: String?
    let language: String?
    let text: String
}
