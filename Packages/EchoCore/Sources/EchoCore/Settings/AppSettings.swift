import Foundation

/// Central app settings manager using UserDefaults with App Groups support
public final class AppSettings: @unchecked Sendable {
    public static let appGroupIdentifier = "group.com.xianggui.echo.shared"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppSettings.appGroupIdentifier)
            ?? .standard
    }

    // MARK: - ASR Settings

    /// Currently selected ASR provider ID
    public var selectedASRProvider: String {
        get { defaults.string(forKey: Keys.selectedASRProvider) ?? "apple_speech" }
        set { defaults.set(newValue, forKey: Keys.selectedASRProvider) }
    }

    /// Whether to use streaming mode when available
    public var preferStreaming: Bool {
        get { defaults.bool(forKey: Keys.preferStreaming, default: true) }
        set { defaults.set(newValue, forKey: Keys.preferStreaming) }
    }

    // MARK: - LLM Correction Settings

    /// Whether LLM correction is enabled
    public var correctionEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionEnabled, default: true) }
        set { defaults.set(newValue, forKey: Keys.correctionEnabled) }
    }

    /// Allow homophone fixes during Auto Edit
    public var correctionHomophonesEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionHomophones, default: true) }
        set { defaults.set(newValue, forKey: Keys.correctionHomophones) }
    }

    /// Allow punctuation fixes during Auto Edit
    public var correctionPunctuationEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionPunctuation, default: true) }
        set { defaults.set(newValue, forKey: Keys.correctionPunctuation) }
    }

    /// Allow formatting/segmentation fixes during Auto Edit
    public var correctionFormattingEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionFormatting, default: true) }
        set { defaults.set(newValue, forKey: Keys.correctionFormatting) }
    }

    public var correctionOptions: CorrectionOptions {
        CorrectionOptions(
            enableHomophones: correctionHomophonesEnabled,
            enablePunctuation: correctionPunctuationEnabled,
            enableFormatting: correctionFormattingEnabled
        )
    }

    /// Currently selected correction provider ID
    public var selectedCorrectionProvider: String {
        get { defaults.string(forKey: Keys.selectedCorrectionProvider) ?? "openai_gpt" }
        set { defaults.set(newValue, forKey: Keys.selectedCorrectionProvider) }
    }

    // MARK: - Keyboard Settings

    /// Current keyboard input mode
    public var defaultInputMode: String {
        get { defaults.string(forKey: Keys.defaultInputMode) ?? "english" }
        set { defaults.set(newValue, forKey: Keys.defaultInputMode) }
    }

    /// Whether haptic feedback is enabled
    public var hapticFeedbackEnabled: Bool {
        get { defaults.bool(forKey: Keys.hapticFeedback, default: true) }
        set { defaults.set(newValue, forKey: Keys.hapticFeedback) }
    }

    /// Whether auto-capitalization is enabled
    public var autoCapitalizationEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoCapitalization, default: true) }
        set { defaults.set(newValue, forKey: Keys.autoCapitalization) }
    }

    // MARK: - Voice Input IPC

    /// Write transcription result for keyboard extension to read
    public var pendingTranscription: String? {
        get { defaults.string(forKey: Keys.pendingTranscription) }
        set { defaults.set(newValue, forKey: Keys.pendingTranscription) }
    }

    /// Clear pending transcription after keyboard reads it
    public func clearPendingTranscription() {
        defaults.removeObject(forKey: Keys.pendingTranscription)
    }

    // MARK: - Keys

    private enum Keys {
        static let selectedASRProvider = "echo.asr.selected"
        static let preferStreaming = "echo.asr.streaming"
        static let correctionEnabled = "echo.correction.enabled"
        static let selectedCorrectionProvider = "echo.correction.selected"
        static let correctionHomophones = "echo.correction.homophones"
        static let correctionPunctuation = "echo.correction.punctuation"
        static let correctionFormatting = "echo.correction.formatting"
        static let defaultInputMode = "echo.keyboard.mode"
        static let hapticFeedback = "echo.keyboard.haptic"
        static let autoCapitalization = "echo.keyboard.autocap"
        static let pendingTranscription = "echo.ipc.pending_transcription"
    }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) != nil ? bool(forKey: key) : defaultValue
    }
}
