import Foundation
#if os(iOS)
@preconcurrency import AVFoundation
#endif

/// Service that manages background dictation sessions triggered by the keyboard extension.
///
/// Flow:
/// 1. Keyboard posts `.dictationStart` via Darwin notification
/// 2. This service receives it, resolves an ASR provider, starts recording + streaming
/// 3. Streaming partials are written to `AppGroupBridge` + `.transcriptionReady` posted
/// 4. Keyboard reads partials and injects text incrementally
/// 5. Keyboard posts `.dictationStop` → recording stops, final result written
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

   /// How long to keep the audio session alive after dictation stops.
   public var idleTimeoutInterval: TimeInterval = 300 // 5 minutes

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

   // Darwin observation tokens
   private var startToken: DarwinNotificationCenter.ObservationToken?
   private var stopToken: DarwinNotificationCenter.ObservationToken?
   private var isActive = false

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

       // Write initial idle state
       bridge.setEngineRunning(true)
       bridge.setDictationState(.idle, sessionId: "")
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
    /// - This keeps existing live recording sessions intact, but recovers stale
    ///   non-functional recording states for background/foreground transitions.
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

        // Cancel idle timeout if we're restarting
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil

       let newSessionId = UUID().uuidString
       sessionId = newSessionId
       sequenceCounter = 0
       latestPartialText = ""
       bridge.clearStreamingData()

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
       guard provider.supportsStreaming else {
           transitionToError("Selected provider does not support streaming")
           return
       }

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
       }

       // Start streaming from provider
       let stream = provider.startStreaming()

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

       // Task: feed audio chunks to provider
       recordingTask = Task { [weak self] in
           for await chunk in audio.audioChunks {
               guard !Task.isCancelled else { break }
               do {
                   try await provider.feedAudio(chunk)
               } catch {
                   // Non-fatal: log and continue
                   print("[BackgroundDictation] feedAudio error: \(error)")
               }
           }
       }

       // Task: consume streaming results and write to bridge
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

    private func performStopDictation() async {
        guard state == .recording || state == .transcribing else { return }

       state = .finalizing
       bridge.setRecording(false)
       bridge.setDictationState(.finalizing, sessionId: sessionId)
       darwin.post(.stateChanged)

       // Stop feeding audio to the ASR provider, but keep the engine running
       // with an idle (noop) tap. This prevents iOS from suspending the app,
       // so it can receive the next Darwin `.dictationStart` without the user
       // having to manually return to the app.
       recordingTask?.cancel()
       recordingTask = nil
       audioService?.idleEngine()
       print("[BackgroundDictation] Engine transitioned to idle (kept alive)")

       // Get final result from provider
       if let provider = currentProvider {
           do {
               if let finalResult = try await provider.stopStreaming() {
                   let text = finalResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
               }
           } catch {
               print("[BackgroundDictation] stopStreaming error: \(error)")
           }
       }

       streamingResultTask?.cancel()
       streamingResultTask = nil

       state = .idle
       bridge.setRecording(false)
       bridge.setDictationState(.idle, sessionId: sessionId)
       darwin.post(.stateChanged)

       // Release provider but keep audioService alive (engine still running)
       currentProvider = nil

       // Start idle timeout to eventually release audio engine & session
       startIdleTimeout()
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

       // Auto-dismiss error after 5 seconds so the overlay doesn't persist
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

   // MARK: - Idle Timeout

   private func startIdleTimeout() {
       idleTimeoutTask?.cancel()
       idleTimeoutTask = Task { [weak self] in
           guard let self else { return }
           let timeout = UInt64(self.idleTimeoutInterval * 1_000_000_000)
           try? await Task.sleep(nanoseconds: timeout)
           guard !Task.isCancelled else { return }

           await MainActor.run {
               // Idle timeout fired — fully stop the audio engine and release the service.
               // This ends the background-audio mode and iOS may suspend the app.
               self.audioService?.stopRecording()
               self.audioService = nil
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
       print("[BackgroundDictation] All tasks cancelled, audio engine stopped")
   }
}
