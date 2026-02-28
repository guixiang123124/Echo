import Foundation
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// Service that manages background dictation sessions triggered by the keyboard extension.
///
/// Flow:
/// 1. Keyboard posts `.dictationStart` via Darwin notification
/// 2. This service receives it, resolves an ASR provider, starts recording
/// 3. Streaming partials are written to `AppGroupBridge` + `.transcriptionReady` posted
/// 4. Keyboard reads partials and injects text incrementally
/// 5. Keyboard posts `.dictationStop` → session stops, ASR finalization + polish happens
///
/// The service also posts a heartbeat every 2s so the keyboard knows the app is alive.
@MainActor
public final class BackgroundDictationService: ObservableObject {
    public enum SessionState: Sendable, Equatable {
        case idle
        case recording
        case transcribing
        case finalizing
        case error(String)
    }

    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var latestPartialText: String = ""
    @Published public private(set) var sessionId: String = ""

    // Dependencies
    private let bridge: AppGroupBridge
    private let darwin: DarwinNotificationCenter
    private let settings: AppSettings
    private let keyStore: SecureKeyStore

    // Session state
    private var audioService: AudioCaptureService?
    private var currentProvider: (any ASRProvider)?
    private var sequenceCounter: Int = 0
    private var isStreamingSession = false
    private var capturedChunks: [AudioChunk] = []
    private var latestPartialLanguage: RecognizedLanguage = .unknown
    private var streamDidReceiveFinalResult = false
    private var recordingTask: Task<Void, Never>?
    private var streamingResultTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var idleTimeoutTask: Task<Void, Never>?
    private var commandPollTask: Task<Void, Never>?

    // Darwin observation tokens
    private var startToken: DarwinNotificationCenter.ObservationToken?
    private var stopToken: DarwinNotificationCenter.ObservationToken?

    // Auth session reference for provider resolution
    private weak var authSession: EchoAuthSession?

    // Debounce: ignore rapid start/stop within this window
    private var lastToggleTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.5

    public init(
        settings: AppSettings = AppSettings(),
        keyStore: SecureKeyStore = SecureKeyStore(),
        bridge: AppGroupBridge = AppGroupBridge(),
        darwin: DarwinNotificationCenter = .shared
    ) {
        self.settings = settings
        self.keyStore = keyStore
        self.bridge = bridge
        self.darwin = darwin
    }

    // MARK: - Lifecycle

