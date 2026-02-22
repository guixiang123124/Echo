import Foundation
import Compression

/// Manages a single WebSocket streaming ASR session with Volcano Engine BigModel.
///
/// Protocol: Custom binary frames over WebSocket.
///   Header (4 bytes):
///     byte 0: [version (4b)][header_size (4b)]   → 0x11
///     byte 1: [msg_type (4b)][flags (4b)]
///     byte 2: [serialization (4b)][compression (4b)]
///     byte 3: reserved → 0x00
///   Then: payload_size (4 bytes, big-endian UInt32), payload (bytes)
///
///   msg_type: 0x1 = full client request, 0x2 = audio only, 0x9 = server response, 0xF = error
///   flags:    0x0 = no seq, 0x1 = has sequence, 0x2 = last packet, 0x3 = last packet + sequence
///   serialization: 0x0 = none, 0x1 = JSON
///   compression:   0x0 = none, 0x1 = gzip
final class VolcanoStreamingSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    // MARK: - Configuration

    struct Config {
        let appId: String
        let accessKey: String
        let resourceId: String
        let endpoint: URL
        let sampleRate: Int
        let enableITN: Bool
        let enablePunc: Bool
        let enableDDC: Bool
    }

    // MARK: - State

    private let config: Config
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var isConnected = false
    private let lock = NSLock()
    private var connectionRetries = 0
    private let maxConnectionRetries = 3
    private var lastReceivedTime: Date?
    private var healthCheckTimer: Task<Void, Never>?
    private var isStopping = false
    private var latestFinalResult: TranscriptionResult?
    private var latestPartialResult: TranscriptionResult?
    private var pendingAudioFrames: [Data] = []
    private var nextOutboundSequence: UInt32 = 1

    private func diagnosticsLog(_ message: String) {
        print("🧭 VolcanoDiag: \(message)")
    }

    // MARK: - Init

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - Public API

    /// Start the streaming session. Returns an AsyncStream that yields partial results.
    func start() -> AsyncStream<TranscriptionResult> {
        let stream = AsyncStream<TranscriptionResult> { continuation in
            self.continuation = continuation
            self.withState {
                self.connectionRetries = 0
                self.isStopping = false
                self.latestFinalResult = nil
                self.isConnected = false
                self.nextOutboundSequence = 1
                self.lastReceivedTime = nil
                self.pendingAudioFrames.removeAll()
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.disconnect()
            }
        }

        connectWithRetry()
        return stream
    }

    /// Feed a chunk of PCM audio (16-bit LE, 16 kHz, mono).
    func feedAudio(_ chunk: AudioChunk) {
        guard !chunk.isEmpty else { return }

        let queuedFrame: Data?
        queuedFrame = withState {
            if isStopping { return nil }

            if isConnected, task != nil {
                return chunk.data
            }
            pendingAudioFrames.append(chunk.data)
            return nil
        }

        if let queuedFrame {
            sendAudioFrame(data: queuedFrame, isLast: false)
        }
    }

    /// Signal end of audio and wait for final result.
    func stop() async -> TranscriptionResult? {
        withState {
            isStopping = true
        }

        guard withState({ isConnected }) else {
            return nil
        }

        // Send explicit end packet before teardown so server can emit final result.
        sendAudioFrame(data: Data(), isLast: true, allowWhenStopping: true)

        // Give server a short window to emit final packet.
        // Prefer low-latency stop when partial text has already stabilized.
        let totalWaitNanos: UInt64 = 1_400_000_000
        let pollStepNanos: UInt64 = 80_000_000
        let attempts = Int(totalWaitNanos / pollStepNanos)
        var lastPartialSnapshot = ""
        var stablePartialTicks = 0
        for _ in 0..<attempts {
            let snapshot = withState { (latestFinalResult, latestPartialResult, isConnected, lastReceivedTime) }
            if snapshot.0 != nil {
                break
            }
            if !snapshot.2 {
                break
            }

            let partialText = snapshot.1?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !partialText.isEmpty {
                if partialText == lastPartialSnapshot {
                    stablePartialTicks += 1
                } else {
                    lastPartialSnapshot = partialText
                    stablePartialTicks = 0
                }

                let idleMs = snapshot.3.map { Date().timeIntervalSince($0) * 1000 } ?? 0
                if stablePartialTicks >= 2 && idleMs >= 240 {
                    diagnosticsLog("stop early finalize from stable partial idleMs=\(Int(idleMs)) len=\(partialText.count)")
                    break
                }
            }
            try? await Task.sleep(nanoseconds: pollStepNanos)
        }

        let finalResult = withState {
            let candidate = Self.preferredStopResult(final: latestFinalResult, partial: latestPartialResult)
            if let candidate {
                diagnosticsLog(
                    "stop result source=\(Self.stopResultSource(final: latestFinalResult, partial: latestPartialResult, selected: candidate)) textLen=\(candidate.text.count) isFinal=\(candidate.isFinal)"
                )
            } else {
                diagnosticsLog("stop result no final/partial available")
            }
            return candidate
        }
        disconnect()
        return finalResult
    }

    // MARK: - Testability Helpers

    static func preferredStopResult(final: TranscriptionResult?, partial: TranscriptionResult?) -> TranscriptionResult? {
        if let final {
            let finalTrimmed = final.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let partialTrimmed = partial?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !partialTrimmed.isEmpty,
               !finalTrimmed.isEmpty,
               Self.shouldUsePartialOverFinal(finalText: finalTrimmed, partialText: partialTrimmed) {
                return TranscriptionResult(text: partialTrimmed, language: final.language, isFinal: true)
            }

            if !finalTrimmed.isEmpty {
                return final
            }
        }
        if let partial, !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return partial
        }
        return final
    }

    static func stopResultSource(
        final: TranscriptionResult?,
        partial: TranscriptionResult?,
        selected: TranscriptionResult?
    ) -> String {
        let finalTrimmed = final?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let selected, let final,
           selected.text == final.text && selected.isFinal == final.isFinal,
           !finalTrimmed.isEmpty {
            return "final"
        }
        if let selected {
            let selectedTrimmed = selected.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let partialTrimmed = partial?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !selectedTrimmed.isEmpty && finalTrimmed.isEmpty && !partialTrimmed.isEmpty {
                return "partial-fallback-empty-final"
            }
            if selectedTrimmed.isEmpty && !partialTrimmed.isEmpty && selectedTrimmed != partialTrimmed {
                return "partial"
            }
            if selectedTrimmed == partialTrimmed,
               !selectedTrimmed.isEmpty,
               Self.shouldUsePartialOverFinal(finalText: finalTrimmed, partialText: partialTrimmed) {
                return "partial-fallback-short-final"
            }
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

    static func normalizedStreamingResult(_ incoming: TranscriptionResult, latestPartial: TranscriptionResult?) -> TranscriptionResult {
        let incomingTrimmed = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard incoming.isFinal, incomingTrimmed.isEmpty,
              let latestPartial,
              !latestPartial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return incoming
        }

        return TranscriptionResult(
            text: latestPartial.text,
            language: incoming.language,
            isFinal: true
        )
    }

    static func sanitizeStreamingText(_ text: String, previous: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Keep stream-time sanitation lightweight for long utterances.
        if trimmed.count > 260 {
            return collapseRepeatedPrefix(from: trimmed, around: previous)
        }

        let deduped = collapseDuplicateFullString(from: trimmed)
        let anchored = collapseRepeatedPrefix(from: deduped, around: previous)
        return anchored
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = String(trimmed.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        })
        let collapsed = normalized
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return collapsed
    }

    private static func appearsRegression(_ candidateText: String, against latestText: String?) -> Bool {
        guard let latestText else { return false }

        let latest = normalizedComparisonText(latestText)
        guard !candidateText.isEmpty, !latest.isEmpty else { return false }

        if candidateText == latest {
            return true
        }

        return candidateText.count <= latest.count &&
        (candidateText.count < latest.count && latest.hasPrefix(candidateText))
    }

    private static func collapseDuplicateFullString(from text: String) -> String {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return incoming }
        if incoming.count > 260 { return incoming }

        let fullTokens = incoming.split { $0.isWhitespace || $0.isNewline }
        if fullTokens.count >= 2 {
            for unitLength in stride(from: fullTokens.count / 2, through: 1, by: -1) {
                let unitCount = max(1, unitLength)
                guard fullTokens.count >= unitCount * 2 else { continue }

                let unit = Array(fullTokens.prefix(unitCount))
                var cursor = unitCount
                var duplicateRuns = 1

                while cursor + unitCount <= fullTokens.count,
                      Array(fullTokens[cursor..<(cursor + unitCount)]) == unit {
                    duplicateRuns += 1
                    cursor += unitCount
                }

                if duplicateRuns >= 2 {
                    let tail = fullTokens.dropFirst(unitCount * duplicateRuns)
                    let unitText = unit.joined(separator: " ")
                    guard !tail.isEmpty else {
                        return unitText
                    }
                    return "\(unitText) \(tail.joined(separator: " "))"
                }
            }
        }

        let incomingChars = Array(incoming)
        let maxUnitLength = incomingChars.count / 2
        guard maxUnitLength > 0 else { return incoming }

        for unitLength in stride(from: maxUnitLength, through: 1, by: -1) {
            let unit = Array(incomingChars[0..<unitLength])
            var cursor = unitLength
            var duplicateRuns = 1

            while cursor + unitLength <= incomingChars.count,
                  Array(incomingChars[cursor..<(cursor + unitLength)]) == unit {
                duplicateRuns += 1
                cursor += unitLength
            }

            if duplicateRuns >= 2 {
                let tail = String(incomingChars.dropFirst(unitLength * duplicateRuns)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tail.isEmpty else { return String(unit) }
                return "\(String(unit)) \(tail)"
            }
        }

        return incoming
    }

    private static func collapseRepeatedPrefix(from text: String, around previousText: String?) -> String {
        guard let previousText else { return text }

        let previousTrimmed = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if previousTrimmed.isEmpty || candidateTrimmed.isEmpty {
            return candidateTrimmed
        }

        let base = Array(previousTrimmed)
        let candidate = Array(candidateTrimmed)

        guard candidate.starts(with: base), base.count > 0 else {
            return candidateTrimmed
        }

        var cursor = base.count
        var repeatRuns = 1
        while cursor + base.count <= candidate.count,
              Array(candidate[cursor..<(cursor + base.count)]) == base {
            repeatRuns += 1
            cursor += base.count
        }

        guard repeatRuns >= 2 else { return candidateTrimmed }

        let tail = String(candidate.dropFirst(base.count * repeatRuns)).trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { return previousTrimmed }
        return "\(previousTrimmed) \(tail)"
    }

    // MARK: - WebSocket Connection

    private func connectWithRetry() {
        withState {
            if connectionRetries == 0 {
                print("ℹ️ Volcano: Opening streaming connection")
            }
        }
        connect()
    }

    private func withState<T>(_ block: () -> T) -> T {
        lock.withLock(block)
    }

    private func connect() {
        withState {
            isConnected = false
            isStopping = false
            latestFinalResult = nil
            latestPartialResult = nil
            lastReceivedTime = nil
            nextOutboundSequence = 1
        }

        var request = URLRequest(url: config.endpoint)
        request.setValue(config.appId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(config.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        request.timeoutInterval = 10

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60

        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    private func disconnect() {
        isStopping = true
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
        let wasConnected = withState {
            let result = isConnected
            isConnected = false
            lastReceivedTime = nil
            latestFinalResult = nil
            latestPartialResult = nil
            pendingAudioFrames.removeAll()
            return result
        }

        if wasConnected {
            task?.cancel(with: .goingAway, reason: nil)
        }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        withState {
            connectionRetries = 0
            isConnected = true
            lastReceivedTime = Date()
        }

        print("ℹ️ Volcano: WebSocket connected")
        sendFullClientRequest()
        flushPendingAudio()
        startHealthCheckTimer()
        receiveLoop()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        print("⚠️ Volcano: WebSocket closed with code \(closeCode.rawValue), reason: \(reasonString)")
        withState { isConnected = false }

        guard !isStopping else {
            continuation?.finish()
            return
        }

        if closeCode == .normalClosure || reasonString.localizedCaseInsensitiveContains("finish last sequence") {
            continuation?.finish()
            return
        }

        attemptReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            print("⚠️ Volcano WS error: \(error.localizedDescription)")
        }
        withState { isConnected = false }

        guard !isStopping else {
            continuation?.finish()
            return
        }
        attemptReconnect()
    }

    private func startHealthCheckTimer() {
        healthCheckTimer?.cancel()
        healthCheckTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { break }
                let state = self.withState {
                    (self.isConnected, self.lastReceivedTime, self.connectionRetries)
                }
                if state.0, let last = state.1 {
                    let elapsed = Date().timeIntervalSince(last)
                    if elapsed > 30 {
                        print("⚠️ Volcano: No data for \(Int(elapsed))s")
                        self.attemptReconnect()
                        break
                    }
                }
            }
        }
    }

    private func attemptReconnect() {
        if isStopping { return }
        let shouldRetry = withState { () -> Bool in
            guard connectionRetries < maxConnectionRetries else {
                return false
            }
            connectionRetries += 1
            return true
        }

        guard shouldRetry else {
            print("⚠️ Volcano: Max retries reached")
            continuation?.finish()
            return
        }

        let delay = withState { pow(2.0, Double(self.connectionRetries)) }
        Task { [weak self] in
            print("ℹ️ Volcano: Reconnecting in \(Int(delay))s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.connectWithRetry()
        }
    }

    // MARK: - Binary Protocol

    private func sendFullClientRequest() {
        let payload: [String: Any] = [
            "user": ["uid": UUID().uuidString],
            "audio": [
                "format": "pcm",
                "rate": config.sampleRate,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": config.enableITN,
                "enable_punc": config.enablePunc,
                "enable_ddc": config.enableDDC,
                "show_utterances": true,
                "result_type": "partial"
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let frame = buildFrame(
            messageType: 0x1, // full request
            flags: 0x1,
            serialization: 0x1,
            compression: 0x0,
            sequence: reserveFrameSequence(),
            payload: jsonData
        )

        task?.send(.data(frame)) { error in
            if let error {
                print("⚠️ Volcano WS send full request error: \(error.localizedDescription)")
            }
        }
    }

    private func sendAudioFrame(data: Data, isLast: Bool, allowWhenStopping: Bool = false) {
        guard !data.isEmpty || isLast else { return }

        var taskToSend: URLSessionWebSocketTask?
        withState {
            if isStopping && !allowWhenStopping { return }
            taskToSend = task
            if taskToSend == nil && !isLast && !data.isEmpty {
                pendingAudioFrames.append(data)
            }
        }

        guard let taskToSend else { return }

        let flags: UInt8 = isLast ? 0x3 : 0x1
        let frame = buildFrame(
            messageType: 0x2,
            flags: flags,
            serialization: 0x0,
            compression: 0x0,
            sequence: reserveFrameSequence(),
            payload: data
        )

        taskToSend.send(.data(frame)) { error in
            if let error {
                print("⚠️ Volcano WS send audio error: \(error.localizedDescription)")
            }
        }
    }

    private func reserveFrameSequence() -> UInt32 {
        withState {
            defer { nextOutboundSequence &+= 1 }
            return nextOutboundSequence
        }
    }

    private func buildFrame(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        sequence: UInt32,
        payload: Data
    ) -> Data {
        let includeSequence = (flags & 0x1) != 0
        var frame = Data(capacity: 8 + payload.count + (includeSequence ? 4 : 0))
        frame.append(0x11)
        frame.append((messageType << 4) | (flags & 0x0F))
        frame.append((serialization << 4) | (compression & 0x0F))
        frame.append(0x00)

        if includeSequence {
            var sequenceBytes = sequence.bigEndian
            frame.append(Data(bytes: &sequenceBytes, count: 4))
        }

        var size = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))
        frame.append(payload)
        return frame
    }

    private func flushPendingAudio() {
        while true {
            let nextFrame: Data? = withState {
                guard !isStopping, task != nil, !pendingAudioFrames.isEmpty else {
                    return nil
                }
                return pendingAudioFrames.removeFirst()
            }

            guard let nextFrame else { return }
            sendAudioFrame(data: nextFrame, isLast: false)
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.withState { self.lastReceivedTime = Date() }

                switch message {
                case .data(let data):
                    self.handleServerFrame(data)
                case .string(let text):
                    print("⚠️ Volcano WS unexpected text: \(text.prefix(200))")
                    if let data = text.data(using: .utf8) {
                        self.handleServerFrame(data)
                    }
                @unknown default:
                    break
                }

                let isConnected = self.withState { self.isConnected }
                if isConnected {
                    self.receiveLoop()
                }

            case .failure(let error):
                if self.isStopping {
                    self.continuation?.finish()
                    return
                }
                print("⚠️ Volcano WS receive error: \(error.localizedDescription)")
                self.attemptReconnect()
            }
        }
    }

    private func handleServerFrame(_ data: Data) {
        guard data.count >= 4 else { return }
        let msgType = (data[1] >> 4) & 0x0F
        let flags = data[1] & 0x0F
        let compression = data[2] & 0x0F

        diagnosticsLog("rx frame bytes=\(data.count) msgType=0x\(String(msgType, radix: 16)) flags=0x\(String(flags, radix: 16)) compression=0x\(String(compression, radix: 16))")

        if msgType == 0xF {
            diagnosticsLog("rx frame classified=error")
            handleErrorFrame(data)
            return
        }

        // Some Volcano responses may arrive as raw JSON payloads. Parse them directly first.
        if let directResult = decodeDirectJsonPayload(from: data) {
            diagnosticsLog("parser path=direct-json textLen=\(directResult.text.count) isFinal=\(directResult.isFinal)")
            yieldServerResult(directResult)
            return
        }

        // Some responses include binary prefix or suffix around JSON payload.
        if let embeddedResult = decodeEmbeddedJsonPayload(from: data) {
            diagnosticsLog("parser path=embedded-json textLen=\(embeddedResult.text.count) isFinal=\(embeddedResult.isFinal)")
            yieldServerResult(embeddedResult)
            return
        }

        // Keep 0x9 for normal ASR result frames, but parse other types defensively.
        // Some endpoints emit useful result frames on variant message types.
        if data.count < 8 {
            diagnosticsLog("parser skipped: frame too short for payload decode")
            return
        }

        let headerSize = Int(data[0] & 0x0F) * 4

        guard let transcription = decodeFrameAsPayloadCandidates(data, headerSize: headerSize, flags: flags, compression: compression) else {
            diagnosticsLog("parser path=binary-payload failed; trying raw-json variants")
            tryToDecodeFrameAsRawJSON(data, reason: "payload parse failure")
            return
        }
        diagnosticsLog("parser path=binary-payload textLen=\(transcription.text.count) isFinal=\(transcription.isFinal)")
        yieldServerResult(transcription)
    }

    private func decodeDirectJsonPayload(from data: Data) -> TranscriptionResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseServerResult(from: json)
    }

    private func decodeEmbeddedJsonPayload(from data: Data) -> TranscriptionResult? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let candidates = embeddedJsonCandidates(from: text)
        for candidate in candidates {
            guard let jsonData = candidate.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
            if let result = parseServerResult(from: json) {
                return result
            }
        }

        return nil
    }

    private func embeddedJsonCandidates(from text: String) -> [String] {
        let bracePayload = extractDelimitedText(from: text, open: "{", close: "}")
        let bracketPayload = extractDelimitedText(from: text, open: "[", close: "]")

        var candidates: [String] = []
        if let payload = bracePayload {
            candidates.append(payload)
        }
        if let payload = bracketPayload {
            candidates.append(payload)
        }
        return candidates
    }

    private func extractDelimitedText(from text: String, open: String, close: String) -> String? {
        guard let start = text.firstIndex(of: Character(open)),
              let end = text.lastIndex(of: Character(close)),
              end >= start else {
            return nil
        }

        let candidate = String(text[start...end])
        return candidate
    }

    private func decodeFrameAsPayloadCandidates(
        _ data: Data,
        headerSize: Int,
        flags: UInt8,
        compression: UInt8
    ) -> TranscriptionResult? {
        let payloads = decodePayloadCandidates(data: data, headerSize: headerSize, flags: flags)
        diagnosticsLog("payload candidates count=\(payloads.count) headerSize=\(headerSize)")

        for (idx, payload) in payloads.enumerated() {
            var candidate = payload
            if compression == 0x1 {
                candidate = gunzip(candidate) ?? candidate
            }

            if let transcription = decodeVolcanoTranscript(from: candidate) {
                diagnosticsLog("payload candidate#\(idx) parsed textLen=\(transcription.text.count) isFinal=\(transcription.isFinal)")
                return transcription
            }
        }

        return nil
    }

    private func yieldServerResult(_ result: TranscriptionResult) {
        let priorPartial = withState { latestPartialResult }
        let priorText = priorPartial?.text
        let normalizedRaw = Self.normalizedStreamingResult(result, latestPartial: priorPartial)
        let sanitizedText = Self.sanitizeStreamingText(normalizedRaw.text, previous: priorText)
        let normalized = TranscriptionResult(
            text: sanitizedText,
            language: normalizedRaw.language,
            isFinal: normalizedRaw.isFinal
        )
        let trimmedNormalized = normalized.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedRaw.text != sanitizedText {
            diagnosticsLog("parser dedupe reduced textLen=\(normalizedRaw.text.count)->\(sanitizedText.count)")
        }

        if normalized.isFinal && trimmedNormalized.isEmpty {
            if !(priorText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                diagnosticsLog("received empty final packet, keep running partial for final fallback")
                return
            }
            diagnosticsLog("received empty final packet with no prior partial")
        }

        var shouldEmit = true
        let normalizedToken = Self.normalizedComparisonText(trimmedNormalized)
        withState {
            if normalized.isFinal {
                let latestFinalText = latestFinalResult?.text
                let latestPartialText = latestPartialResult?.text

                if let latestFinalText,
                   Self.normalizedComparisonText(latestFinalText) == normalizedToken {
                    shouldEmit = false
                } else if let latestPartialText,
                          Self.appearsRegression(normalizedToken, against: latestPartialText),
                          !trimmedNormalized.isEmpty {
                    // Same content as current partial but now flagged final; avoid duplicate emit.
                    shouldEmit = false
                } else if let latestFinalText,
                          Self.appearsRegression(normalizedToken, against: latestFinalText) {
                    shouldEmit = false
                }
                latestFinalResult = normalized
                return
            }

            if let latestPartialText = latestPartialResult?.text,
               Self.appearsRegression(normalizedToken, against: latestPartialText) {
                shouldEmit = false
                return
            }

            if !trimmedNormalized.isEmpty {
                latestPartialResult = normalized
            }
        }

        guard shouldEmit else {
            return
        }
        continuation?.yield(normalized)
    }

    private func tryToDecodeFrameAsRawJSON(_ data: Data, reason: String) {
        let candidates = buildVolcanoPayloadVariants(from: data)
        for payload in candidates {
            if payload == data { continue }
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let transcription = parseServerResult(from: json) {
                yieldServerResult(transcription)
                return
            }
        }
        if reason.count > 0 {
            print("⚠️ Volcano: frame decode skipped (\(reason)), bytes=\(data.count)")
        }
    }

    private func decodePayloadRange(data: Data, headerSize: Int, flags: UInt8) -> (start: Int, length: Int)? {
        func decodeSize(_ index: Int) -> Int? {
            guard index + 4 <= data.count else { return nil }
            return Int(UInt32(bigEndian: data.subdata(in: index..<(index + 4))
                .withUnsafeBytes { $0.load(as: UInt32.self) }))
        }

        // Newer layout: [header][seq][size][payload]
        if flags & 0x01 != 0 {
            let sizeIndex = headerSize + 4
            if let size = decodeSize(sizeIndex) {
                let start = sizeIndex + 4
                if start + size <= data.count {
                    return (start: start, length: size)
                }
            }
        }

        // Legacy layout: [header][size][seq][payload]
        if let size = decodeSize(headerSize) {
            let start = headerSize + 4 + ((flags & 0x01 != 0) ? 4 : 0)
            if start + size <= data.count {
                return (start: start, length: size)
            }
        }

        // Heuristic fallback for servers that place 32-bit size at offset 8 when header flags vary.
        if let size = decodeSize(headerSize + 8) {
            let start = headerSize + 12 + ((flags & 0x01 != 0) ? 4 : 0)
            if start + size <= data.count {
                return (start: start, length: size)
            }
        }

        return nil
    }

    private func decodePayloadCandidates(data: Data, headerSize: Int, flags: UInt8) -> [Data] {
        var payloads: [Data] = []

        for sizeIndex in decodePayloadSizeCandidateOffsets(headerSize: headerSize, flags: flags) {
            guard let payload = decodePayloadData(data: data, sizeIndex: sizeIndex) else {
                continue
            }
            if !payload.isEmpty {
                payloads.append(payload)
            }
        }

        return dedupePayloads(payloads)
    }

    private func decodePayloadSizeCandidateOffsets(headerSize: Int, flags: UInt8) -> Set<Int> {
        let hasSequence = (flags & 0x1) != 0
        var indexes: Set<Int> = [headerSize, headerSize + 4, headerSize + 8, headerSize + 12]
        if hasSequence {
            indexes.insert(headerSize + 1)
            indexes.insert(headerSize + 5)
        }
        return indexes.filter { $0 >= 0 }
    }

    private func decodePayloadData(data: Data, sizeIndex: Int) -> Data? {
        guard sizeIndex + 4 <= data.count else { return nil }
        let size = Int(UInt32(
            bigEndian: data.subdata(in: sizeIndex..<(sizeIndex + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
        ))
        guard size > 0, size < data.count else { return nil }

        let payloadStart = sizeIndex + 4
        let payloadEnd = payloadStart + size
        guard payloadEnd <= data.count else { return nil }
        return data.subdata(in: payloadStart..<payloadEnd)
    }

    private func dedupePayloads(_ payloads: [Data]) -> [Data] {
        var result: [Data] = []
        for payload in payloads {
            if !result.contains(payload) {
                result.append(payload)
            }
        }
        return result
    }

    private func decodeVolcanoTranscript(from data: Data) -> TranscriptionResult? {
        let candidates = buildVolcanoPayloadVariants(from: data)
        for payload in candidates {
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                continue
            }
            if let result = parseServerResult(from: json) {
                return result
            }
        }
        return nil
    }

    private func buildVolcanoPayloadVariants(from data: Data) -> [Data] {
        var candidates: [Data] = [data]
        if let raw = String(data: data, encoding: .utf8), let decoded = raw.data(using: .utf8), decoded != data {
            candidates.append(decoded)
        }
        return candidates
    }

    private func parseServerResult(from json: [String: Any]) -> TranscriptionResult? {
        let containers = volcanoCandidateContainers(from: json)
        var sawTerminalWithoutText = false

        for container in containers {
            let text = extractVolcanoText(from: container)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isFinal = resolveVolcanoFinalFlag(from: container)
            let hasTerminalSignal = resolveVolcanoTerminalFinalFlag(from: container)
            let finalSignals = resolveVolcanoFinalSignals(from: container)
            if let finalSignals {
                diagnosticsLog("parser final decision source=\(finalSignals) final=\(isFinal)")
            } else {
                diagnosticsLog("parser final decision source=none final=\(isFinal)")
            }

            if let text, !text.isEmpty {
                diagnosticsLog("parser result textLen=\(text.count) final=\(isFinal)")
                return TranscriptionResult(text: text, language: .unknown, isFinal: isFinal)
            }

            if hasTerminalSignal {
                sawTerminalWithoutText = true
                if let terminalSignals = resolveVolcanoTerminalSignals(from: container) {
                    diagnosticsLog("parser terminal container signals=\(terminalSignals)")
                }
            }
        }

        if sawTerminalWithoutText || resolveVolcanoTerminalFinalFlag(from: json) {
            diagnosticsLog("parser terminal packet without text")
            return TranscriptionResult(text: "", language: .unknown, isFinal: true)
        }

        return nil
    }

    private func volcanoCandidateContainers(from json: [String: Any]) -> [[String: Any]] {
        var containers: [[String: Any]] = []

        func appendContainer(_ value: [String: Any]?) {
            guard let value else { return }
            containers.append(value)
        }

        func appendAnyContainer(_ value: Any?) {
            if let dict = value as? [String: Any] {
                appendContainer(dict)
            } else if let list = value as? [[String: Any]] {
                list.forEach { appendContainer($0) }
            }
        }

        appendAnyContainer(json["result"])
        appendAnyContainer(json["results"])
        appendAnyContainer(json["data"])
        appendAnyContainer(json["output"])
        appendAnyContainer(json["payload"])
        appendAnyContainer(json["response"])
        appendAnyContainer(json["asr"])
        appendAnyContainer(json["event"])

        if let responseData = json["data"] as? [String: Any] {
            appendAnyContainer(responseData["output"])
            appendAnyContainer(responseData["result"])
        }

        if let textOnly = json["text"] as? String {
            containers.append(["text": textOnly])
        }

        appendContainer(json)
        return containers
    }

    private func extractVolcanoText(from result: [String: Any]) -> String? {
        if let text = result["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let alternatives = result["alternatives"] as? [[String: Any]],
           let first = alternatives.first,
           let text = first["transcript"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let words = result["words"] as? [[String: Any]], !words.isEmpty {
            let text = words.compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !text.isEmpty {
                return text
            }
        }
        if let utterances = result["utterances"] as? [[String: Any]], !utterances.isEmpty {
            let text = utterances.compactMap({ $0["text"] as? String })
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty })
                .joined(separator: " ")
            if !text.isEmpty {
                return text
            }
        }
        if let alternatives = result["result"] as? [String: Any],
           let alternativesText = extractVolcanoText(from: alternatives)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alternativesText.isEmpty {
            return alternativesText
        }
        if let response = result["response"] as? [String: Any],
           let responseText = extractVolcanoText(from: response)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !responseText.isEmpty {
            return responseText
        }
        if let data = result["data"] as? [String: Any],
           let dataText = extractVolcanoText(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dataText.isEmpty {
            return dataText
        }
        if let output = result["output"] as? [String: Any],
           let outputText = extractVolcanoText(from: output)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !outputText.isEmpty {
            return outputText
        }
        if let jsonText = recursiveTextPayload(from: result)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jsonText.isEmpty {
            return jsonText
        }
        return jsonTextFallback(from: result)
    }

    private func recursiveTextPayload(from value: Any, depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }

        if let valueDict = value as? [String: Any] {
            if let resultText = valueDict["transcript"] as? String,
               !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resultText
            }
            if let resultText = valueDict["text"] as? String,
               !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resultText
            }
            if let resultText = valueDict["result"] as? String,
               !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resultText
            }
            if let resultText = valueDict["msg"] as? String,
               !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return resultText
            }

            for (_, nested) in valueDict {
                if let nestedText = recursiveTextPayload(from: nested, depth: depth + 1),
                   !nestedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nestedText
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let nestedText = recursiveTextPayload(from: item, depth: depth + 1),
                   !nestedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nestedText
                }
            }
        }

        return nil
    }

    private func resolveVolcanoFinalFlag(from result: [String: Any]) -> Bool {
        if let final = result["is_final"] as? Bool { return final }
        if let final = result["final"] as? Bool { return final }
        if let final = result["definite"] as? Bool { return final }
        if let final = result["is_end"] as? Bool { return final }
        if let status = result["status"] as? String,
           status.caseInsensitiveCompare("final") == .orderedSame || status.caseInsensitiveCompare("finalized") == .orderedSame {
            return true
        }
        if let status = result["status"] as? String,
           status.caseInsensitiveCompare("completed") == .orderedSame ||
           status.caseInsensitiveCompare("ended") == .orderedSame {
            return true
        }
        if let status = result["event"] as? String,
           ["end", "final", "complete"].contains(where: { status.caseInsensitiveCompare($0) == .orderedSame }) {
            return true
        }
        if let utterances = result["utterances"] as? [[String: Any]], !utterances.isEmpty {
            return utterances.contains {
                ($0["definite"] as? Bool) == true || ($0["final"] as? Bool) == true || ($0["is_final"] as? Bool) == true
            }
        }
        return false
    }

    private func resolveVolcanoFinalSignals(from result: [String: Any]) -> String? {
        var signals: [String] = []

        if let value = result["is_final"] as? Bool {
            signals.append("is_final=\(value)")
        }
        if let value = result["final"] as? Bool {
            signals.append("final=\(value)")
        }
        if let value = result["definite"] as? Bool {
            signals.append("definite=\(value)")
        }
        if let value = result["is_end"] as? Bool {
            signals.append("is_end=\(value)")
        }
        if let status = result["status"] as? String {
            signals.append("status=\(status)")
        }
        if let event = result["event"] as? String {
            signals.append("event=\(event)")
        }

        guard !signals.isEmpty else { return nil }
        return signals.joined(separator: ",")
    }

    private func resolveVolcanoTerminalFinalFlag(from result: [String: Any]) -> Bool {
        if let isEnd = result["is_end"] as? Bool, isEnd { return true }
        if let event = result["event"] as? String,
           ["end", "final", "complete", "completed"].contains(where: { event.caseInsensitiveCompare($0) == .orderedSame }) {
            return true
        }
        if let status = result["status"] as? String,
           ["final", "finalized", "completed", "ended"].contains(where: { status.caseInsensitiveCompare($0) == .orderedSame }) {
            return true
        }
        return false
    }

    private func resolveVolcanoTerminalSignals(from result: [String: Any]) -> String? {
        var signals: [String] = []

        if let isEnd = result["is_end"] as? Bool, isEnd {
            signals.append("is_end=true")
        }
        if let event = result["event"] as? String {
            signals.append("event=\(event)")
        }
        if let status = result["status"] as? String {
            signals.append("status=\(status)")
        }

        guard !signals.isEmpty else { return nil }
        return signals.joined(separator: ",")
    }

    private func jsonTextFallback(from result: [String: Any]) -> String? {
        if let text = result["transcript"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let text = result["result"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    private func handleErrorFrame(_ data: Data) {
        guard data.count >= 12 else { return }

        let headerSize = Int(data[0] & 0x0F) * 4
        guard headerSize + 8 <= data.count else { return }
        let errorCode = UInt32(bigEndian: data.subdata(in: headerSize..<(headerSize + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self) })
        let msgSize = Int(UInt32(bigEndian: data.subdata(in: (headerSize + 4)..<(headerSize + 8))
            .withUnsafeBytes { $0.load(as: UInt32.self) }))

        let msgEnd = min(headerSize + 8 + msgSize, data.count)
        let errorMsg = String(data: data.subdata(in: (headerSize + 8)..<msgEnd), encoding: .utf8) ?? "Unknown"

        print("⚠️ Volcano WS server error \(errorCode): \(errorMsg)")
        continuation?.finish()
    }

    // MARK: - Gzip helpers

    private func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let sourceSize = data.count
        let destinationSize = sourceSize + 512
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourcePtr in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer,
                destinationSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                sourceSize,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    private func gunzip(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }

        let destinationSize = data.count * 10
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }

        let sourceData: Data
        if data.count > 10, data[0] == 0x1f, data[1] == 0x8b {
            sourceData = data.dropFirst(10)
        } else {
            sourceData = data
        }

        let decompressedSize = sourceData.withUnsafeBytes { sourcePtr in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                destinationSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                sourceData.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}
