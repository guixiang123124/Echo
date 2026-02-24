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
                if viewModel.showStreamStatus {
                    StreamStatusBadge(statusText: viewModel.streamStatusText)
                }

                if viewModel.showAutoEditReview {
                    AutoEditReviewCard(
                        originalText: viewModel.pendingAutoEditOriginal,
                        suggestedText: viewModel.pendingAutoEditSuggested,
                        onApply: { viewModel.applyPendingAutoEdit() },
                        onKeep: { viewModel.keepPendingAutoEdit() }
                    )
                }

                if viewModel.canUndoAutoEdit {
                    HStack {
                        Spacer()
                        Button {
                            viewModel.undoAutoEdit()
                        } label: {
                            Label("Undo AutoEdit", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                }

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

                if !startForKeyboard {
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
            guard viewModel.isRecording || viewModel.isProcessing || newValue != lastCommittedText else { return }
            textInput = composeSessionText(newValue)
            lastCommittedText = newValue
        }
        .background(EchoTheme.keyboardBackground)
        .ignoresSafeArea()
        .task {
            guard startForKeyboard else { return }
            await viewModel.startRecordingForKeyboard()
        }
    }

    private func composeSessionText(_ transcript: String) -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return textInput }
        guard !livePrefixText.isEmpty else { return cleaned }
        return livePrefixText + " " + cleaned
    }
}

private struct StreamStatusBadge: View {
    let statusText: String
    @State private var pulse = false

    private var dotColor: Color {
        statusText == "Recording" ? .red : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.15 : 0.85)
                .opacity(pulse ? 1.0 : 0.45)
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(EchoTheme.keyboardSurface)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(EchoTheme.pillStroke, lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }
}

private struct AutoEditReviewCard: View {
    let originalText: String
    let suggestedText: String
    let onApply: () -> Void
    let onKeep: () -> Void

    private func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 110 { return trimmed }
        return String(trimmed.prefix(110)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto Edit Suggestion")
                .font(.system(size: 13, weight: .semibold))

            Text("Before: \(preview(originalText))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Text("After: \(preview(suggestedText))")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(3)

            HStack {
                Button("Keep Finalize", action: onKeep)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(EchoTheme.keyboardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(EchoTheme.pillStroke, lineWidth: 1)
        )
    }
}

// MARK: - View Model

@MainActor
final class VoiceRecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var transcribedText = ""
    @Published var streamStatusText = ""
    @Published var showStreamStatus = false
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published var statusText = "Ready"
    @Published var tipText = EchoTaglines.random()
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var showAutoEditReview = false
    @Published var pendingAutoEditOriginal = ""
    @Published var pendingAutoEditSuggested = ""
    @Published var canUndoAutoEdit = false
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
    private var deferredPolishTask: Task<Void, Never>?
    private var deferredPolishSessionID = UUID()
    private var isKeyboardMode = false
    private var recordingTask: Task<Void, Never>?
    private var streamMetrics: StreamingMetrics?
    private var smoothedLevel: CGFloat = 0
    private var lastAutoEditSnapshot: (before: String, after: String)?

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
        deferredPolishTask?.cancel()
        deferredPolishTask = nil
        deferredPolishSessionID = UUID()
        showAutoEditReview = false
        pendingAutoEditOriginal = ""
        pendingAutoEditSuggested = ""
        canUndoAutoEdit = false
        lastAutoEditSnapshot = nil

        // Request microphone permission
        let micGranted = await audioService.requestPermission()
        guard micGranted else {
            showErrorMessage("Microphone access is required. Enable it in Settings.")
            return
        }

        // Resolve ASR provider based on Settings.
        guard let providerResult = resolveASRProvider() else {
            showErrorMessage("Speech recognition is not configured. Add provider keys in Settings > API Keys, or configure your Cloud API URL for backend-managed auth/sync.")
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
            streamStatusText = "Recording"
            showStreamStatus = true
        } else {
            streamStatusText = ""
            showStreamStatus = false
        }

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
            showStreamStatus = false
            streamStatusText = ""
            streamMetrics = nil
            return
        }

        guard !capturedChunks.isEmpty else {
            statusText = "No audio data recorded"
            showStreamStatus = false
            streamStatusText = ""
            showErrorMessage("No audio data recorded")
            return
        }

