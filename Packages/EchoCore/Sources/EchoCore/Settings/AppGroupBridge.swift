import Foundation

/// Bridge for communication between the main app and keyboard extension via App Groups
public struct AppGroupBridge: Sendable {
    public enum LaunchIntent: String, Sendable {
        case voice
        case settings
        case voiceControl // Start/Stop control without jump
    }

    public enum VoiceCommand: String, Sendable {
        case start
        case stop
    }

    public enum ResidenceMode: String, Sendable, CaseIterable {
        case never
        case fifteenMinutes = "15m"
        case twelveHours = "12h"

        public var displayName: String {
            switch self {
            case .never: return "Never"
            case .fifteenMinutes: return "15 minutes"
            case .twelveHours: return "12 hours"
            }
        }

        public var timeoutSeconds: TimeInterval {
            switch self {
            case .never: return .infinity
            case .fifteenMinutes: return 15 * 60
            case .twelveHours: return 12 * 60 * 60
            }
        }
    }

    /// Dictation state for cross-process status tracking (more granular than isRecording Bool).
    public enum DictationState: String, Sendable {
        case idle, recording, transcribing, finalizing, error
    }

    /// Streaming partial text shared via App Group UserDefaults.
    public struct StreamingPartial: Sendable {
        public let text: String
        public let sequence: Int
        public let isFinal: Bool
        public let sessionId: String
    }

    private enum Keys {
        static let pendingLaunchIntent = "echo.keyboard.pendingLaunchIntent"
        static let pendingLaunchIntentAt = "echo.keyboard.pendingLaunchIntentAt"
        static let lastLaunchAckAt = "echo.keyboard.lastLaunchAckAt"
        // Engine state
        static let engineRunning = "echo.engine.running"
        static let engineRunningAt = "echo.engine.runningAt"
        static let engineHeartbeat = "echo.engine.heartbeat"
        // Voice control
        static let voiceCommand = "echo.engine.voiceCommand"
        static let voiceCommandAt = "echo.engine.voiceCommandAt"
        // Recording state (synced from main app)
        static let isRecording = "echo.engine.isRecording"
        // Residence
        static let residenceMode = "echo.engine.residenceMode"
        // Dictation state
        static let dictationState = "echo.dictation.state"
        static let dictationSessionId = "echo.dictation.sessionId"
        // Streaming partial
        static let streamingText = "echo.streaming.text"
        static let streamingSequence = "echo.streaming.sequence"
        static let streamingIsFinal = "echo.streaming.isFinal"
        static let streamingSessionId = "echo.streaming.sessionId"
    }

    private let settings: AppSettings

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    private var bridgeDefaults: UserDefaults {
        UserDefaults(suiteName: AppSettings.appGroupIdentifier) ?? .standard
    }

    /// Write transcription result for the keyboard extension to read
    public func sendTranscriptionToKeyboard(_ text: String) {
        settings.pendingTranscription = text
    }

    /// Read pending transcription (called by keyboard extension)
    public func receivePendingTranscription() -> String? {
        let text = settings.pendingTranscription
        if text != nil {
            settings.clearPendingTranscription()
        }
        return text
    }

    /// Check if there's a pending transcription
    public var hasPendingTranscription: Bool {
        settings.pendingTranscription != nil
    }

    /// Record keyboard-triggered app launch intent so the app can recover
    /// even if URL callback timing is flaky on some host app states.
    public func setPendingLaunchIntent(_ intent: LaunchIntent) {
        bridgeDefaults.removeObject(forKey: Keys.lastLaunchAckAt)
        bridgeDefaults.set(intent.rawValue, forKey: Keys.pendingLaunchIntent)
        bridgeDefaults.set(Date().timeIntervalSince1970, forKey: Keys.pendingLaunchIntentAt)
        bridgeDefaults.synchronize()
    }

    /// Consume launch intent if it is recent enough.
    public func consumePendingLaunchIntent(maxAge: TimeInterval = 30) -> LaunchIntent? {
        defer { clearPendingLaunchIntent() }
        guard let raw = bridgeDefaults.string(forKey: Keys.pendingLaunchIntent),
              let intent = LaunchIntent(rawValue: raw) else {
            return nil
        }
        let createdAt = bridgeDefaults.double(forKey: Keys.pendingLaunchIntentAt)
        guard createdAt > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - createdAt
        guard age >= 0, age <= maxAge else { return nil }
        return intent
    }

