import Foundation
import EchoCore

/// Service that manages voice input using EchoCore
/// Coordinates audio capture, speech recognition, and LLM correction
@MainActor
public final class VoiceInputService: ObservableObject {
    // MARK: - Published State

    @Published public private(set) var isRecording = false
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var isCorrecting = false
    @Published public private(set) var isStreamingSessionActive = false
    @Published public private(set) var partialTranscription = ""
    @Published public private(set) var finalTranscription = ""
    public private(set) var bestStreamingPartialTranscription = ""
    @Published public private(set) var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published public private(set) var errorMessage: String?

    // MARK: - Dependencies

    private var audioCaptureService: AudioCaptureService
    private let settings: MacAppSettings
    private let keyStore: SecureKeyStore
    private let contextStore: ContextMemoryStore
    private let recordingStore: RecordingStore
    private let authSession = EchoAuthSession.shared

    // Audio buffer for transcription
    private var audioChunks: [AudioChunk] = []
    private var audioUpdateTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var streamingResultTask: Task<Void, Never>?
    private var activeProvider: (any ASRProvider)?
    private var isStreamingSession = false
    private var streamingStartDate: Date?
    private var streamingFirstPartialMs: Int?
    private var streamingFirstFinalMs: Int?
    private var streamMode: String = "batch"
    private var currentTraceId: String?
    private var didLogFirstCaptureChunk = false

    // MARK: - Initialization

    public init(settings: MacAppSettings = MacAppSettings()) {
        self.settings = settings
        self.audioCaptureService = AudioCaptureService()
        self.keyStore = SecureKeyStore()
        self.contextStore = ContextMemoryStore()
        self.recordingStore = RecordingStore.shared

        Task {
            await contextStore.load()
        }
    }

    // MARK: - Recording Control

    /// Start voice recording
    public func startRecording() async throws {
        guard !isRecording else { return }

        errorMessage = nil
        audioChunks = []
        partialTranscription = ""
        bestStreamingPartialTranscription = ""
        streamingFirstPartialMs = nil
        streamingFirstFinalMs = nil
        streamingStartDate = nil
        didLogFirstCaptureChunk = false

        let traceId = UUID().uuidString.lowercased()
        currentTraceId = traceId

        do {
            // Recreate audio capture service per session to avoid stale engine state
            audioCaptureService = AudioCaptureService()

            // Request permissions if needed
            let micPermission = await audioCaptureService.requestPermission()
            guard micPermission else {
                throw VoiceInputError.permissionDenied("Microphone access denied")
            }

            // Resolve ASR provider
            guard let provider = resolveASRProvider() else {
                throw VoiceInputError.noASRProvider
            }
            activeProvider = provider
            isStreamingSession = settings.asrMode == .stream && provider.supportsStreaming
            isStreamingSessionActive = isStreamingSession
            streamMode = isStreamingSession ? "stream" : "batch"
            streamingStartDate = Date()
            streamingFirstPartialMs = nil
            streamingFirstFinalMs = nil
            logStage("capture", traceId: traceId, message: "start mode=\(streamMode) provider=\(provider.id)")

            if isStreamingSession {
                startStreamingResults(provider: provider)
            }

            // Start audio capture
            try audioCaptureService.startRecording()

            // Start collecting audio chunks
            startAudioCollection()

            // Start audio level monitoring
            startAudioLevelMonitoring()

            isRecording = true
            print("🎤 Recording started")
        } catch {
            activeProvider = nil
            currentTraceId = nil
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            throw error
        }
    }