        statusText = streamingActive ? "Finalizing..." : "Thinking..."
        isProcessing = true
        if streamingActive {
            streamStatusText = "Finalizing"
            showStreamStatus = true
        } else {
            streamStatusText = ""
            showStreamStatus = false
        }

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
        var strongestStreamPartial = ""

        do {
            let totalStart = Date()
            totalLatencyMs = nil

            // Transcribe / finalize stream
            let asrStart = Date()
            let transcription: TranscriptionResult
            if streamingActive {
                let final = try await provider.stopStreaming()
                stopStreamingResults()
                let strongestPartial = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
                strongestStreamPartial = strongestPartial
                let merged = mergedStreamingText(finalText: final?.text, accumulatedText: strongestPartial)
                let mergedText = merged.trimmingCharacters(in: .whitespacesAndNewlines)

                let forceBatchFinalizeAfterStream = false
                let shouldBatchFinalize = forceBatchFinalizeAfterStream
                    || shouldFallbackToBatchFromStreaming(finalText: mergedText, accumulatedText: transcribedText)

                if shouldBatchFinalize {
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
            if streamingActive {
                finalText = nativeStreamingFinalize(
                    text: finalText,
                    strongestPartial: strongestStreamPartial
                )
            }
            let finalizeTextBeforePolish = finalText

            // Final polish:
            // - Always try once for streaming sessions (if a correction provider is configured)
            // - Respect user toggle for non-streaming sessions
            var correctionProviderId: String? = nil
            let streamFastPolishOptions = CorrectionOptions(
                enableHomophones: true,
                enablePunctuation: true,
                enableFormatting: false,
                enableRemoveFillerWords: false,
                enableRemoveRepetitions: true,
                rewriteIntensity: .off,
                enableTranslation: false,
                translationTargetLanguage: .keepSource
            )
            let streamFastActive = streamingActive && settings.streamFastEnabled
            let selectedPolishOptions = streamFastActive ? streamFastPolishOptions : settings.correctionOptions
            let shouldRunFinalPolish = settings.correctionEnabled && selectedPolishOptions.isEnabled
            let shouldRunDeferredPolish = streamFastActive && shouldRunFinalPolish
            let correctionProvider = CorrectionProviderResolver.resolve(for: settings.selectedCorrectionProvider)
                ?? CorrectionProviderResolver.firstAvailable()
            if shouldRunFinalPolish,
               let correctionProvider {
                correctionProviderId = correctionProvider.id
                if shouldRunDeferredPolish {
                    deferredPolishSessionID = UUID()
                    queueDeferredPolish(
                        sessionID: deferredPolishSessionID,
                        transcription: transcription,
                        provider: correctionProvider,
                        options: selectedPolishOptions,
                        baseText: finalizeTextBeforePolish
                    )
                } else {
                    if streamingActive {
                        streamStatusText = "Polishing"
                        showStreamStatus = true
                    }
                    statusText = "Correcting..."
                    let correctionStart = Date()
                    do {
                        let pipeline = CorrectionPipeline(provider: correctionProvider)
                        let context = await contextStore.currentContext()
                        let corrected = try await pipeline.process(
                            transcription: transcription,
                            context: context,
                            options: selectedPolishOptions
                        )
                        let correctedText = corrected.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let baseText = finalizeTextBeforePolish.trimmingCharacters(in: .whitespacesAndNewlines)
                        if settings.autoEditApplyMode == .confirmDiff,
                           !correctedText.isEmpty,
                           correctedText != baseText {
                            finalText = finalizeTextBeforePolish
                            stageAutoEditReview(original: baseText, suggested: correctedText)
                        } else if !correctedText.isEmpty {
                            finalText = correctedText
                        }
                    } catch {
                        finalText = rawText
                    }
                    correctionLatencyMs = Int(Date().timeIntervalSince(correctionStart) * 1000)
                }
            } else if shouldRunFinalPolish {
                if streamingActive {
                    streamStatusText = "Polishing"
                    showStreamStatus = true
                }
                let polished = lightweightFinalPolish(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
                let baseText = finalizeTextBeforePolish.trimmingCharacters(in: .whitespacesAndNewlines)
                if settings.autoEditApplyMode == .confirmDiff,
                   !polished.isEmpty,
                   polished != baseText {
                    finalText = finalizeTextBeforePolish
                    stageAutoEditReview(original: baseText, suggested: polished)
                } else if !polished.isEmpty {
                    finalText = polished
                } else {
                    finalText = finalizeTextBeforePolish
                }
                correctionProviderId = "local_polish"
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
            showStreamStatus = false
            streamStatusText = ""
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
            if !showAutoEditReview {
                updateAutoEditUndoSnapshotIfNeeded(
                    before: finalizeTextBeforePolish,
                    after: finalText
                )
            }
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
                    showStreamStatus = false
                    streamStatusText = ""
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
            showStreamStatus = false
            streamStatusText = ""
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

    private func queueDeferredPolish(
        sessionID: UUID,
        transcription: TranscriptionResult,
        provider: any CorrectionProvider,
        options: CorrectionOptions,
        baseText: String
    ) {
        deferredPolishTask?.cancel()
        deferredPolishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pipeline = CorrectionPipeline(provider: provider)
                let context = await self.contextStore.currentContext()
                let corrected = try await pipeline.process(
                    transcription: transcription,
                    context: context,
                    options: options
                )

                guard self.deferredPolishSessionID == sessionID, !self.isRecording else { return }
                let polished = corrected.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !polished.isEmpty, polished != base else { return }

                if self.settings.autoEditApplyMode == .confirmDiff {
                    self.stageAutoEditReview(original: base, suggested: polished)
                    if !self.isRecording {
                        self.statusText = "Review Auto Edit"
                    }
                } else {
                    self.applyAutoEditReplacement(before: base, after: polished)
                }
            } catch {
                // Keep finalized ASR text if deferred polish fails.
            }
        }
    }

    func applyPendingAutoEdit() {
        let before = pendingAutoEditOriginal
        let after = pendingAutoEditSuggested
        guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            keepPendingAutoEdit()
            return
        }
        showAutoEditReview = false
        pendingAutoEditOriginal = ""
        pendingAutoEditSuggested = ""
        applyAutoEditReplacement(before: before, after: after)
    }

    func keepPendingAutoEdit() {
        showAutoEditReview = false
        pendingAutoEditOriginal = ""
        pendingAutoEditSuggested = ""
        if !isRecording {
            statusText = "Ready"
        }
    }

    func undoAutoEdit() {
        guard let snapshot = lastAutoEditSnapshot else {
            canUndoAutoEdit = false
            return
        }
        transcribedText = snapshot.before
        canUndoAutoEdit = false
        lastAutoEditSnapshot = nil
        Task { [before = snapshot.before] in
            await contextStore.addTranscription(before)
        }
        if !isRecording {
            statusText = "Ready"
        }
    }

    private func stageAutoEditReview(original: String, suggested: String) {
        let before = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty, !after.isEmpty, before != after else { return }
        pendingAutoEditOriginal = before
        pendingAutoEditSuggested = after
        showAutoEditReview = true
        if !isRecording {
            statusText = "Review Auto Edit"
        }
    }

    private func applyAutoEditReplacement(before: String, after: String) {
        let beforeText = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterText = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterText.isEmpty else { return }
        transcribedText = afterText
        updateAutoEditUndoSnapshotIfNeeded(before: beforeText, after: afterText)
        Task { [afterText] in
            await contextStore.addTranscription(afterText)
        }
        if !isRecording {
            statusText = "Ready"
        }
    }

    private func updateAutoEditUndoSnapshotIfNeeded(before: String, after: String) {
        let beforeText = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterText = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !beforeText.isEmpty, !afterText.isEmpty, beforeText != afterText else {
            canUndoAutoEdit = false
            lastAutoEditSnapshot = nil
            return
        }
        lastAutoEditSnapshot = (before: beforeText, after: afterText)
        canUndoAutoEdit = true
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
        if selectedId != "openai_whisper", let proxyProvider = resolveCloudProxyProvider(for: selectedId) {
            return ASRProviderResolutionResult(provider: proxyProvider, usedFallback: false, fallbackMessage: "")
        }

        if selectedId == "openai_whisper" {
            let provider = OpenAIWhisperProvider(
                keyStore: keyStore,
                model: settings.openAITranscriptionModel
            )
            if provider.isAvailable {
                return ASRProviderResolutionResult(provider: provider, usedFallback: false, fallbackMessage: "")
            }
            if let proxyProvider = resolveCloudProxyProvider(for: "openai_whisper") {
                return ASRProviderResolutionResult(provider: proxyProvider, usedFallback: false, fallbackMessage: "")
            }
            return nil
        }

        let fallback = OpenAIWhisperProvider(
            keyStore: keyStore,
            model: settings.openAITranscriptionModel
        )
        if fallback.isAvailable {
            return ASRProviderResolutionResult(
                provider: fallback,
                usedFallback: true,
                fallbackMessage: "fallback: selected provider unavailable, using OpenAI"
            )
        }

        if let proxyFallback = resolveCloudProxyProvider(for: "openai_whisper") {
            return ASRProviderResolutionResult(
                provider: proxyFallback,
                usedFallback: true,
                fallbackMessage: "fallback: selected provider unavailable, using backend OpenAI proxy"
            )
        }

        return nil
    }

    private func resolveCloudProxyProvider(for providerId: String) -> (any ASRProvider)? {
        let token = authSession.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseURL = authSession.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !baseURL.isEmpty else { return nil }

        let model: String?
        let language: String?
        switch providerId {
        case "deepgram":
            model = settings.deepgramModel
            language = deepgramLanguageHint(from: settings.defaultInputMode)
        case "openai_whisper":
            model = settings.openAITranscriptionModel
            language = settings.defaultInputMode == "pinyin" ? "zh" : nil
        case "volcano":
            model = nil
            language = settings.defaultInputMode == "pinyin" ? "zh-CN" : nil
        default:
            return nil
        }

        let provider = BackendProxyASRProvider(
            providerId: providerId,
            backendBaseURL: baseURL,
            accessToken: token,
            model: model,
            language: language
        )
        return provider.isAvailable ? provider : nil
    }

    private func asrProvider(for providerId: String) -> (any ASRProvider)? {
        switch providerId {
        case "volcano":
            let provider = VolcanoASRProvider(keyStore: keyStore)
            return provider.isAvailable ? provider : nil
        case "deepgram":
            let languageHint = deepgramLanguageHint(from: settings.defaultInputMode)
            let resolvedModel = settings.deepgramModel
            let provider = DeepgramASRProvider(
                keyStore: keyStore,
                model: resolvedModel,
                language: languageHint
            )
            return provider.isAvailable ? provider : nil
        default:
            // Default to OpenAI Whisper (batch transcription).
            let provider = OpenAIWhisperProvider(
                keyStore: keyStore,
                model: settings.openAITranscriptionModel
            )
            return provider.isAvailable ? provider : nil
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
                    let sanitized = self.sanitizeStreamingText(text, previousText: self.transcribedText)
                    guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let merged = self.mergeStreamingText(sanitized, into: self.transcribedText)
                    let canonical = self.sanitizeStreamingText(merged, previousText: self.transcribedText)
                    guard canonical != self.transcribedText else { return }
                    self.transcribedText = canonical
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
        if let prefixDecision = prefixDominantReplacementDecision(incoming: incoming, accumulated: accumulated) {
            return prefixDecision ? incoming : accumulated
        }

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

    private func nativeStreamingFinalize(text: String, strongestPartial: String) -> String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let partial = strongestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if base.isEmpty {
            candidate = partial
        } else if partial.isEmpty {
            candidate = base
        } else {
            candidate = mergeStreamingText(base, into: partial)
        }
        let normalized = sanitizeStreamingText(candidate, previousText: partial)
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
        return normalized
    }

    private func prefixDominantReplacementDecision(incoming: String, accumulated: String) -> Bool? {
        let normalizedIncoming = normalizedStreamingComparisonText(incoming)
        let normalizedAccumulated = normalizedStreamingComparisonText(accumulated)
        guard !normalizedIncoming.isEmpty, !normalizedAccumulated.isEmpty else { return nil }

        if normalizedIncoming == normalizedAccumulated {
            return incoming.count >= accumulated.count
        }
        if normalizedIncoming.hasPrefix(normalizedAccumulated) {
            return true
        }
        if normalizedAccumulated.hasPrefix(normalizedIncoming) {
            return false
        }

        let shorterCount = min(normalizedIncoming.count, normalizedAccumulated.count)
        guard shorterCount >= 8 else { return nil }
        let sharedPrefix = sharedPrefixLength(normalizedIncoming, normalizedAccumulated)
        let prefixRatio = Double(sharedPrefix) / Double(shorterCount)
        guard prefixRatio >= 0.82 else { return nil }

        return incoming.count >= accumulated.count
    }

    private func normalizedStreamingComparisonText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(filtered))
    }

    private func sharedPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for pair in zip(lhs, rhs) {
            if pair.0 != pair.1 { break }
            count += 1
        }
        return count
    }