    /// Start listening for Darwin notifications from the keyboard extension.
    /// Call this when the app launches or becomes active.
    public func activate(authSession: EchoAuthSession) {
        self.authSession = authSession

        startToken = darwin.observe(.dictationStart) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleDictationStartRequest()
            }
        }

        stopToken = darwin.observe(.dictationStop) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleDictationStopRequest()
            }
        }

        // Write initial idle state
        bridge.setEngineRunning(true)
        bridge.setDictationState(.idle, sessionId: "")
        bridge.writeHeartbeat()
        bridge.clearStreamingData()
        startHeartbeat()
        startCommandPolling()
    }

    /// Stop listening and clean up. Call when app is about to terminate.
    public func deactivate() {
        if let startToken { darwin.removeObservation(startToken) }
        if let stopToken { darwin.removeObservation(stopToken) }
        startToken = nil
        stopToken = nil

        cancelAllTasks()
        bridge.setRecording(false)
        bridge.setEngineRunning(false)
        bridge.clearStreamingData()
        bridge.setDictationState(.idle, sessionId: "")
        state = .idle
    }

    // MARK: - Public API

    /// Start a dictation session programmatically (e.g. from the voice recording view).
    public func startDictation() async {
        await performStartDictation()
    }

    /// Stop the current dictation session.
    public func stopDictation() async {
        await performStopDictation()
    }

    /// Start dictation specifically for a keyboard intent. Handles edge cases like
    /// already-recording sessions or finalizing state.
    public func startDictationForKeyboardIntent() async {
        switch state {
        case .idle, .error:
            await performStartDictation()

        case .recording, .transcribing:
            if hasActiveRecordingPipeline() {
                return
            }
            await recoverAndRestartDictationSession()

        case .finalizing:
            let becameIdle = await waitForStateToBecomeIdle(timeout: 1.0)
            if becameIdle {
                await performStartDictation()
            } else {
                await recoverAndRestartDictationSession()
            }
        }
    }

    /// Toggle dictation (start if idle, stop if recording/transcribing).
    public func toggleDictation() async {
        switch state {
        case .idle, .error:
            await performStartDictation()
        case .recording, .transcribing:
            await performStopDictation()
        case .finalizing:
            break // Wait for finalization to complete
        }
    }

    // MARK: - Darwin Notification Handlers

    private func handleDictationStartRequest() async {
        guard debounceCheck() else { return }

        switch state {
        case .idle, .error:
            await performStartDictation()
        case .recording, .transcribing:
            // Already recording — treat as toggle (stop)
            await performStopDictation()
        case .finalizing:
            break
        }
    }

    private func handleDictationStopRequest() async {
        guard debounceCheck() else { return }

        switch state {
        case .recording, .transcribing:
            await performStopDictation()
        default:
            break
        }
    }

    // MARK: - Core Logic

    private func performStartDictation() async {
        // Cancel idle timeout if we're restarting
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil

        let newSessionId = UUID().uuidString
        sessionId = newSessionId
        sequenceCounter = 0
        latestPartialText = ""
        latestPartialLanguage = .unknown
        streamDidReceiveFinalResult = false
        capturedChunks.removeAll()

        // Resolve ASR provider
        guard let authSession else {
            transitionToError("Auth session not available")
            return
        }

        let resolver = ASRProviderResolver(
            settings: settings,
            keyStore: keyStore,
            authSession: authSession
        )
        guard let resolution = resolver.resolve() else {
            transitionToError("No ASR provider available. Check API keys in Settings.")
            return
        }

        let provider = resolution.provider
        isStreamingSession = settings.preferStreaming && provider.supportsStreaming
        currentProvider = provider

        // Reuse existing AudioCaptureService if the engine is still running (kept
        // alive from a previous session). Otherwise create a fresh one.
        let audio: AudioCaptureService
        let engineWasAlreadyRunning: Bool

        if let existing = audioService, existing.isEngineRunning {
            audio = existing
            engineWasAlreadyRunning = true
            print("[BackgroundDictation] Reusing existing audio engine")
        } else {
            let fresh = AudioCaptureService()
            let hasPermission = await fresh.requestPermission()
            guard hasPermission else {
                transitionToError("Microphone access denied. Grant permission in Settings.")
                return
            }
            audio = fresh
            audioService = fresh
            engineWasAlreadyRunning = false
            bridge.setEngineRunning(true)
        }

        // Start streaming session only when supported and preferred.
        let stream = isStreamingSession ? provider.startStreaming() : nil

        if engineWasAlreadyRunning {
            // Engine is running with an idle (noop) tap — swap to processing tap.
            do {
                try audio.resumeRecording()
            } catch {
                transitionToError("Failed to resume recording: \(error.localizedDescription)")
                return
            }
        } else {
            // Fresh start — uses the standard audio session configuration
            // (same path as VoiceRecordingView).
            do {
                try audio.startRecording()
            } catch {
                transitionToError("Failed to start recording: \(error.localizedDescription)")
                return
            }

            // After recording is active, try to upgrade to background-friendly options.
            // Non-fatal — if it fails, recording still works (just may interrupt other audio).
            #if os(iOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
                )
            } catch {
                print("[BackgroundDictation] mixWithOthers upgrade failed (non-fatal): \(error)")
            }
            #endif
        }

        state = .recording
        bridge.setRecording(true)
        bridge.setDictationState(.recording, sessionId: newSessionId)
        darwin.post(.stateChanged)

        if isStreamingSession {
            // Task: feed audio chunks to provider
            recordingTask = Task { [weak self] in
                guard let self else { return }
                for await chunk in audio.audioChunks {
                    guard !Task.isCancelled else { break }
                    do {
                        try await self.currentProvider?.feedAudio(chunk)
                    } catch {
                        // Non-fatal: log and continue
                        print("[BackgroundDictation] feedAudio error: \(error)")
                    }
                }
            }

            // Task: consume streaming results and write to bridge
            if let stream {
                streamingResultTask = Task { [weak self] in
                    for await result in stream {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }

                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }

                        await MainActor.run {
                            self.sequenceCounter += 1
                            self.latestPartialText = text
                            self.latestPartialLanguage = result.language
                            self.streamDidReceiveFinalResult = self.streamDidReceiveFinalResult || result.isFinal

                            if result.isFinal {
                                self.state = .transcribing
                                self.bridge.setDictationState(.transcribing, sessionId: newSessionId)
                            }

                            self.bridge.writeStreamingPartial(
                                text,
                                sequence: self.sequenceCounter,
                                isFinal: result.isFinal,
                                sessionId: newSessionId
                            )
                            self.darwin.post(.transcriptionReady)
                        }
                    }
                }
            }
        } else {
            // Batch mode: only collect chunks, transcribe after stop.
            recordingTask = Task { [weak self] in
                for await chunk in audio.audioChunks {
                    guard !Task.isCancelled else { break }
                    guard let self else { continue }
                    self.capturedChunks.append(chunk)
                }
            }
        }
    }

    private func performStopDictation() async {
        guard state == .recording || state == .transcribing else { return }

        state = .finalizing
        bridge.setRecording(false)
        bridge.setDictationState(.finalizing, sessionId: sessionId)
        darwin.post(.stateChanged)

        let currentSessionId = sessionId
        let polishOptions = determinePolishOptions()
        var rawText = latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Stop feeding audio to the ASR provider, but keep engine alive by default.
        recordingTask?.cancel()
        recordingTask = nil

        if let service = audioService, service.isEngineRunning {
            service.idleEngine()
            print("[BackgroundDictation] Engine transitioned to idle (kept alive)")
        }

        if let provider = currentProvider {
            do {
                if isStreamingSession {
                    if let finalResult = try await provider.stopStreaming() {
                        let text = finalResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            latestPartialText = text
                            latestPartialLanguage = finalResult.language
                            rawText = text

                            // Stream implementations may emit final chunk already.
                            if !streamDidReceiveFinalResult {
                                sequenceCounter += 1
                                bridge.writeStreamingPartial(
                                    text,
                                    sequence: sequenceCounter,
                                    isFinal: true,
                                    sessionId: currentSessionId
                                )
                                darwin.post(.transcriptionReady)
                            }
                        }
                    }
                } else {
                    let combined = AudioChunk.combine(capturedChunks)
                    if !combined.isEmpty {
                        let result = try await provider.transcribe(audio: combined)
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            latestPartialText = text
                            latestPartialLanguage = result.language
                            rawText = text
                        }
                    }
                }
            } catch {
                print("[BackgroundDictation] stop/Finalize error: \(error)")
            }
        }

        streamingResultTask?.cancel()
        streamingResultTask = nil

        // For both modes, run the correction pipeline before writing final text.
        if !rawText.isEmpty,
           settings.correctionEnabled,
           polishOptions.isEnabled,
           let correctionProvider = CorrectionProviderResolver.resolve(for: settings.selectedCorrectionProvider, keyStore: keyStore)
           ?? CorrectionProviderResolver.firstAvailable(keyStore: keyStore) {
            state = .finalizing
            bridge.setDictationState(.finalizing, sessionId: currentSessionId)
            darwin.post(.stateChanged)

            let transcription = TranscriptionResult(
                text: rawText,
                language: latestPartialLanguage,
                isFinal: true,
                wordConfidences: []
            )

            do {
                let pipeline = CorrectionPipeline(provider: correctionProvider)
                let corrected = try await pipeline.process(
                    transcription: transcription,
                    context: .empty,
                    options: polishOptions
                )
                rawText = corrected.correctedText
            } catch {
                print("[BackgroundDictation] polish error: \(error)")
            }
        }

        let finalText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            state = .finalizing
            sequenceCounter += 1
            latestPartialText = finalText
            bridge.writeStreamingPartial(
                finalText,
                sequence: sequenceCounter,
                isFinal: true,
                sessionId: currentSessionId
            )
            darwin.post(.transcriptionReady)
        }

        state = .idle
        bridge.setDictationState(.idle, sessionId: currentSessionId)
        darwin.post(.stateChanged)

        // Release provider but keep audioService alive (engine still running by default)
        currentProvider = nil
        isStreamingSession = false
        streamDidReceiveFinalResult = false
        capturedChunks.removeAll()

        // Start idle timeout to eventually release audio engine & session
        startIdleTimeout()
    }

    private func determinePolishOptions() -> CorrectionOptions {
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

        let streamFastActive = isStreamingSession && settings.streamFastEnabled
        return streamFastActive ? streamFastPolishOptions : settings.correctionOptions
    }

    private func transitionToError(_ message: String) {
        state = .error(message)
        bridge.setRecording(false)
        bridge.setDictationState(.error, sessionId: sessionId)
        darwin.post(.stateChanged)
        print("[BackgroundDictation] Error: \(message)")

        // Auto-dismiss error after 5 seconds so the overlay doesn't persist
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if case .error = self.state {
                self.state = .idle
                self.bridge.setDictationState(.idle, sessionId: "")
                self.currentProvider = nil
                self.isStreamingSession = false
                self.streamDidReceiveFinalResult = false
                self.capturedChunks.removeAll()
                self.darwin.post(.stateChanged)
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await MainActor.run {
                    self.bridge.writeHeartbeat()
                }
                self.darwin.post(.heartbeat)
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
        }
    }

    // MARK: - Voice Command Polling

    /// Poll AppGroupBridge voice commands that some keyboard paths use instead of
    /// direct Darwin notifications.
    private func startCommandPolling() {
        commandPollTask?.cancel()
        commandPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let command = AppGroupBridge().consumeVoiceCommand() {
                    await MainActor.run {
                        self.handleVoiceCommand(command)
                    }
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    @MainActor
    private func handleVoiceCommand(_ command: AppGroupBridge.VoiceCommand) {
        switch command {
        case .start:
            switch state {
            case .idle, .error:
                Task {
                    await performStartDictation()
                }
            default:
                break
            }
        case .stop:
            switch state {
            case .recording, .transcribing:
                Task {
                    await performStopDictation()
                }
            default:
                break
            }
        }
    }

    // MARK: - Idle Timeout

    private func startIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task { [weak self] in
            guard let self else { return }
            let timeout = self.bridge.residenceMode.timeoutSeconds
            guard timeout.isFinite && timeout > 0 else { return }

            let nanos = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                // Idle timeout fired — fully stop the audio engine and mark it inactive.
                self.audioService?.stopRecording()
                self.audioService = nil
                self.bridge.setEngineRunning(false)
                self.bridge.clearStreamingData()
                print("[BackgroundDictation] Idle timeout — audio engine stopped, session deactivated")
            }
        }
    }

    // MARK: - Session Recovery

    private func recoverAndRestartDictationSession() async {
        if state == .recording || state == .transcribing {
            await performStopDictation()
        } else {
            recordingTask?.cancel()
            streamingResultTask?.cancel()
            recordingTask = nil
            streamingResultTask = nil
        }

        state = .idle
        bridge.setRecording(false)
        bridge.setDictationState(.idle, sessionId: sessionId)
        darwin.post(.stateChanged)
        currentProvider = nil
        await performStartDictation()
    }

    private func hasActiveRecordingPipeline() -> Bool {
        guard state == .recording || state == .transcribing else { return false }

        if let recordingTask, !recordingTask.isCancelled {
            return true
        }
        if let streamingResultTask, !streamingResultTask.isCancelled {
            return true
        }
        return audioService?.isEngineRunning ?? false
    }

    private func waitForStateToBecomeIdle(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .idle = state {
                return true
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return false
    }

    // MARK: - Helpers

    private func debounceCheck() -> Bool {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastToggleTime)
        guard elapsed >= debounceInterval else { return false }
        lastToggleTime = now
        return true
    }

    private func cancelAllTasks() {
        recordingTask?.cancel()
        streamingResultTask?.cancel()
        heartbeatTask?.cancel()
        idleTimeoutTask?.cancel()
        commandPollTask?.cancel()
        recordingTask = nil
        streamingResultTask = nil
        heartbeatTask = nil
        idleTimeoutTask = nil
        commandPollTask = nil

        // Full shutdown — stop the engine and release everything
        audioService?.stopRecording()
        audioService = nil
        currentProvider = nil
        isStreamingSession = false
        streamDidReceiveFinalResult = false
        capturedChunks.removeAll()
        bridge.setRecording(false)
        bridge.setEngineRunning(false)
        bridge.clearStreamingData()
        print("[BackgroundDictation] All tasks cancelled, audio engine stopped")
    }
}
