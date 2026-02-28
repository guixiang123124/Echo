import Foundation
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// Service that manages background dictation sessions triggered by the keyboard extension.
///
/// Flow:
/// 1. Keyboard posts `.dictationStart` via Darwin notification
/// 2. This service receives it, resolves an ASR provider, starts recording/streaming
/// 3. Streaming partials are written to `AppGroupBridge` + `.transcriptionReady` posted
/// 4. Keyboard reads partials and injects text incrementally
/// 5. Keyboard posts `.dictationStop` → recording stops, transcribe/finalize → polish -> final text
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

   // Darwin observation tokens
   private var startToken: DarwinNotificationCenter.ObservationToken?
   private var stopToken: DarwinNotificationCenter.ObservationToken?

   // Auth session reference for provider resolution
   private weak var authSession: EchoAuthSession?

   // Debounce: ignore rapid start/stop within this window
   private var lastToggleTime: Date = .distantPast
   private let debounceInterval: TimeInterval = 0.5

   private var isActive = false

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
       if isActive {
           self.authSession = authSession
           return
       }

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

       // Write initial engine/dictation state
       bridge.setEngineRunning(true)
       bridge.setDictationState(.idle, sessionId: "")
       bridge.clearStreamingData()
       bridge.writeHeartbeat()
       startHeartbeat()
       isActive = true
   }

   /// Stop listening and clean up. Call when app is about to terminate.
   public func deactivate() {
       isActive = false
       if let startToken { darwin.removeObservation(startToken) }
       if let stopToken { darwin.removeObservation(stopToken) }
       startToken = nil
       stopToken = nil

       cancelAllTasks()
       bridge.clearStreamingData()
       bridge.setEngineRunning(false)
       bridge.setRecording(false)
       bridge.setDictationState(.idle, sessionId: "")
       state = .idle
   }

   // MARK: - Public API

   /// Start a dictation session programmatically (e.g. from the voice recording view).
   public func startDictation() async {
       await performStartDictation()
   }

   /// Start/ensure dictation when triggered from keyboard voice intent.
   ///
   /// Keeps active sessions when possible, and recovers stale non-functional sessions
   /// for background/foreground transitions.
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
           break
       }
   }

   // MARK: - Darwin Notification Handlers

   private func handleDictationStartRequest() async {
       guard debounceCheck() else { return }

       switch state {
       case .idle, .error:
           await performStartDictation()
       case .recording, .transcribing:
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
       let canStart: Bool = switch state {
       case .idle, .error:
           true
       default:
           false
       }
       guard canStart else {
           print("[BackgroundDictation] start ignored; non-idle state=\(state)")
           return
       }

       idleTimeoutTask?.cancel()
       idleTimeoutTask = nil

       let newSessionId = UUID().uuidString
       sessionId = newSessionId
       sequenceCounter = 0
       latestPartialText = ""
       latestPartialLanguage = .unknown
       streamDidReceiveFinalResult = false
       capturedChunks.removeAll()
       bridge.clearStreamingData()

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

       // Reuse existing AudioCaptureService if engine already running. Otherwise create a fresh one.
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
       }

       let stream = isStreamingSession ? provider.startStreaming() : nil

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

           #if os(iOS)
           do {
               let session = AVAudioSession.sharedInstance()
               try session.setCategory(
                   .playAndRecord,
                   mode: .default,
                   options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
                )
            } catch {
                print("[BackgroundDictation] audio session upgrade failed (non-fatal): \(error)")
            }
           #endif
       }

       bridge.setEngineRunning(true)
       state = .recording
       bridge.setRecording(true)
       bridge.setDictationState(.recording, sessionId: newSessionId)
       darwin.post(.stateChanged)

       if isStreamingSession {
           recordingTask = Task { [weak self] in
               guard let self else { return }
               for await chunk in audio.audioChunks {
                   guard !Task.isCancelled else { break }
                   do {
                       try await self.currentProvider?.feedAudio(chunk)
                   } catch {
                       print("[BackgroundDictation] feedAudio error: \(error)")
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
           recordingTask = Task { [weak self] in
               for await chunk in audio.audioChunks {
                   guard !Task.isCancelled else { break }
                   guard let self else { continue }
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
       bridge.setRecording(false)
       bridge.setDictationState(.finalizing, sessionId: sessionId)
       darwin.post(.stateChanged)

       let currentSessionId = sessionId
       let polishOptions = determinePolishOptions()
       var rawText = latestPartialText.trimmingCharacters(in: .whitespacesAndNewlines)

       recordingTask?.cancel()
       recordingTask = nil

       if let service = audioService, service.isEngineRunning {
           service.idleEngine()
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
                   capturedChunks.removeAll()

                   if !combined.isEmpty {
                       let result = try await provider.transcribe(audio: combined)
                       latestPartialLanguage = result.language
                       let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                       if !text.isEmpty {
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

       if !rawText.isEmpty,
          settings.correctionEnabled,
          polishOptions.isEnabled,
          let correctionProvider = CorrectionProviderResolver.resolve(
              for: settings.selectedCorrectionProvider,
              keyStore: keyStore
          ) ?? CorrectionProviderResolver.firstAvailable(keyStore: keyStore) {
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
       bridge.setRecording(false)
       bridge.setDictationState(.idle, sessionId: currentSessionId)
       darwin.post(.stateChanged)

       currentProvider = nil
       isStreamingSession = false
       streamDidReceiveFinalResult = false
       capturedChunks.removeAll()

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

    private func transitionToError(_ message: String) {
        state = .error(message)
        bridge.setRecording(false)
        bridge.setDictationState(.error, sessionId: sessionId)
        darwin.post(.stateChanged)
       print("[BackgroundDictation] Error: \(message)")

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
                    self.bridge.setDictationState(self.currentBridgeDictationState, sessionId: self.sessionId)
                }
                self.darwin.post(.heartbeat)
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
        }
    }

   // MARK: - Idle Timeout

   private func startIdleTimeout() {
       idleTimeoutTask?.cancel()
       idleTimeoutTask = Task { [weak self] in
           guard let self else { return }
           let timeout = self.bridge.residenceMode.timeoutSeconds
           guard timeout.isFinite else { return }
           let nanos = UInt64(timeout * 1_000_000_000)
           try? await Task.sleep(nanoseconds: nanos)
           guard !Task.isCancelled else { return }

           await MainActor.run {
               self.audioService?.stopRecording()
               self.audioService = nil
               self.bridge.setEngineRunning(false)
               self.bridge.clearStreamingData()
               print("[BackgroundDictation] Idle timeout — audio engine stopped, session deactivated")
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

   private var currentBridgeDictationState: AppGroupBridge.DictationState {
       switch state {
       case .idle:
           return .idle
       case .recording:
           return .recording
       case .transcribing:
           return .transcribing
       case .finalizing:
           return .finalizing
       case .error:
           return .error
       }
   }
}
