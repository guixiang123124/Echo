import Foundation

/// Bridge for communication between the main app and keyboard extension via App Groups
public struct AppGroupBridge: Sendable {
    public enum LaunchIntent: String, Sendable {
        case voice
        case settings
    }

    private enum Keys {
        static let pendingLaunchIntent = "echo.keyboard.pendingLaunchIntent"
        static let pendingLaunchIntentAt = "echo.keyboard.pendingLaunchIntentAt"
        static let lastLaunchAckAt = "echo.keyboard.lastLaunchAckAt"
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
}