    /// Stop recording and begin transcription
    public func stopRecording() async throws -> String {
        guard isRecording else { return "" }

        let traceId = currentTraceId ?? UUID().uuidString.lowercased()
        currentTraceId = traceId

        isRecording = false
        // Stop audio capture first so we can flush any in-flight buffers
        audioCaptureService.stopRecording()
        // Give the tap a brief moment to deliver any final chunks
        for _ in 0..<4 where audioChunks.isEmpty {
            try? await Task.sleep(for: .milliseconds(80))
        }
        stopAudioLevelMonitoring()
        await stopAudioCollectionGracefully()

        print("🎤 Recording stopped, starting transcription...")
        logStage("capture", traceId: traceId, message: "stop chunks=\(audioChunks.count)")

        // Transcribe the audio
        isTranscribing = true
        defer { isTranscribing = false }

        var providerForStorage: (any ASRProvider)?
        var rawTranscript: String?
        var finalTranscriptValue: String?
        var correctionProviderId: String? = nil
        var totalStart = Date()
        let sessionMode = streamMode
        let streamSessionActive = isStreamingSession
        let firstPartialMs = streamingFirstPartialMs ?? -1
        let firstFinalMs = streamingFirstFinalMs ?? -1
        var fallbackUsed = false
        var asrLatencyMs: Int?

        do {
            // Resolve ASR provider
            let provider = activeProvider ?? resolveASRProvider()
            activeProvider = nil
            guard let provider else {
                throw VoiceInputError.noASRProvider
            }
            totalStart = Date()
            providerForStorage = provider
            let fallbackProvider = fallbackASRProvider(for: provider.id)
            let transcription: TranscriptionResult

            guard !audioChunks.isEmpty else {
                throw VoiceInputError.noAudioData
            }

            let combinedData = audioChunks.reduce(Data()) { $0 + $1.data }
            let totalDuration = audioChunks.reduce(0) { $0 + $1.duration }
            let format = audioChunks.first?.format ?? .default
            let combinedChunk = AudioChunk(
                data: combinedData,
                format: format,
                duration: totalDuration
            )

            if isStreamingSession {
                let asrStart = Date()
                let finalResult = try await provider.stopStreaming()
                stopStreamingResults()

                let accumulatedText = partialTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
                logStage("stream", traceId: traceId, message: "stop partial_len=\(accumulatedText.count)")
                let bestPartialText = bestStreamingPartialTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
                let strongestPartial = bestPartialText.count >= accumulatedText.count ? bestPartialText : accumulatedText
                let merged = mergedStreamingText(finalText: finalResult?.text, accumulatedText: strongestPartial)
                var mergedText = merged.trimmingCharacters(in: .whitespacesAndNewlines)

                if shouldPreferStreamingPartial(finalText: mergedText, accumulatedText: strongestPartial) {
                    DiagnosticsState.shared.log(
                        "Replacing final with strongest partial (final=\(mergedText.count), partial=\(strongestPartial.count))"
                    )
                    mergedText = strongestPartial
                }

                // Deepgram commonly emits cumulative partials but shorter final utterance chunks.
                // When we have a clearly richer accumulated partial transcript, prefer it.
                if strongestPartial.count >= 12 && strongestPartial.count >= mergedText.count + 6 {
                    DiagnosticsState.shared.log(
                        "Streaming final shorter than accumulated partial, preferring accumulated (merged=\(mergedText.count), partial=\(strongestPartial.count))"
                    )
                    mergedText = strongestPartial
                }

                logStage("merge", traceId: traceId, message: "stream merged_len=\(mergedText.count) partial_len=\(strongestPartial.count)")

                if !mergedText.isEmpty && !shouldFallbackToBatchFromStreaming(finalText: mergedText, accumulatedText: strongestPartial, audioDuration: totalDuration) {
                    transcription = TranscriptionResult(text: mergedText, language: finalResult?.language ?? .unknown, isFinal: true)
                    asrLatencyMs = Int(Date().timeIntervalSince(asrStart) * 1000)
                } else {
                    DiagnosticsState.shared.log(
                        "Streaming final weak -> fallback batch transcribe (duration=\(String(format: "%.2f", totalDuration))s)"
                    )
                    logStage("merge", traceId: traceId, message: "fallback_to_batch duration_s=\(String(format: "%.2f", totalDuration))")
                    let fallback = try await transcribeAudioWithFallback(
                        primaryProvider: provider,
                        fallbackProvider: fallbackProvider,
                        audio: combinedChunk
                    )
                    transcription = fallback.result
                    providerForStorage = fallback.provider
                    if fallback.provider.id != provider.id {
                        fallbackUsed = true
                    }
                    asrLatencyMs = Int(Date().timeIntervalSince(asrStart) * 1000)
                }
            } else {
                DiagnosticsState.shared.log(
                    "Audio captured: chunks=\(audioChunks.count), bytes=\(combinedData.count), duration=\(String(format: "%.2f", totalDuration))s"
                )

                let asrStart = Date()
                let batch = try await transcribeAudioWithFallback(
                    primaryProvider: provider,
                    fallbackProvider: fallbackProvider,
                    audio: combinedChunk
                )
                transcription = batch.result
                providerForStorage = batch.provider
                if batch.provider.id != provider.id {
                    fallbackUsed = true
                }
                logStage("merge", traceId: traceId, message: "batch transcript_len=\(transcription.text.count)")
                asrLatencyMs = Int(Date().timeIntervalSince(asrStart) * 1000)
            }

            let resolvedAsrLatencyMs = asrLatencyMs ?? 0

            rawTranscript = transcription.text
            var result = transcription.text

            // Apply LLM correction if enabled and provider is available
            var correctionLatencyMs: Int? = nil
            if settings.correctionEnabled,
               let correctionProvider = resolveCorrectionProvider() {
                correctionProviderId = correctionProvider.id
                isCorrecting = true
                defer { isCorrecting = false }

                let correctionStart = Date()
                do {
                    // Always include the shared on-device dictionary in the prompt context.
                    let dictTerms = await EchoDictionaryStore.shared.all().map(\.term)
                    let mergedTerms = Array(Set(dictTerms + settings.customTerms))
                    await contextStore.updateUserTerms(mergedTerms)

                    let context = await contextStore.currentContext()
                    let pipeline = CorrectionPipeline(provider: correctionProvider)
                    let correction = try await pipeline.process(
                        transcription: transcription,
                        context: context,
                        options: settings.autoEditOptions
                    )
                    result = correction.correctedText

                    if correction.wasModified {
                        let candidates = DictionaryAutoAdder.candidates(
                            original: correction.originalText,
                            corrected: correction.correctedText
                        )
                        await EchoDictionaryStore.shared.add(terms: candidates, source: .autoAdded)
                    }
                } catch {
                    print("⚠️ Correction failed, using raw transcription: \(error)")
                }
                correctionLatencyMs = Int(Date().timeIntervalSince(correctionStart) * 1000)
            }

            await contextStore.addTranscription(result)
            let wordCount = result.split { $0.isWhitespace }.count
            if wordCount > 0 {
                settings.addWordsTranscribed(wordCount)
            } else {
                settings.addWordsTranscribed(result.count)
            }
            finalTranscription = result
            finalTranscriptValue = result
            logStage("ui", traceId: traceId, message: "final_text_len=\(result.count)")

            let totalLatencyMs = Int(Date().timeIntervalSince(totalStart) * 1000)
            let combinedDataForSave = audioChunks.reduce(Data()) { $0 + $1.data }
            let totalDurationForSave = audioChunks.reduce(0) { $0 + $1.duration }
            let formatForSave = audioChunks.first?.format ?? .default
            let recordingChunk = AudioChunk(
                data: combinedDataForSave,
                format: formatForSave,
                duration: totalDurationForSave
            )

            logStage("store", traceId: traceId, message: "save status=success mode=\(sessionMode) fallback=\(fallbackUsed)")
            await recordingStore.saveRecording(
                audio: recordingChunk,
                asrProviderId: providerForStorage?.id ?? provider.id,
                asrProviderName: providerForStorage?.displayName ?? provider.displayName,
                correctionProviderId: correctionProviderId,
                transcriptRaw: rawTranscript,
                transcriptFinal: finalTranscriptValue,
                error: nil,
                userId: authSession.userId ?? settings.currentUserId,
                asrLatencyMs: resolvedAsrLatencyMs,
                correctionLatencyMs: correctionLatencyMs,
                totalLatencyMs: totalLatencyMs,
                streamMode: sessionMode,
                firstPartialMs: firstPartialMs,
                firstFinalMs: firstFinalMs,
                fallbackUsed: fallbackUsed,
                errorCode: "none",
                traceId: traceId
            )

            let autoEditLatencyText = correctionLatencyMs.map(String.init) ?? "-"
            DiagnosticsState.shared.log(
                "Latency(ms): asr=\(resolvedAsrLatencyMs) autoEdit=\(autoEditLatencyText) total=\(totalLatencyMs)"
            )

            currentTraceId = nil
            return result
        } catch {
            if isStreamingSession, let provider = providerForStorage {
                try? await provider.stopStreaming()
            }
            stopStreamingResults()

            let errorString = error.localizedDescription
            if !audioChunks.isEmpty {
                let combinedData = audioChunks.reduce(Data()) { $0 + $1.data }
                let totalDuration = audioChunks.reduce(0) { $0 + $1.duration }
                let format = audioChunks.first?.format ?? .default
                let combinedChunk = AudioChunk(
                    data: combinedData,
                    format: format,
                    duration: totalDuration
                )

                let fallbackTarget = providerForStorage ?? resolveASRProvider()

                if let fallbackTarget {
                    let fallbackProvider = fallbackASRProvider(for: fallbackTarget.id)
                    do {
                        let recovered = try await transcribeAudioWithFallback(
                            primaryProvider: fallbackTarget,
                            fallbackProvider: fallbackProvider,
                            audio: combinedChunk
                        )

                        let recoveredText = recovered.result.text
                        rawTranscript = recoveredText
                        finalTranscriptValue = recoveredText
                        fallbackUsed = fallbackUsed || (recovered.provider.id != fallbackTarget.id)
                        isCorrecting = false
                        if !recoveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await contextStore.addTranscription(recoveredText)
                        }
                        let recoveredMode = recovered.provider.id == (providerForStorage?.id ?? recovered.provider.id) ? "stream-recovered" : "batch-fallback"
                        logStage("store", traceId: traceId, message: "save status=recovered mode=\(recoveredMode) fallback=\(fallbackUsed)")
                        await recordingStore.saveRecording(
                            audio: combinedChunk,
                            asrProviderId: recovered.provider.id,
                            asrProviderName: recovered.provider.displayName,
                            correctionProviderId: correctionProviderId,
                            transcriptRaw: rawTranscript,
                            transcriptFinal: finalTranscriptValue,
                            error: nil,
                            userId: authSession.userId ?? settings.currentUserId,
                            asrLatencyMs: asrLatencyMs ?? 0,
                            correctionLatencyMs: nil,
                            totalLatencyMs: Int(Date().timeIntervalSince(totalStart) * 1000),
                            streamMode: recoveredMode,
                            firstPartialMs: firstPartialMs,
                            firstFinalMs: firstFinalMs,
                            fallbackUsed: fallbackUsed,
                            errorCode: "none",
                            traceId: traceId
                        )
                        finalTranscription = recoveredText
                        currentTraceId = nil
                        return recoveredText
                    } catch {
                        // Keep the original error path if fallback recovery fails.
                    }
                }

                let fallbackProviderId = fallbackTarget?.id ?? providerForStorage?.id ?? "openai_whisper"
                let fallbackProviderName = fallbackTarget?.displayName ?? providerForStorage?.displayName ?? "OpenAI Whisper"
                logStage("store", traceId: traceId, message: "save status=error mode=\(sessionMode) fallback=\(fallbackUsed || streamSessionActive)")
                await recordingStore.saveRecording(
                    audio: combinedChunk,
                    asrProviderId: fallbackTarget?.id ?? fallbackProviderId,
                    asrProviderName: fallbackTarget?.displayName ?? fallbackProviderName,
                    correctionProviderId: correctionProviderId,
                    transcriptRaw: rawTranscript,
                    transcriptFinal: finalTranscriptValue,
                    error: errorString,
                    userId: authSession.userId ?? settings.currentUserId,
                    streamMode: sessionMode,
                    firstPartialMs: firstPartialMs,
                    firstFinalMs: firstFinalMs,
                    fallbackUsed: fallbackUsed || streamSessionActive,
                    errorCode: "\(type(of: error)):\(errorCodeValue(for: error))",
                    traceId: traceId
                )
            }
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            currentTraceId = nil
            throw error
        }
    }

    /// Cancel recording without transcription
    public func cancelRecording() {
        guard isRecording else { return }

        isRecording = false
        if isStreamingSession, let provider = activeProvider {
            Task { try? await provider.stopStreaming() }
        }
        activeProvider = nil
        stopStreamingResults()
        stopAudioLevelMonitoring()
        Task { await stopAudioCollectionGracefully() }
        audioCaptureService.stopRecording()
        audioChunks = []
        partialTranscription = ""
        bestStreamingPartialTranscription = ""

        logStage("capture", traceId: currentTraceId, message: "cancel")
        currentTraceId = nil
        print("🎤 Recording cancelled")
    }

    // MARK: - Audio Collection

    private func startAudioCollection() {
        recordingTask = Task {
            for await chunk in audioCaptureService.audioChunks {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.audioChunks.append(chunk)
                    if !self.didLogFirstCaptureChunk {
                        self.didLogFirstCaptureChunk = true
                        self.logStage("capture", traceId: self.currentTraceId, message: "first_chunk bytes=\(chunk.data.count)")
                    }
                }

                if isStreamingSession, let provider = activeProvider {
                    let maxFeedRetries = 12
                    var sent = false

                    for attempt in 0..<maxFeedRetries where !sent {
                        do {
                            try await provider.feedAudio(chunk)
                            sent = true
                        } catch {
                            if attempt + 1 >= maxFeedRetries {
                                DiagnosticsState.shared.log("Streaming feed error: \(error.localizedDescription)")
                                self.logStage("stream", traceId: self.currentTraceId, message: "feed_error=\(errorCodeValue(for: error))")
                                break
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                }
            }
        }
    }

    private func stopAudioCollection() {
        recordingTask?.cancel()
        recordingTask = nil
    }

    private func stopAudioCollectionGracefully() async {
        let task = recordingTask
        recordingTask = nil
        task?.cancel()
        if let task {
            _ = await task.result
        }
    }

    // MARK: - Audio Level Monitoring
    private var smoothedLevel: CGFloat = 0

    private func startAudioLevelMonitoring() {
        audioUpdateTask = Task {
            while !Task.isCancelled && isRecording {
                // Calculate audio level from recent chunks
                let level = calculateCurrentAudioLevel()
                updateAudioLevels(with: level)

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopAudioLevelMonitoring() {
        audioUpdateTask?.cancel()
        audioUpdateTask = nil
        smoothedLevel = 0
        audioLevels = Array(repeating: 0, count: 30)
    }

    private func calculateCurrentAudioLevel() -> CGFloat {
        // Get the most recent audio chunk
        guard let lastChunk = audioChunks.last else { return 0 }

        // Calculate RMS level from the audio data
        let samples = lastChunk.data.withUnsafeBytes { buffer -> [Int16] in
            Array(buffer.bindMemory(to: Int16.self))
        }

        guard !samples.isEmpty else { return 0 }

        // Calculate RMS
        let sumOfSquares = samples.reduce(0.0) { sum, sample in
            let floatSample = Double(sample) / Double(Int16.max)
            return sum + floatSample * floatSample
        }
        let rms = sqrt(sumOfSquares / Double(samples.count))

        // Convert to 0-1 range with some scaling
        return CGFloat(min(1.0, rms * 3.0))
    }

    private func updateAudioLevels(with newLevel: CGFloat) {
        let alpha: CGFloat = 0.22
        smoothedLevel = (smoothedLevel * (1 - alpha)) + (newLevel * alpha)
        var levels = audioLevels
        levels.removeFirst()
        levels.append(smoothedLevel)
        audioLevels = levels
    }

    private func startStreamingResults(provider: any ASRProvider) {
        let stream = provider.startStreaming()
        streamingResultTask = Task {
            for await result in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    if let startDate = self.streamingStartDate {
                        if self.streamingFirstPartialMs == nil {
                            self.streamingFirstPartialMs = Int(Date().timeIntervalSince(startDate) * 1000)
                            self.logStage("stream", traceId: self.currentTraceId, message: "first_partial_ms=\(self.streamingFirstPartialMs ?? -1)")
                        }
                        if result.isFinal, self.streamingFirstFinalMs == nil {
                            self.streamingFirstFinalMs = Int(Date().timeIntervalSince(startDate) * 1000)
                            self.logStage("stream", traceId: self.currentTraceId, message: "first_final_ms=\(self.streamingFirstFinalMs ?? -1)")
                        }
                    }
                    let mergedPartial = self.mergeStreamingText(result.text, into: self.partialTranscription)
                    self.partialTranscription = mergedPartial

                    if mergedPartial.count >= self.bestStreamingPartialTranscription.count {
                        self.bestStreamingPartialTranscription = mergedPartial
                    }

                    if result.isFinal {
                        self.finalTranscription = result.text
                    }
                }
            }
        }
    }

    private func stopStreamingResults() {
        if isStreamingSession {
            logStage("stream", traceId: currentTraceId, message: "result_stream_closed")
        }
        streamingResultTask?.cancel()
        streamingResultTask = nil
        isStreamingSession = false
        isStreamingSessionActive = false
        streamingStartDate = nil
        streamMode = "batch"
    }

    private func fallbackASRProvider(for providerId: String) -> (any ASRProvider)? {
        if providerId == "openai_whisper" {
            return nil
        }

        let fallback = OpenAIWhisperProvider(
            keyStore: keyStore,
            language: whisperLanguageCode(from: settings.asrLanguage),
            apiKey: try? keyStore.retrieve(for: "openai_whisper"),
            model: settings.openAITranscriptionModel
        )
        guard fallback.isAvailable else {
            return nil
        }
        return fallback
    }

    private func transcribeAudioWithFallback(
        primaryProvider: any ASRProvider,
        fallbackProvider: (any ASRProvider)?,
        audio: AudioChunk
    ) async throws -> (provider: any ASRProvider, result: TranscriptionResult) {
        do {
            let result = try await primaryProvider.transcribe(audio: audio)
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (provider: primaryProvider, result: result)
            }
            throw ASRError.transcriptionFailed("Primary provider returned empty transcription")
        } catch {
            if let fallbackProvider {
                let result = try await fallbackProvider.transcribe(audio: audio)
                let fallbackText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fallbackText.isEmpty else {
                    throw ASRError.transcriptionFailed("Fallback provider returned empty transcription")
                }
                return (provider: fallbackProvider, result: result)
            }
            throw error
        }
    }

    private func mergedStreamingText(finalText: String?, accumulatedText: String) -> String {
        let final = finalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let accumulated = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if final.isEmpty { return accumulated }
        if accumulated.isEmpty { return final }
        return mergeStreamingText(final, into: accumulated)
    }

    private func mergeStreamingText(_ incomingText: String, into accumulatedText: String) -> String {
        let incoming = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let accumulated = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if incoming.isEmpty { return accumulated }
        if accumulated.isEmpty { return incoming }
        if incoming == accumulated { return accumulated }
        if incoming.hasPrefix(accumulated) { return incoming }
        if accumulated.hasSuffix(incoming) { return accumulated }

        let overlap = longestSuffixPrefixOverlap(accumulated, incoming)
        if overlap > 0 {
            let suffix = incoming.dropFirst(overlap)
            if suffix.isEmpty { return accumulated }
            if CharacterSet.alphanumerics.contains(incoming.unicodeScalars.first!),
               CharacterSet.alphanumerics.contains(accumulated.unicodeScalars.last!) {
                return accumulated + String(suffix)
            }
            return "\(accumulated) \(String(suffix))"
        }

        if shouldInsertSpace(between: accumulated, and: incoming) {
            return "\(accumulated) \(incoming)"
        }

        return accumulated + incoming
    }

    private func shouldInsertSpace(between accumulated: String, and incoming: String) -> Bool {
        guard let leftLast = accumulated.unicodeScalars.last,
              let rightFirst = incoming.unicodeScalars.first else {
            return false
        }

        let leftIsWordLike = CharacterSet.alphanumerics.contains(leftLast)
        let rightIsWordLike = CharacterSet.alphanumerics.contains(rightFirst)
        let rightIsPunctuation = CharacterSet.punctuationCharacters.contains(rightFirst)
        return leftIsWordLike && rightIsWordLike && !rightIsPunctuation
    }

    private func longestSuffixPrefixOverlap(_ accumulated: String, _ incoming: String) -> Int {
        let leftChars = Array(accumulated)
        let rightChars = Array(incoming)
        let maxLength = min(leftChars.count, rightChars.count)

        if maxLength == 0 { return 0 }

        for length in stride(from: maxLength, through: 1, by: -1) {
            let left = String(leftChars[(leftChars.count - length)..<leftChars.count])
            let right = String(rightChars[..<length])
            if left == right {
                return length
            }
        }
        return 0
    }

    private func shouldFallbackToBatchFromStreaming(finalText: String, accumulatedText: String, audioDuration: TimeInterval) -> Bool {
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            return true
        }

        let accumulated = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.count < 3 {
            return true
        }

        if accumulated.count >= 8 && final.count < max(3, accumulated.count / 2) {
            return true
        }
        if shouldPreferStreamingPartial(finalText: final, accumulatedText: accumulated) {
            return true
        }

        // Heuristic: for longer utterances, a very short final is usually a weak stream tail.
        if audioDuration >= 2.2 {
            let wordCount = final.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            if final.count < 8 || wordCount <= 1 {
                return true
            }
        }

        return false
    }

    private func shouldPreferStreamingPartial(finalText: String, accumulatedText: String) -> Bool {
        let finalTrimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let accumulatedTrimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalTrimmed.isEmpty, !accumulatedTrimmed.isEmpty else { return false }
        if finalTrimmed.count >= accumulatedTrimmed.count { return false }
        if accumulatedTrimmed.count >= 12 && finalTrimmed.count <= accumulatedTrimmed.count - 6 { return true }
        if accumulatedTrimmed.count >= 10 && finalTrimmed.count <= 3 { return true }
        if Double(finalTrimmed.count) <= Double(accumulatedTrimmed.count) * 0.55 { return true }
        return false
    }

    private func errorCodeValue(for error: Error) -> String {
        if let nsError = error as NSError? {
            return "\(nsError.domain):\(nsError.code)"
        }
        return String(describing: type(of: error))
    }

    private func logStage(_ stage: String, traceId: String?, message: String) {
        let candidate = traceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTraceId = candidate.flatMap { $0.isEmpty ? nil : $0 } ?? "missing-trace"
        DiagnosticsState.shared.log("[trace:\(resolvedTraceId)] \(stage): \(message)")
    }

    // MARK: - Configuration

    public func updateSettings() {
        // Re-initialize providers if needed
    }

    // MARK: - Provider Resolution

    private func resolveASRProvider() -> (any ASRProvider)? {
        let selectedId = settings.selectedASRProvider

        if selectedId != "openai_whisper", let selectedProvider = asrProvider(for: selectedId), selectedProvider.isAvailable {
            return selectedProvider
        }

        if let fallbackProvider = resolveOpenAIProvider(), fallbackProvider.isAvailable {
            return fallbackProvider
        }

        return nil
    }

    private func asrProvider(for providerId: String) -> (any ASRProvider)? {
        switch providerId {
        case "volcano":
            let volcanoOverrides = resolveVolcanoOverrides()
            let provider = VolcanoASRProvider(
                keyStore: keyStore,
                appId: volcanoOverrides.appId,
                accessKey: volcanoOverrides.accessKey
            )
            return provider.isAvailable ? provider : nil
        case "ark_asr":
            let provider = ArkASRProvider(
                keyStore: keyStore,
                language: whisperLanguageCode(from: settings.asrLanguage)
            )
            return provider.isAvailable ? provider : nil
        case "deepgram":
            let selectedModel = settings.deepgramModel
            // Prefer explicit language hint for Chinese to avoid English-like gibberish in zh speech.
            // For English/mixed we still allow auto-detect on nova-3.
            let preferredLanguage = deepgramLanguageCode(from: settings.asrLanguage)
            let resolvedLanguage: String?
            if selectedModel == "nova-3" {
                resolvedLanguage = (settings.asrLanguage == "zh-CN" || settings.asrLanguage == "zh-TW") ? preferredLanguage : nil
            } else {
                resolvedLanguage = preferredLanguage
            }
            let provider = DeepgramASRProvider(
                keyStore: keyStore,
                apiKey: resolveProviderKey(
                    primarySource: try? keyStore.retrieve(for: "deepgram"),
                    fallbackSource: readTrimmedString(from: NSHomeDirectory() + "/.deepgram_key"),
                    providerLabel: "Deepgram"
                ),
                model: selectedModel,
                language: resolvedLanguage
            )
            return provider.isAvailable ? provider : nil
        case "aliyun":
            guard let appKey = try? keyStore.retrieve(for: "aliyun_app_key"),
                  let token = try? keyStore.retrieve(for: "aliyun_token"),
                  !appKey.isEmpty,
                  !token.isEmpty else {
                return nil
            }
            return AliyunASRProvider(appKey: appKey, token: token)
        default:
            return resolveOpenAIProvider()
        }
    }

    private func resolveOpenAIProvider() -> (any ASRProvider)? {
        guard let apiKey = try? keyStore.retrieve(for: "openai_whisper"),
              !apiKey.isEmpty else {
            return nil
        }
        return OpenAIWhisperProvider(
            keyStore: keyStore,
            language: whisperLanguageCode(from: settings.asrLanguage),
            apiKey: apiKey,
            model: settings.openAITranscriptionModel
        )
    }

    private func deepgramModelHint(from inputMode: String) -> String {
        switch inputMode {
        case "pinyin":
            return "nova-2"
        default:
            return settings.deepgramModel
        }
    }

    private func deepgramLanguageHint(from inputMode: String) -> String? {
        switch inputMode {
        case "zh-cn":
            return "zh-CN"
        case "zh-tw":
            return "zh-TW"
        default:
            return nil
        }
    }

    private func whisperLanguageCode(from setting: String) -> String? {
        switch setting {
        case "en-US":
            return "en"
        case "zh-CN", "zh-TW":
            return "zh"
        case "ja-JP":
            return "ja"
        case "ko-KR":
            return "ko"
        default:
            return nil
        }
    }

    private func deepgramLanguageCode(from setting: String) -> String? {
        // Deepgram uses BCP-47-ish / short codes depending on model.
        // Keep it conservative.
        switch setting {
        case "en-US":
            return "en"
        case "zh-CN":
            return "zh-CN"
        case "zh-TW":
            return "zh-TW"
        default:
            return nil
        }
    }

    private func resolveVolcanoOverrides() -> (appId: String?, accessKey: String?) {
        let appIdPath = NSHomeDirectory() + "/.volcano_app_id"
        let tokenPath = NSHomeDirectory() + "/.volcano_token"

        let keychainAccessKey = try? keyStore.retrieve(for: "volcano_access_key")
        let keychainAppId = try? keyStore.retrieve(for: "volcano_app_id")
        let appIdFromFile = readTrimmedString(from: appIdPath)
        let accessKeyFromFile = readTrimmedString(from: tokenPath)
        let keychainAccess = keychainAccessKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keychainAppIdTrimmed = keychainAppId?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let access = keychainAccess, !access.isEmpty {
            if let appId = keychainAppIdTrimmed, !appId.isEmpty {
                return (appId: appId, accessKey: access)
            }
            if let appId = appIdFromFile, !appId.isEmpty {
                return (appId: appId, accessKey: access)
            }
            DiagnosticsState.shared.log("Volcano: using keychain access key with fallback appId")
            return (appId: "6490217589", accessKey: access)
        }

        if let access = accessKeyFromFile, !access.isEmpty {
            DiagnosticsState.shared.log("Volcano: using fallback file credentials")
            return (appId: appIdFromFile ?? "6490217589", accessKey: access)
        }

        return (nil, nil)
    }

    private func resolveProviderKey(
        primarySource: String?,
        fallbackSource: String?,
        providerLabel: String
    ) -> String? {
        let primary = primarySource?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let primary, !primary.isEmpty {
            return primary
        }

        let fallback = fallbackSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty {
            DiagnosticsState.shared.log("\(providerLabel): key fallback to local file source")
            return fallback
        }

        return nil
    }

    private func readTrimmedString(from path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func resolveCorrectionProvider() -> (any CorrectionProvider)? {
        let provider: any CorrectionProvider
        switch settings.selectedCorrectionProvider {
        case "openai_gpt":
            provider = OpenAICorrectionProvider(
                keyStore: keyStore,
                apiKey: try? keyStore.retrieve(for: "openai_gpt")
            )
        case "claude":
            provider = ClaudeCorrectionProvider(keyStore: keyStore)
        case "doubao":
            provider = DoubaoCorrectionProvider(keyStore: keyStore)
        case "qwen":
            provider = QwenCorrectionProvider(keyStore: keyStore)
        default:
            return nil
        }

        return provider.isAvailable ? provider : nil
    }
}

// MARK: - Errors

public enum VoiceInputError: LocalizedError {
    case permissionDenied(String)
    case noASRProvider
    case recordingFailed
    case transcriptionFailed
    case noAudioData

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let reason):
            return "Permission denied: \(reason)"
        case .noASRProvider:
            return "ASR provider is not configured. Add your API credentials in Settings."
        case .recordingFailed:
            return "Failed to record audio"
        case .transcriptionFailed:
            return "Failed to transcribe audio"
        case .noAudioData:
            return "No audio data recorded"
        }
    }
}
