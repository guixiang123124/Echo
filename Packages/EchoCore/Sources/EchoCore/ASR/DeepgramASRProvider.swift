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
    private var latestPartial: TranscriptionResult?
    private var latestStreamError: String?
    private var connectionRetries = 0
    private let maxConnectionRetries = 3
    private var lastReceivedTime: Date?
    private var healthCheckTimer: Task<Void, Never>?
    private var isStopping = false
    private var pendingAudioChunks: [Data] = []
    private let maxPendingAudioChunks = 256
    private var streamingModelCandidates: [String] = []
    private var streamingModelIndex = 0
    private var streamingLanguageCandidates: [String?] = [""]
    private var streamingLanguageIndex = 0
    private let stateLock = NSLock()

    private func withState<T>(_ block: () -> T) -> T {
        stateLock.withLock(block)
    }

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
        if let apiKeyOverride, !normalizeApiKey(apiKeyOverride).isEmpty { return true }
        return keyStore.hasKey(for: id)
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        let apiKey = try resolveApiKey()
        guard !apiKey.isEmpty else { throw ASRError.apiKeyMissing }
        guard !audio.isEmpty else { throw ASRError.noAudioData }

        let wavData = AudioFormatHelper.wavData(for: audio)
        let requestLanguage = resolveDeepgramLanguage(language)
        let candidates = batchCompatibleModelLanguageCandidates(for: requestLanguage)

        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            let candidateModel = candidate.model
            let candidateLanguage = candidate.language
            do {
                return try await transcribeWithModel(
                    audio: audio,
                    apiKey: apiKey,
                    wavData: wavData,
                    model: candidateModel,
                    language: candidateLanguage
                )
            } catch {
                lastError = error

                if let apiError = error as? ASRError,
                   shouldUseAlternativeModel(for: apiError, currentModel: candidateModel, requestLanguageCandidate: candidateLanguage),
                   index + 1 < candidates.count {
                    print("ℹ️ Deepgram: Batch model \(candidateModel) language=\(candidateLanguage ?? "auto") not supported/invalid, trying fallback candidate")
                    continue
                }
                if let apiError = error as? ASRError,
                   shouldRetryWithAlternateModel(for: apiError),
                   index + 1 < candidates.count {
                    print("ℹ️ Deepgram: Batch model \(candidateModel) returned empty transcript, trying fallback model")
                    continue
                }
                throw error
            }
        }

        throw lastError ?? ASRError.transcriptionFailed("Deepgram batch transcription failed")
    }

    private func transcribeWithModel(
        audio: AudioChunk,
        apiKey: String,
        wavData: Data,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
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
            if let apiError = analyzeDeepgramError(statusCode: statusCode, body: body) {
                throw apiError
            }
            throw ASRError.apiError("Deepgram HTTP \(statusCode) \(body)")
        }

        return try parseBatchResponse(data: data)
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            Task {
                let requestLanguage = self.resolveDeepgramLanguage(self.language)
                let initialModelCandidates = self.streamingModelCandidates(for: requestLanguage)
                let initialModel = initialModelCandidates.first ?? self.model
                let initialLanguageCandidates = self.deepgramLanguageCandidates(
                    for: initialModel,
                    requestLanguage: requestLanguage
                )

                self.withState {
                    self.connectionRetries = 0
                    self.isStopping = false
                    self.latestFinal = nil
                    self.latestPartial = nil
                    self.latestStreamError = nil
                    self.lastReceivedTime = nil
                    self.pendingAudioChunks.removeAll()
                    self.streamContinuation = continuation
                    self.streamingModelCandidates = initialModelCandidates
                    self.streamingLanguageCandidates = initialLanguageCandidates
                    self.streamingModelIndex = 0
                    self.streamingLanguageIndex = 0
                }

                await self.startStreamingWithRetry(continuation: continuation)
            }
        }
    }

    private func startStreamingWithRetry(continuation: AsyncStream<TranscriptionResult>.Continuation) async {
        do {
            let apiKey = try resolveApiKey()
            guard !apiKey.isEmpty else {
                print("⚠️ Deepgram: API key missing, cannot start streaming")
                continuation.finish()
                return
            }
            cleanupStreamingSession(reason: "retry")

            let candidates = withState { streamingModelCandidates }
            let candidateIndex = withState { streamingModelIndex }
            let languageCandidates = withState {
                if streamingLanguageCandidates.isEmpty {
                    return deepgramLanguageCandidates(
                        for: candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : model,
                        requestLanguage: resolveDeepgramLanguage(language)
                    )
                }
                return streamingLanguageCandidates
            }
            guard candidateIndex < candidates.count else {
                print("⚠️ Deepgram: No stream model candidates available")
                continuation.finish()
                return
            }

            let safeLanguageIndex = withState {
                let idx = streamingLanguageIndex
                if languageCandidates.indices.contains(idx) {
                    return idx
                }
                if languageCandidates.isEmpty {
                    streamingLanguageCandidates = [resolveDeepgramLanguage(language)]
                    streamingLanguageIndex = 0
                    return 0
                }
                let normalized = min(max(0, idx), languageCandidates.count - 1)
                streamingLanguageIndex = normalized
                return normalized
            }

            let resolvedModel = candidates[candidateIndex]
            let requestedLanguage = withState {
                if streamingLanguageCandidates.isEmpty {
                    streamingLanguageCandidates = languageCandidates
                }
                return languageCandidates.indices.contains(safeLanguageIndex)
                    ? languageCandidates[safeLanguageIndex]
                    : nil
            }
            let effectiveLanguage = resolveDeepgramLanguageForModel(model: resolvedModel, language: requestedLanguage)

            var components = URLComponents(string: wsEndpoint)!
            var q: [URLQueryItem] = [
                URLQueryItem(name: "model", value: resolvedModel),
                URLQueryItem(name: "punctuate", value: punctuate ? "true" : "false"),
                URLQueryItem(name: "smart_format", value: smartFormat ? "true" : "false"),
                URLQueryItem(name: "interim_results", value: "true"),
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: "16000"),
                URLQueryItem(name: "channels", value: "1")
            ]
            if let effectiveLanguage, !effectiveLanguage.isEmpty {
                q.append(URLQueryItem(name: "language", value: effectiveLanguage))
            }
            components.queryItems = q

            guard let url = components.url else {
                print("⚠️ Deepgram: Invalid WebSocket URL")
                continuation.finish()
                return
            }

            var request = URLRequest(url: url)
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60

            let session = URLSession(configuration: config)
            let task = session.webSocketTask(with: request)

            let attempt = withState {
                self.streamingSession = session
                self.webSocketTask = task
                self.streamContinuation = continuation
                self.latestFinal = nil
                self.latestPartial = nil
                self.latestStreamError = nil
                self.lastReceivedTime = Date()
                self.isStopping = false
                self.pendingAudioChunks.removeAll()
                return self.connectionRetries + 1
            }

            let modelInfo = withState {
                let candidateCount = streamingLanguageCandidates.count
                let langDisplay = requestedLanguage ?? "auto"
                return "\(resolvedModel)[\(streamingModelIndex)] lang=\(langDisplay), languageIdx=\(streamingLanguageIndex)/\(max(0, candidateCount - 1)), mode=stream"
            }
            print("ℹ️ Deepgram: Starting WebSocket (attempt \(attempt)/\(maxConnectionRetries + 1)) model=\(modelInfo)")
            task.resume()

            startHealthCheckTimer()
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                await self?.flushPendingAudioChunks()
            }
            receiveLoop(task: task, model: resolvedModel)
        } catch {
            print("⚠️ Deepgram: Failed to start streaming: \(error.localizedDescription)")

            let shouldRetry = withState {
                guard self.connectionRetries < self.maxConnectionRetries else { return false }
                self.connectionRetries += 1
                return true
            }

            if shouldRetry {
                let delay = withState { pow(2.0, Double(self.connectionRetries)) }
                print("ℹ️ Deepgram: Retrying connection in \(Int(delay)) seconds")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await startStreamingWithRetry(continuation: continuation)
            } else {
                print("⚠️ Deepgram: Max retries reached, giving up")
                continuation.finish()
            }
        }
    }

    private func startHealthCheckTimer() {
        healthCheckTimer?.cancel()
        healthCheckTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                guard let self else { break }
                let snapshot = self.withState { () -> (elapsed: Double, continuation: AsyncStream<TranscriptionResult>.Continuation?, task: URLSessionWebSocketTask?)? in
                    guard
                        !self.isStopping,
                        let lastReceived = self.lastReceivedTime,
                        self.connectionRetries < self.maxConnectionRetries
                    else { return nil }

                    let elapsed = Date().timeIntervalSince(lastReceived)
                    guard elapsed > 30 else { return nil }

                    self.connectionRetries += 1
                    return (elapsed: elapsed, continuation: self.streamContinuation, task: self.webSocketTask)
                }

                if let snapshot {
                    print("⚠️ Deepgram: No data for \(Int(snapshot.elapsed))s, reconnecting")
                    snapshot.task?.cancel(with: .abnormalClosure, reason: nil)
                    if let continuation = snapshot.continuation {
                        await startStreamingWithRetry(continuation: continuation)
                    }
                    break
                }
            }
        }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        let task = withState { webSocketTask }
        guard let task else {
            throw ASRError.streamingNotSupported
        }
        guard !chunk.isEmpty else { return }
        let sent = await sendStreamChunk(chunk.data, task: task)
        if !sent {
            let queued = withState {
                if isStopping { return false }
                pendingAudioChunks.append(chunk.data)
                if pendingAudioChunks.count > maxPendingAudioChunks {
                    pendingAudioChunks.removeFirst(pendingAudioChunks.count - maxPendingAudioChunks)
                }
                return true
            }
            if !queued {
                throw ASRError.streamingNotSupported
            }
            Task.detached { [weak self] in
                await self?.flushPendingAudioChunks()
            }
        }
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil

        let state = withState {
            isStopping = true
            return (task: webSocketTask, session: streamingSession, continuation: streamContinuation)
        }

        let final = await waitForStreamingFinal(timeoutMilliseconds: 3500)

        if let task = state.task {
            await sendDeepgramCloseStream(task: task)
        }

        state.task?.cancel(with: .normalClosure, reason: nil)
        state.session?.invalidateAndCancel()

        let finalResult = withState {
            let candidate = Self.preferredStopResult(final: latestFinal, partial: latestPartial ?? final)
            guard let candidate else { return nil as TranscriptionResult? }

            let reason = Self.stopResultSource(final: latestFinal, partial: latestPartial ?? final, selected: candidate)
            print("🧭 DeepgramDiag: stop result source=\(reason) textLen=\(candidate.text.count) isFinal=\(candidate.isFinal)")

            streamContinuation = nil
            webSocketTask = nil
            streamingSession = nil
            latestStreamError = nil
            connectionRetries = 0
            lastReceivedTime = nil
            latestFinal = nil
            latestPartial = nil
            pendingAudioChunks.removeAll()
            return candidate
        }

        state.continuation?.finish()
        return finalResult
    }

    private func waitForStreamingFinal(timeoutMilliseconds: UInt64) async -> TranscriptionResult? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000)
        let interval: UInt64 = 80_000_000

        while Date() < deadline {
            if let latest = withState({ latestFinal }) {
                return latest
            }
            try? await Task.sleep(nanoseconds: interval)
        }

        return withState { latestFinal }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, model: String) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .failure(let error):
                print("⚠️ Deepgram: WebSocket receive error: \(error.localizedDescription)")

                let shouldRetry = self.withState {
                    guard !self.isStopping else { return false }
                    guard self.connectionRetries < self.maxConnectionRetries else { return false }
                    self.connectionRetries += 1
                    return true
                }

                let continuation = self.withState { self.streamContinuation }
                if shouldRetry {
                    let switched = self.withState { () -> Bool in
                        guard self.canSwitchToAlternativeStreamModel(message: error.localizedDescription) else { return false }
                        return self.advanceStreamCandidate(when: error.localizedDescription)
                    }

                    let attemptDelay = self.withState { pow(2.0, Double(self.connectionRetries)) }

                    Task {
                        print("ℹ️ Deepgram: Reconnecting in \(Int(attemptDelay))s for model idx \(self.withState { self.streamingModelIndex }) (switchedModel: \(switched))...")
                        try? await Task.sleep(nanoseconds: UInt64(attemptDelay * 1_000_000_000))
                        if let continuation {
                            await self.startStreamingWithRetry(continuation: continuation)
                        }
                    }
                } else {
                    continuation?.finish()
                }

            case .success(let message):
                self.withState { self.lastReceivedTime = Date() }
                if self.handleWebSocketMessage(message, model: model) {
                    let continuation = self.withState { self.streamContinuation }
                    let switched = self.withState { () -> Bool in
                        guard self.canSwitchToAlternativeStreamModel(message: self.latestStreamError ?? "") else { return false }
                        return self.advanceStreamCandidate(when: self.latestStreamError ?? "")
                    }

                    let shouldRetry = self.withState { () -> Bool in
                        guard !self.isStopping else { return false }
                        guard self.connectionRetries < self.maxConnectionRetries else { return false }
                        self.connectionRetries += 1
                        return true
                    }

                    if shouldRetry {
                        let attemptDelay = self.withState { pow(2.0, Double(self.connectionRetries)) }
                        Task {
                            print("ℹ️ Deepgram: Reconnecting in \(Int(attemptDelay))s after stream error (switchedModel: \(switched))...")
                            try? await Task.sleep(nanoseconds: UInt64(attemptDelay * 1_000_000_000))
                            if let continuation {
                                await self.startStreamingWithRetry(continuation: continuation)
                            }
                        }
                    } else {
                        continuation?.finish()
                    }
                    return
                }

                let shouldContinue = self.withState {
                    !self.isStopping || self.latestFinal == nil
                }
                if shouldContinue {
                    self.receiveLoop(task: task, model: model)
                }
            }
        }
    }

    private func sendStreamChunk(_ data: Data, task: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { continuation in
            task.send(.data(data)) { error in
                if let error {
                    print("⚠️ Deepgram: stream send failed: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private func sendDeepgramCloseStream(task: URLSessionWebSocketTask) async {
        let payload = """
        {"type":"CloseStream"}
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payloadData = payload.data(using: .utf8) else { return }

        let sent = await withCheckedContinuation { continuation in
            task.send(.data(payloadData)) { error in
                if let error {
                    print("⚠️ Deepgram: close-stream send failed: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }

        if !sent {
            print("⚠️ Deepgram: close-stream send was rejected")
        }
    }

    private func flushPendingAudioChunks() async {
        while true {
            let nextChunk: Data? = withState {
                guard !isStopping, !pendingAudioChunks.isEmpty else { return nil }
                return pendingAudioChunks.removeFirst()
            }

            guard let chunk = nextChunk else { return }

            let task = withState { webSocketTask }
            guard let task else {
                withState {
                    if isStopping { return }
                    pendingAudioChunks.insert(chunk, at: 0)
                    if pendingAudioChunks.count > maxPendingAudioChunks {
                        pendingAudioChunks.removeLast(pendingAudioChunks.count - maxPendingAudioChunks)
                    }
                }
                return
            }

            let sent = await sendStreamChunk(chunk, task: task)
            if !sent {
                withState {
                    if isStopping { return }
                    pendingAudioChunks.insert(chunk, at: 0)
                    if pendingAudioChunks.count > maxPendingAudioChunks {
                        pendingAudioChunks.removeLast(pendingAudioChunks.count - maxPendingAudioChunks)
                    }
                }
                return
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func cleanupStreamingSession(reason: String) {
        let previousTask = withState {
            let task = webSocketTask
            let session = streamingSession
            webSocketTask = nil
            streamingSession = nil
            latestFinal = nil
            latestPartial = nil
            isStopping = true
            return (task, session)
        }

        if let task = previousTask.0 {
            task.cancel(with: .abnormalClosure, reason: reason.data(using: .utf8))
        }
        previousTask.1?.invalidateAndCancel()
    }

    private func canSwitchToAlternativeStreamModel(message: String) -> Bool {
        if streamingLanguageIndex + 1 < streamingLanguageCandidates.count { return true }
        guard streamingModelIndex + 1 < streamingModelCandidates.count else { return false }
        let message = message.lowercased()
        let hints = [
            "model",
            "language",
            "unsupported",
            "combination",
            "bad request",
            "insufficient_permissions",
            "requested model",
            "not have access",
            "access denied",
            "400",
            "422",
            "404",
            "403",
            "401",
            "invalid",
            "unauthorized",
            "permission",
            "not available",
            "model not found",
            "not exist"
        ]
        return hints.contains { message.contains($0) }
    }

    private func advanceStreamCandidate(when message: String) -> Bool {
        if streamingLanguageIndex + 1 < streamingLanguageCandidates.count {
            streamingLanguageIndex += 1
            latestStreamError = nil
            return true
        }

        guard streamingModelIndex + 1 < streamingModelCandidates.count else { return false }
        let nextModel = streamingModelCandidates[streamingModelIndex + 1]
        let requestLanguage = resolveDeepgramLanguage(language)
        streamingModelIndex += 1
        streamingLanguageCandidates = deepgramLanguageCandidates(for: nextModel, requestLanguage: requestLanguage)
        streamingLanguageIndex = 0
        latestStreamError = nil
        return canSwitchToAlternativeStreamModel(message: message) || !streamingLanguageCandidates.isEmpty
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message, model: String) -> Bool {
        let payloads = decodeDeepgramMessageJSONPayloads(message)
        guard !payloads.isEmpty else {
            return false
        }

        var shouldReconnect = false
        for json in payloads {
            if let errorMessage = extractDeepgramStreamError(from: json) {
                print("⚠️ Deepgram: Stream error payload received for model \(model): \(errorMessage)")
                withState {
                    latestStreamError = errorMessage
                }
                shouldReconnect = canSwitchToAlternativeStreamModel(message: errorMessage) || shouldReconnect
                continue
            }

            if let rawMessage = json["message"] as? String,
               let type = json["type"] as? String,
               type.lowercased().contains("error"),
               !rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("⚠️ Deepgram: Stream error payload received for model \(model): \(rawMessage)")
                withState { latestStreamError = rawMessage }
                shouldReconnect = canSwitchToAlternativeStreamModel(message: rawMessage) || shouldReconnect
                continue
            }

            let isFinal = resolveDeepgramFinalFlag(from: json)
            let transcript = extractDeepgramTranscript(from: json)
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if isFinal {
                    let statusHint = describeDeepgramStreamState(from: json)
                    let hasPartial = withState { latestPartial?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                    if hasPartial {
                        print("ℹ️ Deepgram: Final message received with empty transcript for model \(model). Keeping partial text for stop fallback. \(statusHint)")
                        withState { latestFinal = nil }
                    } else {
                        withState {
                            latestFinal = TranscriptionResult(text: "", language: .unknown, isFinal: true)
                        }
                    }
                    withState { latestStreamError = statusHint }
                    print("⚠️ Deepgram: Final message received with empty transcript for model \(model). \(statusHint)")
                }
                continue
            }

            let result = TranscriptionResult(text: trimmed, language: .unknown, isFinal: isFinal)
            let continuation = withState {
                if isFinal {
                    latestFinal = result
                } else {
                    latestPartial = result
                }
                return streamContinuation
            }
            continuation?.yield(result)
        }
        return shouldReconnect
    }

    private static func preferredStopResult(final: TranscriptionResult?, partial: TranscriptionResult?) -> TranscriptionResult? {
        let trimmedFinal = final?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedPartial = partial?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedFinal.isEmpty {
            if !trimmedPartial.isEmpty, shouldUsePartialOverFinal(finalText: trimmedFinal, partialText: trimmedPartial) {
                return TranscriptionResult(text: trimmedPartial, language: final?.language ?? partial?.language ?? .unknown, isFinal: true)
            }
            return final
        }
        return partial
    }

    private static func stopResultSource(
        final: TranscriptionResult?,
        partial: TranscriptionResult?,
        selected: TranscriptionResult?
    ) -> String {
        let finalText = final?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let selected, let final, selected.text == final.text && selected.isFinal == final.isFinal && !finalText.isEmpty {
            return "final"
        }
        let partialText = partial?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let selectedText = selected?.text.trimmingCharacters(in: .whitespacesAndNewlines), !selectedText.isEmpty,
           !finalText.isEmpty,
           shouldUsePartialOverFinal(finalText: finalText, partialText: partialText),
           selectedText == partialText {
            return "partial-fallback-short-final"
        }
        if selected != nil, let finalText = final?.text, finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(partial?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return "partial-fallback-empty-final"
        }
        return "partial"
    }

    private static func shouldUsePartialOverFinal(finalText: String, partialText: String) -> Bool {
        let finalTrimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partialTrimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalTrimmed.isEmpty, !partialTrimmed.isEmpty else { return false }
        if finalTrimmed.count >= partialTrimmed.count { return false }
        if partialTrimmed.count >= 12 && finalTrimmed.count <= partialTrimmed.count - 6 { return true }
        if partialTrimmed.count >= 10 && finalTrimmed.count <= 3 { return true }
        if Double(finalTrimmed.count) <= Double(partialTrimmed.count) * 0.55 { return true }
        return false
    }

    private func decodeDeepgramMessageJSONPayloads(_ message: URLSessionWebSocketTask.Message) -> [[String: Any]] {
        let payloadData: [Data]
        switch message {
        case .string(let text):
            payloadData = [Data(text.utf8)]
        case .data(let d):
            payloadData = [d]
        @unknown default:
            return []
        }

        var results: [[String: Any]] = []
        for data in payloadData {
            results.append(contentsOf: decodeJSONObjects(from: data))
        }
        return dedupeJSONObjectList(results)
    }

    private func decodeJSONObjects(from data: Data) -> [[String: Any]] {
        var results: [[String: Any]] = []

        let candidates = decodeJSONTexts(from: data)
        for candidate in candidates {
            guard let candidateData = candidate.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: candidateData) else {
                continue
            }

            switch decoded {
            case let dict as [String: Any]:
                results.append(dict)
            case let array as [[String: Any]]:
                results.append(contentsOf: array)
            case let array as [Any]:
                for item in array {
                    if let dict = item as? [String: Any] {
                        results.append(dict)
                    }
                }
            default:
                break
            }
        }

        return results
    }

    private func decodeJSONTexts(from data: Data) -> [String] {
        // First try strict JSON decode for the full payload.
        if let fullObject = try? JSONSerialization.jsonObject(with: data) {
            return convertJSONValueToTexts(fullObject)
        }

        // Fall back to embedded JSON parsing for NDJSON/concatenated payloads.
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return extractEmbeddedJSONText(from: text)
    }

    private func convertJSONValueToTexts(_ value: Any) -> [String] {
        switch value {
        case let dict as [String: Any]:
            if let text = compactJsonText(from: dict) { return [text] }
            return []
        case let array as [[String: Any]]:
            return array.compactMap { item -> String? in
                if let text = compactJsonText(from: item) { return text }
                return nil
            }
        case let array as [Any]:
            return array.compactMap { item in
                convertJSONValueToTexts(item)
                    .first
            }
        default:
            return []
        }
    }

    private func compactJsonText(from value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func extractEmbeddedJSONText(from text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let lineJSON = lines.compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return nil
            }
            return line
        }
        if !lineJSON.isEmpty {
            return lineJSON
        }

        // As a fallback, parse concatenated JSON objects in the same buffer.
        return extractBalancedJSONSegments(from: text)
    }

    private func extractBalancedJSONSegments(from text: String) -> [String] {
        var segments: [String] = []
        guard !text.isEmpty else { return segments }

        var depth = 0
        var arrayDepth = 0
        var startIndex: String.Index?
        var inString = false
        var isEscaping = false

        func currentDepth() -> Int {
            return depth + arrayDepth
        }

        for (offset, scalar) in text.unicodeScalars.enumerated() {
            let index = text.index(text.startIndex, offsetBy: offset)

            if isEscaping {
                isEscaping = false
                continue
            }

            if inString {
                if scalar == "\\" { isEscaping = true; continue }
                if scalar == "\"" { inString = false }
                continue
            }

            if scalar == "\"" {
                inString = true
                continue
            }

            if scalar == "{" {
                if currentDepth() == 0 {
                    startIndex = index
                }
                depth += 1
            } else if scalar == "}" {
                if depth > 0 { depth -= 1 }
                if depth == 0, let start = startIndex {
                    let candidate = String(text[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        segments.append(candidate)
                    }
                    startIndex = nil
                }
            } else if scalar == "[" {
                if currentDepth() == 0 {
                    startIndex = index
                }
                arrayDepth += 1
            } else if scalar == "]" {
                if arrayDepth > 0 { arrayDepth -= 1 }
                if arrayDepth == 0, let start = startIndex {
                    let candidate = String(text[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        segments.append(candidate)
                    }
                    startIndex = nil
                }
            }
        }

        if let start = startIndex,
           let data = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            segments.append(String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return dedupeTextSegments(segments)
    }

    private func dedupeTextSegments(_ segments: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for segment in segments {
            if seen.insert(segment).inserted {
                output.append(segment)
            }
        }
        return output
    }

    private func dedupeJSONObjectList(_ jsons: [[String: Any]]) -> [[String: Any]] {
        var output: [[String: Any]] = []
        var seen = Set<String>()
        for item in jsons {
            let textHint = extractDeepgramTranscript(from: item).trimmingCharacters(in: .whitespacesAndNewlines)
            let finalHint = resolveDeepgramFinalFlag(from: item)
            if let requestId = item["request_id"] as? String {
                if !seen.insert("request_id:\(requestId)").inserted {
                    continue
                }
            } else if let sessionId = item["session_id"] as? String {
                if !seen.insert("session_id:\(sessionId)").inserted {
                    continue
                }
            } else {
                let signature = item.keys.sorted().joined(separator: ",")
                var signatureWithPayload = signature
                if let trimmedText = item["text"] as? String {
                    let shortText = trimmedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !shortText.isEmpty {
                        signatureWithPayload += "|text=\(shortText.prefix(80))"
                    }
                } else if !textHint.isEmpty {
                    signatureWithPayload += "|transcript=\(textHint.prefix(80))"
                }
                signatureWithPayload += "|final=\(finalHint)"

                if !seen.insert(signatureWithPayload).inserted {
                    continue
                }
            }
            output.append(item)
        }
        return output
    }

    private func parseBatchResponse(data: Data) throws -> TranscriptionResult {
        let jsonPayloads = decodeJSONTexts(from: data)
            .compactMap { payload -> [String: Any]? in
                guard let payloadData = payload.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: payloadData) else {
                    return nil
                }

                switch value {
                case let dict as [String: Any]:
                    return dict
                default:
                    return nil
                }
            }

        guard !jsonPayloads.isEmpty else {
            throw ASRError.transcriptionFailed("Failed to parse Deepgram response")
        }

        let nonEmptyPayloads = dedupeJSONObjectList(jsonPayloads)
        for json in nonEmptyPayloads {
            if let apiError = extractDeepgramBatchError(from: json) {
                throw ASRError.apiError(apiError)
            }
        }

        let collectedTexts = nonEmptyPayloads.compactMap {
            let text = extractDeepgramTranscript(from: $0)
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }

        guard !collectedTexts.isEmpty else {
            let keys = nonEmptyPayloads
                .map { $0.keys.map { $0 }.sorted().joined(separator: ", ") }
                .joined(separator: " | ")

            let snippet = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300) ?? ""
            throw ASRError.transcriptionFailed("Deepgram response missing transcript; keys=[\(keys)]; snippet=\(snippet)")
        }

        let mergedText = collectedTexts
            .enumerated()
            .map { index, text in
                index == 0 ? text : text
            }
            .joined(separator: " ")

        let trimmed = mergedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ASRError.transcriptionFailed("Deepgram returned empty transcript")
        }

        let bestSource = nonEmptyPayloads.first { candidate in
            let text = extractDeepgramTranscript(from: candidate).trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty
        }

        var wordConfidences: [WordConfidence] = []
        if let source = bestSource,
           let results = source["results"] as? [String: Any],
           let channels = results["channels"] as? [[String: Any]],
           let firstChannel = channels.first,
           let alternatives = firstChannel["alternatives"] as? [[String: Any]],
           let firstAlt = alternatives.first,
           let words = firstAlt["words"] as? [[String: Any]] {
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

    private func extractDeepgramBatchError(from json: [String: Any]) -> String? {
        var errors: [String] = []

        if let errorObject = json["error"] as? [String: Any] {
            if let message = errorObject["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(message)
            }
            if let code = errorObject["code"] {
                errors.append("code=\(String(describing: code))")
            }
            if let detail = errorObject["detail"] as? String,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(detail)
            }
        }

        if let code = json["code"] as? String, !code.isEmpty { errors.append("code=\(code)") }
        if let code = json["code"] as? Int { errors.append("code=\(code)") }
        if let errCode = json["err_code"] as? String, !errCode.isEmpty { errors.append("err_code=\(errCode)") }
        if let errCode = json["err_code"] as? Int { errors.append("err_code=\(errCode)") }
        if let message = json["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(message)
        }
        if let reason = json["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(reason)
        }

        let deduped = dedupeValues(errors)
        guard !deduped.isEmpty else { return nil }

        let requestId = (json["request_id"] as? String)
            ?? (json["request"] as? [String: Any]).flatMap { $0["id"] as? String }
            ?? (json["id"] as? String)

        if let requestId {
            return "Deepgram batch response error: \(deduped.joined(separator: "; ")); request_id=\(requestId)"
        }
        return "Deepgram batch response error: \(deduped.joined(separator: "; "))"
    }

    private func dedupeValues(_ values: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if seen.insert(trimmed).inserted {
                output.append(trimmed)
            }
        }
        return output
    }

    private func resolveApiKey() throws -> String {
        let candidate = try apiKeyOverride ?? keyStore.retrieve(for: id)
        return normalizeApiKey(candidate)
    }

    private func normalizeApiKey(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveDeepgramLanguage(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let normalized = raw.lowercased().replacingOccurrences(of: "_", with: "-")

        if ["zh", "zh-cn", "zh-hans", "zh-hans-cn", "zh-sg", "zh-my"].contains(normalized) {
            return "zh-CN"
        }

        if ["zh-tw", "zh-hant", "zh-hk", "zh-mo"].contains(normalized) {
            return "zh-TW"
        }

        if ["en", "en-us", "en-gb", "en-au", "en-ca", "en-cn"].contains(normalized) {
            return "en"
        }

        return raw
    }

    private func resolveDeepgramLanguageForModel(model: String, language: String?) -> String? {
        guard let resolved = language else { return nil }
        if resolved.hasPrefix("zh") && model.lowercased().contains("nova-3") {
            // Nova-3 is not always available for zh with explicit language on some accounts.
            return nil
        }
        return resolved
    }

    private struct DeepgramModelLanguageCandidate: Hashable {
        let model: String
        let language: String?
    }

    private func batchCompatibleModelLanguageCandidates(for requestLanguage: String?) -> [DeepgramModelLanguageCandidate] {
        var candidates: [DeepgramModelLanguageCandidate] = []
        let orderedModels = batchCompatibleModels(for: requestLanguage)
        let languageCandidates = deepgramLanguageCandidatesForBatch(requestLanguage)

        for model in orderedModels {
            for language in languageCandidates {
                let effectiveLanguage = resolveDeepgramLanguageForModel(model: model, language: language)
                candidates.append(DeepgramModelLanguageCandidate(model: model, language: effectiveLanguage))
            }
        }

        return dedupeCandidatePairs(candidates)
    }

    private func batchCompatibleModels(for language: String?) -> [String] {
        if let language, language.hasPrefix("zh") {
            return dedupePreserveOrder(["nova-2", "nova-2-general", model])
        }
        return dedupePreserveOrder([model, "nova-2", "nova-2-general", "nova-2-eu"])
    }

    private func deepgramLanguageCandidatesForBatch(_ requestLanguage: String?) -> [String?] {
        guard let requestLanguage else { return [nil, "en", "zh"] }
        if requestLanguage.hasPrefix("zh") {
            return [requestLanguage, "zh-CN", "zh", "en", nil]
        }
        if requestLanguage.hasPrefix("en") {
            return [requestLanguage, "en", "zh-CN", nil]
        }
        return [requestLanguage, nil, "zh-CN", "en"]
    }

    private func dedupeCandidatePairs(_ candidates: [DeepgramModelLanguageCandidate]) -> [DeepgramModelLanguageCandidate] {
        var seen = Set<String>()
        var output: [DeepgramModelLanguageCandidate] = []

        for item in candidates {
            let languageKey: String = {
                if let language = item.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                    return "\(item.model.lowercased())|\(language.lowercased())"
                }
                return "\(item.model.lowercased())|__nil__"
            }()
            if seen.insert(languageKey).inserted {
                output.append(item)
            }
        }

        return output
    }

    private func streamingModelCandidates(for language: String?) -> [String] {
        if let language, language.hasPrefix("zh") {
            return dedupePreserveOrder(["nova-2", "nova-2-general", model])
        }
        return dedupePreserveOrder([model, "nova-2", "nova-2-general"])
    }

    private func deepgramLanguageCandidates(for model: String, requestLanguage: String?) -> [String?] {
        guard let requestLanguage else { return [nil] }

        let normalized = requestLanguage.lowercased().replacingOccurrences(of: "_", with: "-")
        let explicitLanguage: String
        if ["zh", "zh-cn", "zh-hans", "zh-hans-cn", "zh-sg", "zh-my", "zh-tw", "zh-hant", "zh-hk", "zh-mo"].contains(normalized) {
            explicitLanguage = normalized.hasPrefix("zh-t") ? "zh-TW" : "zh-CN"
        } else if ["en", "en-us", "en-gb", "en-au", "en-ca"].contains(normalized) {
            explicitLanguage = "en"
        } else {
            explicitLanguage = requestLanguage
        }

        var candidates: [String?] = [explicitLanguage]

        if model.lowercased().contains("nova-3") && explicitLanguage.lowercased().hasPrefix("zh") {
            candidates.append(nil)
        }
        if !explicitLanguage.lowercased().hasPrefix("zh") {
            candidates.append("zh-CN")
        } else {
            candidates.append("en")
        }
        candidates.append(nil)

        var output: [String?] = []
        var seen = Set<String>()
        for value in candidates {
            let key: String
            if let value {
                let lowered = value.lowercased()
                if lowered.isEmpty { continue }
                key = lowered
            } else {
                key = "__nil__"
            }
            if seen.insert(key).inserted {
                output.append(value)
            }
        }
        return output
    }

    private func dedupePreserveOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let key = value.lowercased()
            if seen.insert(key).inserted {
                output.append(value)
            }
        }
        return output
    }

    private func analyzeDeepgramError(statusCode: Int, body: String) -> ASRError? {
        if statusCode == 401 || statusCode == 403 {
            if statusCode == 403 && isModelPermissionError(body: body) {
                return ASRError.apiError("Deepgram model/language permissions denied: \(body)")
            }
            return ASRError.apiError("Deepgram auth failed: \(statusCode) \(body)")
        }

        if statusCode == 400 && isModelLanguageMismatch(body: body) {
            return ASRError.apiError("Deepgram model/language combination is not supported: \(body)")
        }

        if statusCode >= 500 {
            return ASRError.apiError("Deepgram server error \(statusCode): \(body)")
        }

        return nil
    }

    private func isModelLanguageMismatch(body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("model") &&
            (lower.contains("language") || lower.contains("tier") || lower.contains("combination") || lower.contains("no such"))
    }

    private func isModelPermissionError(body: String) -> Bool {
        let parsedSignals = parseDeepgramErrorSignals(body: body)
        if !parsedSignals.isDisjoint(with: Set(["insufficient_permissions", "access denied", "no access", "model not found"])) {
            return true
        }

        let lower = body.lowercased()
        return lower.contains("insufficient_permissions") ||
            lower.contains("requested model") ||
            lower.contains("not have access") ||
            lower.contains("access denied")
    }

    private func parseDeepgramErrorSignals(body: String) -> Set<String> {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var found: [String] = []
        collectDeepgramErrorValues(from: json, into: &found)
        return Set(found.map { $0.lowercased() })
    }

    private func collectDeepgramErrorValues(from value: Any, into values: inout [String]) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if ["error", "message", "code", "err_code", "error_description", "detail"].contains(key.lowercased()),
                   let text = stringifyErrorToken(child), !text.isEmpty {
                    values.append(text)
                }
                collectDeepgramErrorValues(from: child, into: &values)
            }
        } else if let array = value as? [Any] {
            array.forEach { collectDeepgramErrorValues(from: $0, into: &values) }
        } else if let text = stringifyErrorToken(value), !text.isEmpty {
            values.append(text)
        }
    }

    private func stringifyErrorToken(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let num = value as? Int {
            return String(num)
        }
        return nil
    }

    private func shouldUseAlternativeModel(
        for error: ASRError,
        currentModel: String,
        requestLanguageCandidate: String?
    ) -> Bool {
        switch error {
        case .apiError(let message):
            let lower = message.lowercased()
            let recoverableSignals = [
                "combination",
                "unsupported",
                "bad request",
                "model access denied",
                "insufficient_permissions",
                "requested model",
                "not have access",
                "access denied",
                "permission",
                "not available",
                "forbidden",
                "unauthorized",
                "model not found",
                "invalid access",
                "resource"
            ]
            if recoverableSignals.contains(where: { lower.contains($0) }) {
                return true
            }
            if currentModel.lowercased().contains("nova-3"), let requestLanguageCandidate, requestLanguageCandidate.hasPrefix("zh") {
                return true
            }
            if lower.contains("invalid language") || lower.contains("unsupported language") || lower.contains("not support language") {
                return true
            }
            if let requestLanguageCandidate,
               let current = currentModel.lowercased() as String?,
               requestLanguageCandidate.hasPrefix("zh") && current.contains("nova-3") {
                    return true
            }
            if requestLanguageCandidate == nil && lower.contains("empty transcript") {
                return true
            }
        case .transcriptionFailed(let message):
            return shouldRetryWithAlternateModel(for: .transcriptionFailed(message))
        default:
            return false
        }
        return false
    }

    private func shouldRetryWithAlternateModel(for error: ASRError) -> Bool {
        guard case .transcriptionFailed(let message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("missing transcript") ||
            lower.contains("response missing transcript") ||
            lower.contains("empty transcript")
    }

    private func resolveDeepgramFinalFlag(from json: [String: Any]) -> Bool {
        if let isFinal = json["is_final"] as? Bool { return isFinal }
        if let channel = json["channel"] as? [String: Any],
           let isFinal = channel["is_final"] as? Bool {
            return isFinal
        }
        if let metadata = json["metadata"] as? [String: Any],
           let isFinal = metadata["is_final"] as? Bool {
            return isFinal
        }
        if let results = json["results"] as? [String: Any],
           let isFinal = results["is_final"] as? Bool {
            return isFinal
        }
        if let speechFinal = json["speech_final"] as? Bool {
            return speechFinal
        }
        if let metadata = json["metadata"] as? [String: Any],
           let status = metadata["status"] as? String,
           ["final", "ended", "completed"].contains(status.lowercased()) {
            return true
        }
        if let status = json["status"] as? String,
           ["final", "ended", "completed"].contains(status.lowercased()) {
            return true
        }
        if let request = json["request"] as? [String: Any],
           let final = request["final"] as? Bool {
            return final
        }
        if let channel = json["channel"] as? [String: Any],
           let final = channel["final"] as? Bool {
            return final
        }
        if let results = json["results"] as? [String: Any],
           let final = results["final"] as? Bool {
            return final
        }
        return false
    }

    private func extractDeepgramStreamError(from json: [String: Any]) -> String? {
        if let errorObject = json["error"] as? [String: Any] {
            if let message = errorObject["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let code = errorObject["code"] as? String, !code.isEmpty {
                return code
            }
            if let code = errorObject["code"] as? Int {
                return String(code)
            }
            if let detail = errorObject["detail"] as? String, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return detail
            }
        }

        if let type = json["type"] as? String,
           type.lowercased().contains("error") {
            if let code = json["code"] {
                if let codeString = stringifyErrorToken(code), !codeString.isEmpty {
                    return codeString
                }
            }
            if let detail = json["detail"] as? String, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return detail
            }
            if let message = json["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }

        return nil
    }

    private func describeDeepgramStreamState(from json: [String: Any]) -> String {
        if let isFinal = json["is_final"] as? Bool {
            return "is_final=\(isFinal)"
        }
        if let channel = json["channel"] as? [String: Any],
           let final = channel["final"] as? Bool {
            return "channel.final=\(final)"
        }
        if let results = json["results"] as? [String: Any],
           let final = results["final"] as? Bool {
            return "results.final=\(final)"
        }
        if let request = json["request"] as? [String: Any],
           let final = request["final"] as? Bool {
            return "request.final=\(final)"
        }
        if let status = json["status"] as? String {
            return "status=\(status)"
        }
        if let requestId = json["request_id"] as? String {
            return "request_id=\(requestId)"
        }
        return "stream-state-unavailable"
    }

    private func extractDeepgramTranscript(from json: [String: Any]) -> String {
        if let channel = json["channel"] as? [String: Any],
           let transcript = extractAlternativesText(from: channel) {
            return transcript
        }

        if let results = json["results"] as? [String: Any],
           let channels = results["channels"] as? [[String: Any]],
           let firstChannel = channels.first,
           let transcript = extractAlternativesText(from: firstChannel) {
            return transcript
        }

        if let alternatives = json["alternatives"] as? [[String: Any]],
           let first = alternatives.first,
           let text = first["transcript"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let transcript = json["transcript"] as? String {
            return transcript
        }

        if let output = extractDeepgramTextCandidates(from: json) {
            return output
        }

        if let output = extractDeepgramDeepText(from: json, depth: 0) {
            return output
        }

        return ""
    }

    private func extractDeepgramTextCandidates(from json: [String: Any]) -> String? {
        if let results = json["results"] as? [String: Any] {
            if let text = extractDeepgramTextCandidates(from: results) {
                return text
            }
        }

        if let alternative = json["alternatives"] as? [[String: Any]],
           let first = alternative.first,
           let text = extractAlternativesText(from: ["alternatives": [first]]),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let transcript = json["result"] as? String,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcript
        }

        if let utterances = json["utterances"] as? [[String: Any]],
           let text = extractText(from: utterances) {
            return text
        }

        if let payload = json["payload"] as? [String: Any],
           let text = extractDeepgramDeepText(from: payload, depth: 1) {
            return text
        }

        if let response = json["response"] as? [String: Any],
           let text = extractDeepgramDeepText(from: response, depth: 1) {
            return text
        }

        return nil
    }

    private func extractText(from utterances: [[String: Any]]) -> String? {
        let text = utterances.compactMap { utterance in
            if let utteranceText = utterance["text"] as? String {
                return utteranceText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let transcript = utterance["transcript"] as? String {
                return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        return text.isEmpty ? nil : text
    }

    private func extractDeepgramDeepText(from value: Any, depth: Int) -> String? {
        guard depth < 5 else { return nil }

        if let dict = value as? [String: Any] {
            if let text = dict["transcript"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = dict["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = dict["utterance"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = dict["result"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let utterances = dict["utterances"] as? [[String: Any]],
               let text = extractText(from: utterances),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let paragraphs = dict["paragraphs"] as? [String: Any],
               let text = paragraphs["transcript"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }

            let containerKeys: [String] = [
                "results",
                "result",
                "channel",
                "channels",
                "alternatives",
                "utterances",
                "utterance",
                "data",
                "metadata",
                "payload",
                "response",
                "paragraphs",
                "output",
                "alternatives_text",
                "hypotheses",
                "segments"
            ]
            for key in containerKeys {
                if let nested = dict[key], let text = extractDeepgramDeepText(from: nested, depth: depth + 1) {
                    return text
                }
            }

            for (_, nested) in dict {
                if let text = extractDeepgramDeepText(from: nested, depth: depth + 1) {
                    return text
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let text = extractDeepgramDeepText(from: item, depth: depth + 1) {
                    return text
                }
            }
        }

        return nil
    }

    private func extractAlternativesText(from container: [String: Any]) -> String? {
        if let alternatives = container["alternatives"] as? [[String: Any]],
           let first = alternatives.first {
            if let text = first["transcript"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }

            if let words = first["words"] as? [[String: Any]] {
                let joined = words
                    .compactMap({ $0["word"] as? String })
                    .joined(separator: " ")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return joined
                }
            }

            if let paragraphs = first["paragraphs"] as? [String: Any],
               let transcript = paragraphs["transcript"] as? String,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transcript
            }
        }

        if let paragraphs = container["paragraphs"] as? [String: Any],
           let transcript = paragraphs["transcript"] as? String,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcript
        }

        return nil
    }
}
