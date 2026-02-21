import Speech
import SwiftUI
import EchoCore
import EchoUI

struct VoiceRecordingView: View {
    let startForKeyboard: Bool

    @StateObject private var viewModel = VoiceRecordingViewModel()
    @State private var textInput: String = ""
    @State private var lastCommittedText: String = ""
    @State private var livePrefixText: String = ""
    @State private var showSettings = false
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(startForKeyboard: Bool = false) {
        self.startForKeyboard = startForKeyboard
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $textInput)
                    .font(.system(size: 18))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(EchoTheme.keyboardSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(EchoTheme.pillStroke, lineWidth: 1)
                    )
                    .frame(minHeight: 180)
                    .focused($isFocused)
                    .onTapGesture { isFocused = true }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .navigationTitle("Echo")
            .toolbar {
                if !startForKeyboard {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    KeyboardAccessoryBar(
                        isRecording: viewModel.isRecording,
                        isProcessing: viewModel.isProcessing,
                        audioLevels: viewModel.audioLevels,
                        tipText: viewModel.tipText,
                        onToggleRecording: {
                            Task { await viewModel.toggleRecording() }
                        },
                        onOpenSettings: {
                            showSettings = true
                        },
                        onDismissKeyboard: {
                            isFocused = false
                        }
                    )
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") { viewModel.showError = false }
            } message: {
                Text(viewModel.errorMessage)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: viewModel.isRecording) { _, isRecording in
            if isRecording {
                livePrefixText = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .onChange(of: viewModel.transcribedText) { _, newValue in
            guard !newValue.isEmpty else { return }

            if viewModel.isRecording {
                if livePrefixText.isEmpty {
                    textInput = newValue
                } else {
                    textInput = livePrefixText + " " + newValue
                }
                lastCommittedText = newValue
                return
            }

            guard !viewModel.isProcessing,
                  newValue != lastCommittedText else { return }
            lastCommittedText = newValue
            if textInput.isEmpty {
                textInput = newValue
            } else {
                textInput += " " + newValue
            }
        }
        .background(EchoTheme.keyboardBackground)
        .ignoresSafeArea()
        .task {
            guard startForKeyboard else { return }
            await viewModel.startRecordingForKeyboard()
        }
    }
}

// MARK: - View Model

@MainActor
final class VoiceRecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var transcribedText = ""
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published var statusText = "Ready"
    @Published var tipText = EchoTaglines.random()
    @Published var showError = false
    @Published var errorMessage = ""
    private struct StreamingMetrics {
        let providerId: String
        let providerName: String
        let mode: String
        let startDate: Date
        var firstPartialMs: Int?
        var firstFinalMs: Int?
        var fallbackUsed: Bool = false
        var error: String?
    }

    private var audioService = AudioCaptureService()
    private let settings = AppSettings()
    private let keyStore = SecureKeyStore()
    private let contextStore = ContextMemoryStore()
    private let authSession = EchoAuthSession.shared
    private var capturedChunks: [AudioChunk] = []
    private var activeASRProvider: (any ASRProvider)?
    private var isStreamingSession = false
    private var streamingTask: Task<Void, Never>?
    private var isKeyboardMode = false
    private var recordingTask: Task<Void, Never>?
    private var streamMetrics: StreamingMetrics?
    private var smoothedLevel: CGFloat = 0

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        errorMessage = ""
        showError = false
        capturedChunks = []

        // Request microphone permission
        let micGranted = await audioService.requestPermission()
        guard micGranted else {
            showErrorMessage("Microphone access is required. Enable it in Settings.")
            return
        }

        // Resolve ASR provider based on Settings.
        guard let providerResult = resolveASRProvider() else {
            showErrorMessage("Speech recognition is not configured. Add your API key in Settings > API Keys.")
            return
        }
        let provider = providerResult.provider
        activeASRProvider = provider
        if providerResult.usedFallback {
            statusText = providerResult.fallbackMessage
        }
        isStreamingSession = settings.preferStreaming && provider.supportsStreaming
        if isStreamingSession {
            streamMetrics = StreamingMetrics(
                providerId: provider.id,
                providerName: provider.displayName,
                mode: "stream",
                startDate: Date()
            )
        } else {
            streamMetrics = StreamingMetrics(
                providerId: provider.id,
                providerName: provider.displayName,
                mode: "batch",
                startDate: Date()
            )
        }

        // Apple Speech requires explicit authorization.
        if provider.id == "apple_speech" {
            if let appleProvider = provider as? AppleLegacySpeechProvider {
                let speechStatus = await appleProvider.requestAuthorization()
                guard speechStatus == .authorized else {
                    showErrorMessage("Speech recognition permission is required.")
                    activeASRProvider = nil
                    return
                }
            }
        }

        // Start audio capture
        do {
            // Recreate per session to avoid stale AVAudioEngine state.
            audioService = AudioCaptureService()
            try audioService.startRecording()
        } catch {
            showErrorMessage("Failed to start recording: \(error.localizedDescription)")
            activeASRProvider = nil
            return
        }

        isRecording = true
        isProcessing = false
        statusText = isStreamingSession ? "Streaming..." : "Listening..."
        transcribedText = ""
        tipText = EchoTaglines.random()

        if isStreamingSession {
            startStreamingResults(provider: provider)
        }

        // Collect audio + update audio levels while recording.
        recordingTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.audioService.audioChunks {
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    self.capturedChunks.append(chunk)
                    let level = AudioLevelCalculator.rmsLevel(from: chunk)
                    self.appendAudioLevel(level)
                }

                if self.isStreamingSession, let provider = self.activeASRProvider {
                    var sent = false
                    for _ in 0..<12 {
                        do {
                            try await provider.feedAudio(chunk)
                            sent = true
                            break
                        } catch {
                            try? await Task.sleep(for: .milliseconds(120))
                        }
                    }
                    if !sent {
                        await MainActor.run {
                            self.errorMessage = "Streaming feed lagged; continuing with buffered audio."
                        }
                    }
                }
            }
        }
    }

    func stopRecording() async {
        let provider = activeASRProvider
        let streamingActive = isStreamingSession
        activeASRProvider = nil
        isStreamingSession = false

        audioService.stopRecording()
        recordingTask?.cancel()
        recordingTask = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: 30)

        // Give the tap a moment to flush in-flight buffers.
        for _ in 0..<4 where capturedChunks.isEmpty {
            try? await Task.sleep(for: .milliseconds(80))
        }

        guard let provider else {
            statusText = "Ready"
            streamMetrics = nil
            return
        }

        guard !capturedChunks.isEmpty else {
            statusText = "No audio data recorded"
            showErrorMessage("No audio data recorded")
            return
        }

        statusText = streamingActive ? "Finalizing..." : "Thinking..."
        isProcessing = true

        let combinedData = capturedChunks.reduce(Data()) { $0 + $1.data }
        let totalDuration = capturedChunks.reduce(0) { $0 + $1.duration }
        let format = capturedChunks.first?.format ?? .default

        let combinedChunk = AudioChunk(
            data: combinedData,
            format: format,
            duration: totalDuration
        )
        let sessionStartDate = streamMetrics?.startDate
        let sessionMode = streamMetrics?.mode ?? (streamingActive ? "stream" : "batch")
        var streamFirstPartialMs = streamMetrics?.firstPartialMs
        var streamFirstFinalMs = streamMetrics?.firstFinalMs
        var providerForStorage: (any ASRProvider)? = provider
        var fallbackUsed = false
        var asrLatencyMs: Int?
        var totalLatencyMs: Int?
        var correctionLatencyMs: Int?
        var rawText = ""

        do {
            let totalStart = Date()
            totalLatencyMs = nil

            // Transcribe / finalize stream
            let asrStart = Date()
            let transcription: TranscriptionResult
            if streamingActive {
                let final = try await provider.stopStreaming()
                stopStreamingResults()
                let merged = mergedStreamingText(finalText: final?.text, accumulatedText: transcribedText)
                let mergedText = merged.trimmingCharacters(in: .whitespacesAndNewlines)

                if shouldFallbackToBatchFromStreaming(finalText: mergedText, accumulatedText: transcribedText) {
                    let fallbackProvider = fallbackASRProvider(for: provider.id)
                    let fallbackStart = Date()

                    if let fallbackProvider {
                        let fallbackResult = try await transcribeAudioWithFallback(
                            primaryProvider: provider,
                            fallbackProvider: fallbackProvider,
                            audio: combinedChunk
                        )
                        transcription = fallbackResult.result
                        providerForStorage = fallbackResult.provider
                        if fallbackProvider.id != provider.id {
                            fallbackUsed = true
                        }
                        asrLatencyMs = Int(Date().timeIntervalSince(fallbackStart) * 1000)
                    } else {
                        let directResult = try await provider.transcribe(audio: combinedChunk)
                        let directText = directResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !directText.isEmpty else {
                            throw ASRError.transcriptionFailed("Streaming returned empty transcription")
                        }
                        transcription = directResult
                        asrLatencyMs = Int(Date().timeIntervalSince(fallbackStart) * 1000)
                    }
                } else {
                    transcription = TranscriptionResult(
                        text: mergedText,
                        language: final?.language ?? .unknown,
                        isFinal: true
                    )
                }

                if asrLatencyMs == nil {
                    asrLatencyMs = Int(Date().timeIntervalSince(asrStart) * 1000)
                }
            } else {
                let fallbackProvider = fallbackASRProvider(for: provider.id)
                let batchStart = Date()
                let batchResult = try await transcribeAudioWithFallback(
                    primaryProvider: provider,
                    fallbackProvider: fallbackProvider,
                    audio: combinedChunk
                )
                transcription = batchResult.result
                providerForStorage = batchResult.provider
                if batchResult.provider.id != provider.id {
                    fallbackUsed = true
                }
                if batchResult.provider.id == provider.id {
                    asrLatencyMs = Int(Date().timeIntervalSince(asrStart) * 1000)
                } else {
                    asrLatencyMs = Int(Date().timeIntervalSince(batchStart) * 1000)
                }
            }

            let now = Date()
            let resolvedSessionStart = sessionStartDate ?? asrStart
            let sessionElapsedMs = Int(now.timeIntervalSince(resolvedSessionStart) * 1000)
            if streamFirstFinalMs == nil {
                streamFirstFinalMs = sessionElapsedMs
            }
            if streamFirstPartialMs == nil {
                streamFirstPartialMs = min(
                    asrLatencyMs ?? sessionElapsedMs,
                    streamFirstFinalMs ?? sessionElapsedMs
                )
            }

            rawText = transcription.text
            var finalText = rawText

            // Auto Edit (optional)
            var correctionProviderId: String? = nil
            if settings.correctionEnabled,
               let correctionProvider = CorrectionProviderResolver.resolve(for: settings.selectedCorrectionProvider) {
                correctionProviderId = correctionProvider.id
                statusText = "Correcting..."
                let correctionStart = Date()
                do {
                    let pipeline = CorrectionPipeline(provider: correctionProvider)
                    let context = await contextStore.currentContext()
                    let corrected = try await pipeline.process(
                        transcription: transcription,
                        context: context,
                        options: settings.correctionOptions
                    )
                    finalText = corrected.correctedText
                } catch {
                    finalText = rawText
                }
                correctionLatencyMs = Int(Date().timeIntervalSince(correctionStart) * 1000)
            }

            await contextStore.addTranscription(finalText)

            totalLatencyMs = Int(Date().timeIntervalSince(totalStart) * 1000)

            await RecordingStore.shared.saveRecording(
                audio: combinedChunk,
                asrProviderId: providerForStorage?.id ?? provider.id,
                asrProviderName: providerForStorage?.displayName ?? provider.displayName,
                correctionProviderId: correctionProviderId,
                transcriptRaw: rawText,
                transcriptFinal: finalText,
                error: nil,
                userId: authSession.userId,
                asrLatencyMs: asrLatencyMs,
                correctionLatencyMs: correctionLatencyMs,
                totalLatencyMs: totalLatencyMs,
                streamMode: sessionMode,
                firstPartialMs: streamFirstPartialMs,
                firstFinalMs: streamFirstFinalMs,
                fallbackUsed: fallbackUsed
            )

            transcribedText = finalText
            isProcessing = false
            statusText = "Ready"
            let finalMetrics = StreamingMetrics(
                providerId: providerForStorage?.id ?? provider.id,
                providerName: providerForStorage?.displayName ?? provider.displayName,
                mode: fallbackUsed ? "batch-fallback" : sessionMode,
                startDate: streamMetrics?.startDate ?? Date(),
                firstPartialMs: streamFirstPartialMs,
                firstFinalMs: streamFirstFinalMs,
                fallbackUsed: fallbackUsed,
                error: nil
            )
            logStreamingMetrics(finalMetrics, totalMs: totalLatencyMs, asrMs: asrLatencyMs, correctionMs: correctionLatencyMs)
            deliverResult()
        } catch {
            if streamingActive {
                try? await provider.stopStreaming()
                stopStreamingResults()

                do {
                    let fallbackProvider = fallbackASRProvider(for: provider.id)
                    let recovered = try await transcribeAudioWithFallback(
                        primaryProvider: provider,
                        fallbackProvider: fallbackProvider,
                        audio: combinedChunk
                    )
                    let fallbackRaw = recovered.result.text
                    let finalText = fallbackRaw.isEmpty ? transcribedText : fallbackRaw
                    let recoveredFallbackUsed = recovered.provider.id != provider.id

                    let finalMetrics = StreamingMetrics(
                        providerId: recovered.provider.id,
                        providerName: recovered.provider.displayName,
                        mode: recoveredFallbackUsed ? "batch-fallback" : "stream-recovered",
                        startDate: streamMetrics?.startDate ?? Date(),
                        firstPartialMs: streamFirstPartialMs,
                        firstFinalMs: streamFirstFinalMs,
                        fallbackUsed: recoveredFallbackUsed || streamingActive,
                        error: nil
                    )

                    await RecordingStore.shared.saveRecording(
                        audio: combinedChunk,
                        asrProviderId: recovered.provider.id,
                        asrProviderName: recovered.provider.displayName,
                        correctionProviderId: nil,
                        transcriptRaw: fallbackRaw,
                        transcriptFinal: finalText,
                        error: nil,
                        userId: authSession.userId,
                        asrLatencyMs: asrLatencyMs,
                        correctionLatencyMs: correctionLatencyMs,
                        totalLatencyMs: totalLatencyMs,
                        streamMode: recovered.provider.id == provider.id ? "stream-recovered" : "batch-fallback",
                        firstPartialMs: streamFirstPartialMs,
                        firstFinalMs: streamFirstFinalMs,
                        fallbackUsed: recoveredFallbackUsed || streamingActive
                    )

                    transcribedText = finalText
                    isProcessing = false
                    statusText = "Ready"
                    logStreamingMetrics(finalMetrics, totalMs: totalLatencyMs, asrMs: asrLatencyMs, correctionMs: correctionLatencyMs)
                    deliverResult()
                    streamMetrics = nil
                    return
                } catch {
                    // keep fallback failure and continue normal error handling
                }
            } else {
                try? await provider.stopStreaming()
                stopStreamingResults()
            }

            if var metrics = streamMetrics {
                metrics.error = "Stop pipeline failed: \(error.localizedDescription)"
                logStreamingMetrics(metrics, totalMs: nil, asrMs: nil, correctionMs: nil)
            }
            await RecordingStore.shared.saveRecording(
                audio: combinedChunk,
                asrProviderId: providerForStorage?.id ?? provider.id,
                asrProviderName: providerForStorage?.displayName ?? provider.displayName,
                correctionProviderId: nil,
                transcriptRaw: nil,
                transcriptFinal: nil,
                error: error.localizedDescription,
                userId: authSession.userId,
                streamMode: sessionMode,
                fallbackUsed: streamingActive,
                errorCode: "\(type(of: error)):\(errorCodeValue(for: error))"
            )
            isProcessing = false
            statusText = "Ready"
            showErrorMessage("Could not process audio: \(error.localizedDescription)")
        }
        streamMetrics = nil
    }

    func startRecordingForKeyboard() async {
        isKeyboardMode = true
        await startRecording()
    }

    private func deliverResult() {
        guard !transcribedText.isEmpty else { return }
        if isKeyboardMode {
            settings.pendingTranscription = transcribedText
            isKeyboardMode = false
            statusText = "Sent to keyboard"
        } else {
            statusText = "Ready"
        }
    }

    private struct ASRProviderResolutionResult {
        let provider: any ASRProvider
        let usedFallback: Bool
        let fallbackMessage: String
    }

    private func resolveASRProvider() -> ASRProviderResolutionResult? {
        let selectedId = settings.selectedASRProvider

        if selectedId != "openai_whisper", let selectedProvider = asrProvider(for: selectedId), selectedProvider.isAvailable {
            return ASRProviderResolutionResult(provider: selectedProvider, usedFallback: false, fallbackMessage: "")
        }

        if selectedId == "openai_whisper" || selectedId == "apple_speech" {
            let provider = OpenAIWhisperProvider(keyStore: keyStore)
            if provider.isAvailable {
                return ASRProviderResolutionResult(provider: provider, usedFallback: false, fallbackMessage: "")
            }
            return nil
        }

        let fallback = OpenAIWhisperProvider(keyStore: keyStore)
        if fallback.isAvailable {
            return ASRProviderResolutionResult(
                provider: fallback,
                usedFallback: true,
                fallbackMessage: "fallback: selected provider unavailable, using OpenAI"
            )
        }

        return nil
    }

    private func asrProvider(for providerId: String) -> (any ASRProvider)? {
        switch providerId {
        case "apple_speech":
            let provider = AppleLegacySpeechProvider(localeIdentifier: nil)
            return provider.isAvailable ? provider : nil
        case "aliyun":
            guard let appKey = try? keyStore.retrieve(for: "aliyun_app_key"),
                  let token = try? keyStore.retrieve(for: "aliyun_token"),
                  !appKey.isEmpty,
                  !token.isEmpty else {
                return nil
            }
            return AliyunASRProvider(appKey: appKey, token: token)
        case "volcano":
            let provider = VolcanoASRProvider(keyStore: keyStore)
            return provider.isAvailable ? provider : nil
        case "ark_asr":
            let provider = ArkASRProvider(keyStore: keyStore)
            return provider.isAvailable ? provider : nil
        case "deepgram":
            let languageHint = deepgramLanguageHint(from: settings.defaultInputMode)
            let resolvedModel = deepgramModelHint(from: settings.defaultInputMode)
            let provider = DeepgramASRProvider(
                keyStore: keyStore,
                model: resolvedModel,
                language: languageHint
            )
            return provider.isAvailable ? provider : nil
        default:
            // Default to OpenAI Whisper (batch transcription).
            let provider = OpenAIWhisperProvider(keyStore: keyStore)
            return provider.isAvailable ? provider : nil
        }
    }

    private func deepgramModelHint(from inputMode: String) -> String {
        switch inputMode {
        case "pinyin":
            return "nova-2"
        default:
            return "nova-3"
        }
    }

    private func deepgramLanguageHint(from inputMode: String) -> String? {
        switch inputMode {
        case "pinyin":
            return "zh-CN"
        default:
            return nil
        }
    }

    private func appendAudioLevel(_ level: CGFloat) {
        let alpha: CGFloat = 0.22
        smoothedLevel = (smoothedLevel * (1 - alpha)) + (level * alpha)
        var levels = audioLevels
        levels.removeFirst()
        levels.append(smoothedLevel)
        audioLevels = levels
    }

    private func startStreamingResults(provider: any ASRProvider) {
        let stream = provider.startStreaming()
        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            guard let self else { return }
            for await result in stream {
                if Task.isCancelled { break }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                await MainActor.run {
                    if var metrics = self.streamMetrics {
                        if metrics.firstPartialMs == nil {
                            metrics.firstPartialMs = Int(Date().timeIntervalSince(metrics.startDate) * 1000)
                        }
                        if result.isFinal, metrics.firstFinalMs == nil {
                            metrics.firstFinalMs = Int(Date().timeIntervalSince(metrics.startDate) * 1000)
                        }
                        self.streamMetrics = metrics
                    }
                    self.transcribedText = self.mergeStreamingText(text, into: self.transcribedText)
                    self.statusText = result.isFinal ? "Refining..." : "Streaming..."
                }
            }
        }
    }

    private func stopStreamingResults() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    private func mergedStreamingText(finalText: String?, accumulatedText: String) -> String {
        let final = finalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let accumulated = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if final.isEmpty { return accumulated }
        if accumulated.isEmpty { return final }
        if final == accumulated { return accumulated }
        if final.hasPrefix(accumulated) { return final }
        if accumulated.hasSuffix(final) { return accumulated }
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

    private func shouldFallbackToBatchFromStreaming(finalText: String, accumulatedText: String) -> Bool {
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            return true
        }
        let accumulated = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if accumulated.isEmpty {
            return false
        }
        if final.count < 3 {
            return true
        }
        if accumulated.count >= 8 && final.count < max(3, accumulated.count / 2) {
            return true
        }
        return false
    }

    private func fallbackASRProvider(for providerId: String) -> (any ASRProvider)? {
        if providerId == "openai_whisper" {
            return nil
        }
        let fallback = OpenAIWhisperProvider(keyStore: keyStore)
        guard fallback.isAvailable else { return nil }
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

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func errorCodeValue(for error: Error) -> String {
        if let ns = error as NSError? {
            return "\(ns.domain):\(ns.code)"
        }
        return String(describing: type(of: error))
    }

    private func logStreamingMetrics(
        _ metrics: StreamingMetrics,
        totalMs: Int?,
        asrMs: Int?,
        correctionMs: Int?
    ) {
        let asr = asrMs.map(String.init) ?? "-"
        let total = totalMs.map(String.init) ?? "-"
        let edit = correctionMs.map(String.init) ?? "-"
        let firstPartial = metrics.firstPartialMs.map(String.init) ?? "-"
        let firstFinal = metrics.firstFinalMs.map(String.init) ?? "-"
        let mode = metrics.mode
        let fallback = metrics.fallbackUsed ? "true" : "false"
        let status = metrics.error == nil ? "success" : "error"
        print(
            """
            streaming_metrics \
            provider=\(metrics.providerId) \
            mode=\(mode) \
            first_partial_ms=\(firstPartial) \
            first_final_ms=\(firstFinal) \
            asr_ms=\(asr) \
            correction_ms=\(edit) \
            total_ms=\(total) \
            fallback=\(fallback) \
            status=\(status) \
            error=\(metrics.error ?? "none")
            """
        )
    }
}

// MARK: - Keyboard Accessory UI

struct KeyboardAccessoryBar: View {
    let isRecording: Bool
    let isProcessing: Bool
    let audioLevels: [CGFloat]
    let tipText: String
    let onToggleRecording: () -> Void
    let onOpenSettings: () -> Void
    let onDismissKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(EchoTheme.keySecondaryBackground))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onToggleRecording) {
                EchoDictationPill(
                    isRecording: isRecording,
                    isProcessing: isProcessing,
                    levels: audioLevels,
                    tipText: tipText,
                    width: 210,
                    height: 32
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onDismissKeyboard) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(EchoTheme.keySecondaryBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(EchoTheme.keyboardSurface)
    }
}

enum EchoTaglines {
    private static let options: [String] = [
        "Speak once. Echo shapes it into clarity.",
        "Echo turns ideas into clean, polished notes.",
        "Think aloud, Echo makes it usable.",
        "From voice to precision — powered by Echo.",
        "Echo keeps your thoughts crisp and actionable.",
        "Echo turns rough drafts into sharp direction."
    ]

    static func random() -> String {
        options.randomElement() ?? "Speak once. Echo shapes it into clarity."
    }
}
