import Foundation

/// Bridge for communication between the main app and keyboard extension via App Groups
public struct AppGroupBridge: Sendable {
    private let settings: AppSettings

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
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

    /// URL scheme for keyboard to open the main app for voice input
    public static var voiceInputURL: URL {
        URL(string: "echo://voice")!
    }

    /// URL scheme for keyboard to open settings
    public static var settingsURL: URL {
        URL(string: "echo://settings")!
    }
}