    private func sanitizeStreamingText(_ text: String, previousText: String) -> String {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = removeObviousConsecutiveRepetition(
            in: incoming,
            baseText: previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if cleaned.count > 1200 {
            return cleaned
        }
        return collapseDuplicateFullString(from: cleaned)
    }

    private func removeObviousConsecutiveRepetition(in text: String, baseText: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !baseText.isEmpty else {
            return trimmedText
        }

        let repeatedTrimmed = collapseImmediateRepetition(around: baseText, candidate: trimmedText)
        return repeatedTrimmed
    }

    private func collapseImmediateRepetition(around baseText: String, candidate text: String) -> String {
        guard !baseText.isEmpty else { return text }
        if text == baseText { return text }

        let repeated = collapseLeadingRuns(of: baseText, in: text)
        return repeated
    }

    private func collapseLeadingRuns(of unit: String, in text: String) -> String {
        guard !unit.isEmpty else { return text }
        guard text.hasPrefix(unit) else { return text }

        var remaining = text
        var runCount = 0

        while canDropPrefixRun(remaining, unit: unit) {
            remaining = String(remaining.dropFirst(unit.count))
            remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            runCount += 1
        }

        if runCount <= 1 {
            return text
        }
        if remaining.isEmpty {
            return unit
        }
        if shouldInsertSpace(between: unit, and: remaining) {
            return "\(unit) \(remaining)"
        }
        return unit + remaining
    }

    private func canDropPrefixRun(_ text: String, unit: String) -> Bool {
        guard text.hasPrefix(unit) else { return false }
        if text == unit { return true }

        let remainder = String(text.dropFirst(unit.count))
        let unitContainsWhitespace = unit.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        guard unitContainsWhitespace else {
            let unitASCII = unit.unicodeScalars.allSatisfy(\.isASCII)
            if !unitASCII { return true }
            guard let next = remainder.unicodeScalars.first else { return false }
            return !CharacterSet.alphanumerics.contains(next)
        }

        return true
    }

    private func collapseDuplicateFullString(from text: String) -> String {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return incoming }

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
                let unitText = String(unit)
                let tail = String(incomingChars.dropFirst(unitLength * duplicateRuns))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tail.isEmpty else { return unitText }
                if shouldInsertSpace(between: unitText, and: tail) {
                    return "\(unitText) \(tail)"
                }
                return unitText + tail
            }
        }

        return incoming
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
        let fallback = OpenAIWhisperProvider(
            keyStore: keyStore,
            model: settings.openAITranscriptionModel
        )
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

    private func lightweightFinalPolish(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return output }

        output = output.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        output = output.replacingOccurrences(of: " ,", with: ",")
        output = output.replacingOccurrences(of: " .", with: ".")
        output = output.replacingOccurrences(of: " !", with: "!")
        output = output.replacingOccurrences(of: " ?", with: "?")
        output = output.replacingOccurrences(of: " ，", with: "，")
        output = output.replacingOccurrences(of: " 。", with: "。")
        output = output.replacingOccurrences(of: " ！", with: "！")
        output = output.replacingOccurrences(of: " ？", with: "？")

        if let first = output.first, first.isLetter {
            output.replaceSubrange(output.startIndex...output.startIndex, with: String(first).uppercased())
        }
        return output
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