    public func clearPendingLaunchIntent() {
        bridgeDefaults.removeObject(forKey: Keys.pendingLaunchIntent)
        bridgeDefaults.removeObject(forKey: Keys.pendingLaunchIntentAt)
        bridgeDefaults.synchronize()
    }

    /// Mark that the app has acknowledged a keyboard launch request.
    public func markLaunchAcknowledged() {
        bridgeDefaults.set(Date().timeIntervalSince1970, forKey: Keys.lastLaunchAckAt)
        bridgeDefaults.synchronize()
    }

    /// Returns true if the app acknowledged a keyboard launch recently.
    public func hasRecentLaunchAcknowledgement(maxAge: TimeInterval = 8) -> Bool {
        let ackAt = bridgeDefaults.double(forKey: Keys.lastLaunchAckAt)
        guard ackAt > 0 else { return false }
        let age = Date().timeIntervalSince1970 - ackAt
        return age >= 0 && age <= maxAge
    }

    /// Returns true when the pending launch intent still exists and is recent.
    public func hasRecentPendingLaunchIntent(maxAge: TimeInterval = 30) -> Bool {
        guard bridgeDefaults.string(forKey: Keys.pendingLaunchIntent) != nil else { return false }
        let createdAt = bridgeDefaults.double(forKey: Keys.pendingLaunchIntentAt)
        guard createdAt > 0 else { return false }
        let age = Date().timeIntervalSince1970 - createdAt
        return age >= 0 && age <= maxAge
    }

    /// Quick check used by keyboard UI to ensure shared app-group storage is available.
    public static var hasSharedContainerAccess: Bool {
        UserDefaults(suiteName: AppSettings.appGroupIdentifier) != nil
    }

    /// URL scheme for keyboard to open the main app for voice input
    public static var voiceInputURL: URL {
        URL(string: "echo://voice")!
    }

    /// URL scheme for keyboard to open settings
    public static var settingsURL: URL {
        URL(string: "echo://settings")!
    }

    // MARK: - Engine State Management

    /// Mark the voice engine as running (called by main app when engine starts)
    public func setEngineRunning(_ running: Bool) {
        bridgeDefaults.set(running, forKey: Keys.engineRunning)
        if running {
            bridgeDefaults.set(Date().timeIntervalSince1970, forKey: Keys.engineRunningAt)
        } else {
            bridgeDefaults.removeObject(forKey: Keys.engineRunningAt)
        }
        bridgeDefaults.synchronize()
    }

    /// Check if the voice engine is currently running
    public var isEngineRunning: Bool {
        // Check if running flag is set
        guard bridgeDefaults.bool(forKey: Keys.engineRunning) else { return false }

        // Check residence timeout
        let residenceMode = self.residenceMode
        let runningAt = bridgeDefaults.double(forKey: Keys.engineRunningAt)
        guard runningAt > 0 else { return false }

        let age = Date().timeIntervalSince1970 - runningAt
        return age < residenceMode.timeoutSeconds
    }

    /// Update engine heartbeat (called periodically by main app)
    public func updateEngineHeartbeat() {
        bridgeDefaults.set(Date().timeIntervalSince1970, forKey: Keys.engineHeartbeat)
        bridgeDefaults.synchronize()
    }

    /// Check if engine heartbeat is recent (engine is alive)
    public var isEngineHealthy: Bool {
        let heartbeat = bridgeDefaults.double(forKey: Keys.engineHeartbeat)
        guard heartbeat > 0 else { return false }
        let age = Date().timeIntervalSince1970 - heartbeat
        // Heartbeat timeout: 30 seconds
        return age < 30 && isEngineRunning
    }

    /// Check if voice recording is currently in progress (synced from main app)
    public var isRecording: Bool {
        bridgeDefaults.bool(forKey: Keys.isRecording)
    }

    /// Set recording state (called by main app)
    public func setRecording(_ recording: Bool) {
        bridgeDefaults.set(recording, forKey: Keys.isRecording)
        bridgeDefaults.synchronize()
    }

    // MARK: - Voice Control Commands

    /// Send a voice command from keyboard to main app (Start/Stop)
    public func sendVoiceCommand(_ command: VoiceCommand) {
        bridgeDefaults.set(command.rawValue, forKey: Keys.voiceCommand)
        bridgeDefaults.set(Date().timeIntervalSince1970, forKey: Keys.voiceCommandAt)
        bridgeDefaults.synchronize()
    }

