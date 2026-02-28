import Foundation
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// Service that manages background dictation sessions triggered by the keyboard extension.
///
/// Flow:
/// 1. Keyboard posts `.dictationStart` via Darwin notification
/// 2. This service receives it, resolves an ASR provider, starts recording
/// 3. **Streaming mode**: partials written to `AppGroupBridge` + `.transcriptionReady` posted
/// 4. **Batch mode**: audio chunks collected; transcribed on stop
/// 5. Keyboard posts `.dictationStop` -> recording stops, polish pipeline runs, final result written
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
    private var recordingTask: Task<Void, Never>?
    private var streamingResultTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var idleTimeoutTask: Task<Void, Never>?

    // Dual-mode state
    private var isStreamingSession: Bool = false
    private var capturedChunks: [AudioChunk] = []

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

        // Idempotent: skip if already registered
        guard startToken == nil else { return }

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
        bridge.setDictationState(.idle, sessionId: "")
        bridge.writeHeartbeat()
        startHeartbeat()
    }

    /// Stop listening and clean up. Call when app is about to terminate.
    public func deactivate() {
        if let startToken { darwin.removeObservation(startToken) }
        if let stopToken { darwin.removeObservation(stopToken) }
        startToken = nil
        stopToken = nil

        cancelAllTasks()
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
            // Already recording -- treat as toggle (stop)
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
        capturedChunks = []

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
        currentProvider = provider

        // Determine streaming vs batch mode
        isStreamingSession = settings.preferStreaming && provider.supportsStreaming

        // Reuse existing AudioCaptureService if the engine is still running (kept
        // alive from a previous session). Otherwise create a fresh one.
        let audio: AudioCaptureService
        let engineWasAlreadyRunning: Bool

        if let existing = audioService, existing.isEngineRunning {
            audio = existing
            engineWasAlreadyRunning = true
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
        }

        // Start streaming from provider (only for streaming mode)
        let stream: AsyncStream<TranscriptionResult>? = isStreamingSession ? provider.startStreaming() : nil

        if engineWasAlreadyRunning {
            do {
                try audio.resumeRecording()
            } catch {
                transitionToError("Failed to resume recording: \(error.localizedDescription)")
                return
            }
        } else {
            do {
                try audio.startRecording()
            } catch {
                transitionToError("Failed to start recording: \(error.localizedDescription)")
                return
            }

            // After recording is active, try to upgrade to background-friendly options.
            #if os(iOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
                )
            } catch {
                // Non-fatal -- recording still works
            }
            #endif
        }

        state = .recording
        bridge.setDictationState(.recording, sessionId: newSessionId)
        darwin.post(.stateChanged)

        if isStreamingSession {
            // Streaming mode: feed audio to provider and consume streaming results
            recordingTask = Task {
                for await chunk in audio.audioChunks {
                    guard !Task.isCancelled else { break }
                    do {
                        try await provider.feedAudio(chunk)
                    } catch {
                        // Non-fatal: continue
                    }
                }
            }

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
            // Batch mode: only collect audio chunks, no real-time transcription
            recordingTask = Task { [weak self] in
                for await chunk in audio.audioChunks {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    await MainActor.run {
                        self.capturedChunks.append(chunk)
                    }
                }
            }
        }
    }

    private func performStopDictation() async {
        guard state == .recording || state == .transcribing else { return }

        state = .finalizing
        bridge.setDictationState(.finalizing, sessionId: sessionId)
        darwin.post(.stateChanged)

        // Stop feeding audio, but keep the engine running with an idle tap.
        recordingTask?.cancel()
        recordingTask = nil
        audioService?.idleEngine()

        var rawText = ""

        if isStreamingSession {
            // Streaming path: get final result from provider
            if let provider = currentProvider {
                do {
                    if let finalResult = try await provider.stopStreaming() {
                        let text = finalResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            rawText = text
                        }
                    }
                } catch {
                    // Fall back to last partial
                    rawText = latestPartialText
                }
            }

            streamingResultTask?.cancel()
            streamingResultTask = nil

            // If streaming produced no final text, use last partial
            if rawText.isEmpty {
                rawText = latestPartialText
            }
        } else {
            // Batch path: combine chunks and transcribe
            let combined = AudioChunk.combine(capturedChunks)
            capturedChunks = []

            guard !combined.isEmpty, let provider = currentProvider else {
                finishSession(finalText: "")
                return
            }

            // Write a placeholder so keyboard shows "transcribing..."
            state = .transcribing
            bridge.setDictationState(.transcribing, sessionId: sessionId)
            darwin.post(.stateChanged)

            do {
                let result = try await provider.transcribe(audio: combined)
                rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Write raw text immediately so the keyboard can show it
                if !rawText.isEmpty {
                    sequenceCounter += 1
                    latestPartialText = rawText
                    bridge.writeStreamingPartial(
                        rawText,
                        sequence: sequenceCounter,
                        isFinal: false,
                        sessionId: sessionId
                    )
                    darwin.post(.transcriptionReady)
                }
            } catch {
                transitionToError("Transcription failed: \(error.localizedDescription)")
                return
            }
        }

        // Polish pipeline (shared by both streaming and batch)
        let finalText = await runPolishPipeline(rawText: rawText)
        finishSession(finalText: finalText)
    }

    // MARK: - Polish Pipeline

    private func runPolishPipeline(rawText: String) async -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Choose polish options based on mode
        let streamFastActive = isStreamingSession && settings.streamFastEnabled
        let polishOptions = streamFastActive
            ? CorrectionOptions.preset(.streamFast)
            : settings.correctionOptions

        // Resolve correction provider
        let corrProvider = CorrectionProviderResolver.resolve(
            for: settings.selectedCorrectionProvider,
            keyStore: keyStore
        ) ?? CorrectionProviderResolver.firstAvailable(keyStore: keyStore)

        guard let corrProvider, settings.correctionEnabled, polishOptions.isEnabled else {
            return trimmed
        }

        state = .finalizing
        bridge.setDictationState(.finalizing, sessionId: sessionId)
        darwin.post(.stateChanged)

        do {
            let pipeline = CorrectionPipeline(provider: corrProvider)
            let transcription = TranscriptionResult(
                text: trimmed,
                language: .unknown,
                isFinal: true
            )
            let corrected = try await pipeline.process(
                transcription: transcription,
                context: .empty,
                options: polishOptions
            )
            return corrected.correctedText
        } catch {
            // Polish failed -- return raw text
            return trimmed
        }
    }

    // MARK: - Session Cleanup

    private func finishSession(finalText: String) {
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            sequenceCounter += 1
            latestPartialText = text
            bridge.writeStreamingPartial(
                text,
                sequence: sequenceCounter,
                isFinal: true,
                sessionId: sessionId
            )
            darwin.post(.transcriptionReady)
        }

        state = .idle
        bridge.setDictationState(.idle, sessionId: sessionId)
        darwin.post(.stateChanged)

        currentProvider = nil
        startIdleTimeout()
    }

    private func transitionToError(_ message: String) {
        state = .error(message)
        bridge.setDictationState(.error, sessionId: sessionId)
        darwin.post(.stateChanged)

        // Auto-dismiss error after 5 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if case .error = self.state {
                self.state = .idle
                self.bridge.setDictationState(.idle, sessionId: "")
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

    // MARK: - Idle Timeout (configurable via ResidenceMode)

    private func startIdleTimeout() {
        idleTimeoutTask?.cancel()

        let timeout = bridge.residenceMode.timeoutSeconds
        guard timeout.isFinite else { return } // Never -> no timeout

        idleTimeoutTask = Task { [weak self] in
            let nanoseconds = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.audioService?.stopRecording()
                self.audioService = nil
            }
        }
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
        recordingTask = nil
        streamingResultTask = nil
        heartbeatTask = nil
        idleTimeoutTask = nil

        audioService?.stopRecording()
        audioService = nil
        currentProvider = nil
    }
}