    /// Consume and return pending voice command
    public func consumeVoiceCommand(maxAge: TimeInterval = 10) -> VoiceCommand? {
        guard let raw = bridgeDefaults.string(forKey: Keys.voiceCommand),
              let command = VoiceCommand(rawValue: raw) else {
            return nil
        }
        let createdAt = bridgeDefaults.double(forKey: Keys.voiceCommandAt)
        guard createdAt > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - createdAt
        guard age >= 0, age <= maxAge else { return nil }

        // Clear after consuming
        bridgeDefaults.removeObject(forKey: Keys.voiceCommand)
        bridgeDefaults.removeObject(forKey: Keys.voiceCommandAt)
        bridgeDefaults.synchronize()

        return command
    }

    // MARK: - Residence Settings

    /// Get/set the residence mode
    public var residenceMode: ResidenceMode {
        get {
            guard let raw = bridgeDefaults.string(forKey: Keys.residenceMode),
                  let mode = ResidenceMode(rawValue: raw) else {
                return .never // Default to Never (permanent residence)
            }
            return mode
        }
        set {
            bridgeDefaults.set(newValue.rawValue, forKey: Keys.residenceMode)
            bridgeDefaults.synchronize()
        }
    }

    // MARK: - Dictation State IPC

    /// Write the current dictation state for the keyboard extension to read.
    public func setDictationState(_ state: DictationState, sessionId: String) {
        bridgeDefaults.set(state.rawValue, forKey: Keys.dictationState)
        bridgeDefaults.set(sessionId, forKey: Keys.dictationSessionId)
        bridgeDefaults.synchronize()
    }

    /// Read the current dictation state written by the main app.
    public func readDictationState() -> (state: DictationState, sessionId: String)? {
        guard let raw = bridgeDefaults.string(forKey: Keys.dictationState),
              let state = DictationState(rawValue: raw) else {
            return nil
        }
        let sessionId = bridgeDefaults.string(forKey: Keys.dictationSessionId) ?? ""
        return (state, sessionId)
    }

    // MARK: - Streaming Partial IPC

    /// Write a streaming partial transcription result for the keyboard to read.
    public func writeStreamingPartial(_ text: String, sequence: Int, isFinal: Bool, sessionId: String) {
        bridgeDefaults.set(text, forKey: Keys.streamingText)
        bridgeDefaults.set(sequence, forKey: Keys.streamingSequence)
        bridgeDefaults.set(isFinal, forKey: Keys.streamingIsFinal)
        bridgeDefaults.set(sessionId, forKey: Keys.streamingSessionId)
        bridgeDefaults.synchronize()
    }

    /// Read the latest streaming partial written by the main app.
    public func readStreamingPartial() -> StreamingPartial? {
        guard let text = bridgeDefaults.string(forKey: Keys.streamingText) else {
            return nil
        }
        let sequence = bridgeDefaults.integer(forKey: Keys.streamingSequence)
        let isFinal = bridgeDefaults.bool(forKey: Keys.streamingIsFinal)
        let sessionId = bridgeDefaults.string(forKey: Keys.streamingSessionId) ?? ""
        return StreamingPartial(text: text, sequence: sequence, isFinal: isFinal, sessionId: sessionId)
    }

    /// Clear all streaming data after consumption or session end.
    public func clearStreamingData() {
        bridgeDefaults.removeObject(forKey: Keys.streamingText)
        bridgeDefaults.removeObject(forKey: Keys.streamingSequence)
        bridgeDefaults.removeObject(forKey: Keys.streamingIsFinal)
        bridgeDefaults.removeObject(forKey: Keys.streamingSessionId)
        bridgeDefaults.synchronize()
    }

    // MARK: - Heartbeat (unified naming)

    /// Write a heartbeat timestamp (alias for updateEngineHeartbeat).
    public func writeHeartbeat() {
        updateEngineHeartbeat()
    }

    /// Check if a recent heartbeat exists within the given max age.
    public func hasRecentHeartbeat(maxAge: TimeInterval = 6) -> Bool {
        let heartbeat = bridgeDefaults.double(forKey: Keys.engineHeartbeat)
        guard heartbeat > 0 else { return false }
        let age = Date().timeIntervalSince1970 - heartbeat
        return age >= 0 && age <= maxAge
    }
}
