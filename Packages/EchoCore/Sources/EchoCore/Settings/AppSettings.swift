import Foundation

/// Central app settings manager using UserDefaults with App Groups support
public final class AppSettings: @unchecked Sendable {
    public static let appGroupIdentifier = "group.com.xianggui.echo.shared"
    private static let supportedASRProviders: Set<String> = ["openai_whisper", "deepgram", "volcano"]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppSettings.appGroupIdentifier)
            ?? .standard

        // Sane defaults for a fresh install. Keep existing user choices intact.
        if self.defaults.object(forKey: Keys.selectedASRProvider) == nil {
            self.defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
        } else {
            let raw = self.defaults.string(forKey: Keys.selectedASRProvider) ?? "openai_whisper"
            if !Self.supportedASRProviders.contains(raw) {
                self.defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
            }
        }
        if self.defaults.object(forKey: Keys.preferStreaming) == nil {
            // OpenAI transcription is batch. Default to non-streaming to avoid confusing UX.
            self.defaults.set(false, forKey: Keys.preferStreaming)
        }
        if self.defaults.object(forKey: Keys.streamFastEnabled) == nil {
            self.defaults.set(true, forKey: Keys.streamFastEnabled)
        }
        if self.defaults.object(forKey: Keys.autoEditPreset) == nil {
            self.defaults.set(AutoEditPreset.smartPolish.rawValue, forKey: Keys.autoEditPreset)
        }
        if self.defaults.object(forKey: Keys.autoEditApplyMode) == nil {
            self.defaults.set(AutoEditApplyMode.autoReplace.rawValue, forKey: Keys.autoEditApplyMode)
        }
        if self.defaults.object(forKey: Keys.correctionRemoveFiller) == nil {
            self.defaults.set(true, forKey: Keys.correctionRemoveFiller)
        }
        if self.defaults.object(forKey: Keys.correctionRemoveRepetition) == nil {
            self.defaults.set(true, forKey: Keys.correctionRemoveRepetition)
        }
        if self.defaults.object(forKey: Keys.correctionRewriteIntensity) == nil {
            self.defaults.set(RewriteIntensity.light.rawValue, forKey: Keys.correctionRewriteIntensity)
        }
        if self.defaults.object(forKey: Keys.correctionTranslationEnabled) == nil {
            self.defaults.set(false, forKey: Keys.correctionTranslationEnabled)
        }
        if self.defaults.object(forKey: Keys.correctionTranslationTarget) == nil {
            self.defaults.set(TranslationTargetLanguage.keepSource.rawValue, forKey: Keys.correctionTranslationTarget)
        }
        if self.defaults.object(forKey: Keys.correctionStructuredOutput) == nil {
            self.defaults.set(StructuredOutputStyle.off.rawValue, forKey: Keys.correctionStructuredOutput)
        }
        if self.defaults.object(forKey: Keys.dictionaryAutoLearnEnabled) == nil {
            self.defaults.set(true, forKey: Keys.dictionaryAutoLearnEnabled)
        }
        if self.defaults.object(forKey: Keys.dictionaryAutoLearnRequireReview) == nil {
            self.defaults.set(true, forKey: Keys.dictionaryAutoLearnRequireReview)
        }
    }

    // MARK: - ASR Settings

    /// Currently selected ASR provider ID
    public var selectedASRProvider: String {
        get {
            let raw = defaults.string(forKey: Keys.selectedASRProvider) ?? "openai_whisper"
            return Self.supportedASRProviders.contains(raw) ? raw : "openai_whisper"
        }
        set {
            let normalized = Self.supportedASRProviders.contains(newValue) ? newValue : "openai_whisper"
            defaults.set(normalized, forKey: Keys.selectedASRProvider)
            if normalized == "openai_whisper" {
                preferStreaming = false
            } else if !preferStreaming {
                preferStreaming = true
            }
        }
    }

    /// Whether to use streaming mode when available
    public var preferStreaming: Bool {
        get { defaults.bool(forKey: Keys.preferStreaming, default: false) }
        set { defaults.set(newValue, forKey: Keys.preferStreaming) }
    }

    /// Whether StreamFast behavior is enabled (fast finalize + async polish)
    public var streamFastEnabled: Bool {
        get { defaults.bool(forKey: Keys.streamFastEnabled, default: true) }
        set { defaults.set(newValue, forKey: Keys.streamFastEnabled) }
    }

    // MARK: - LLM Correction Settings

    /// Whether LLM correction is enabled
    public var correctionEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionEnabled, default: true) }
        set { defaults.set(newValue, forKey: Keys.correctionEnabled) }
    }

    public var autoEditPreset: AutoEditPreset {
        get {
            guard let rawValue = defaults.string(forKey: Keys.autoEditPreset),
                  let preset = AutoEditPreset(rawValue: rawValue) else {
                return .smartPolish
            }
            return preset
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.autoEditPreset)
            applyAutoEditPreset(newValue)
        }
    }

    public var autoEditApplyMode: AutoEditApplyMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.autoEditApplyMode),
                  let mode = AutoEditApplyMode(rawValue: rawValue) else {
                return .autoReplace
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.autoEditApplyMode)
        }
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

    /// Remove filler words during Auto Edit.
    public var correctionRemoveFillerEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionRemoveFiller, default: true) }
        set { defaults.set(newValue, forKey: Keys.correctionRemoveFiller) }
    }

    /// Remove duplicate phrases during Auto Edit.
    public var correctionRemoveRepetitionEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionRemoveRepetition, default: true) }
        set { defaults.set(newValue, forKey: Keys.correctionRemoveRepetition) }
    }

    public var correctionRewriteIntensity: RewriteIntensity {
        get {
            guard let rawValue = defaults.string(forKey: Keys.correctionRewriteIntensity),
                  let value = RewriteIntensity(rawValue: rawValue) else {
                return .light
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.correctionRewriteIntensity)
        }
    }

    public var correctionTranslationEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionTranslationEnabled, default: false) }
        set { defaults.set(newValue, forKey: Keys.correctionTranslationEnabled) }
    }

    public var correctionTranslationTarget: TranslationTargetLanguage {
        get {
            guard let rawValue = defaults.string(forKey: Keys.correctionTranslationTarget),
                  let value = TranslationTargetLanguage(rawValue: rawValue) else {
                return .keepSource
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.correctionTranslationTarget)
        }
    }

    public var correctionStructuredOutputStyle: StructuredOutputStyle {
        get {
            guard let rawValue = defaults.string(forKey: Keys.correctionStructuredOutput),
                  let value = StructuredOutputStyle(rawValue: rawValue) else {
                return .off
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.correctionStructuredOutput)
        }
    }

    public var correctionOptions: CorrectionOptions {
        CorrectionOptions(
            enableHomophones: correctionHomophonesEnabled,
            enablePunctuation: correctionPunctuationEnabled,
            enableFormatting: correctionFormattingEnabled,
            enableRemoveFillerWords: correctionRemoveFillerEnabled,
            enableRemoveRepetitions: correctionRemoveRepetitionEnabled,
            rewriteIntensity: correctionRewriteIntensity,
            enableTranslation: correctionTranslationEnabled,
            translationTargetLanguage: correctionTranslationTarget,
            structuredOutputStyle: correctionStructuredOutputStyle
        )
    }

    public var dictionaryAutoLearnEnabled: Bool {
        get { defaults.bool(forKey: Keys.dictionaryAutoLearnEnabled, default: true) }
        set { defaults.set(newValue, forKey: Keys.dictionaryAutoLearnEnabled) }
    }

    /// When enabled, auto-learned terms stay as review candidates and are not applied automatically.
    public var dictionaryAutoLearnRequireReview: Bool {
        get { defaults.bool(forKey: Keys.dictionaryAutoLearnRequireReview, default: true) }
        set { defaults.set(newValue, forKey: Keys.dictionaryAutoLearnRequireReview) }
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

    // MARK: - Cloud Sync

    public var cloudSyncEnabled: Bool {
        get { defaults.bool(forKey: Keys.cloudSyncEnabled, default: true) }
        set { defaults.set(newValue, forKey: Keys.cloudSyncEnabled) }
    }

    public var cloudSyncBaseURL: String {
        get { defaults.string(forKey: Keys.cloudSyncBaseURL) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.cloudSyncBaseURL) }
    }

    public var cloudUploadAudioEnabled: Bool {
        get { defaults.bool(forKey: Keys.cloudUploadAudio, default: false) }
        set { defaults.set(newValue, forKey: Keys.cloudUploadAudio) }
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
        static let streamFastEnabled = "echo.asr.streamFastEnabled"
        static let correctionEnabled = "echo.correction.enabled"
        static let autoEditPreset = "echo.correction.preset"
        static let autoEditApplyMode = "echo.correction.applyMode"
        static let selectedCorrectionProvider = "echo.correction.selected"
        static let correctionHomophones = "echo.correction.homophones"
        static let correctionPunctuation = "echo.correction.punctuation"
        static let correctionFormatting = "echo.correction.formatting"
        static let correctionRemoveFiller = "echo.correction.removeFiller"
        static let correctionRemoveRepetition = "echo.correction.removeRepetition"
        static let correctionRewriteIntensity = "echo.correction.rewriteIntensity"
        static let correctionTranslationEnabled = "echo.correction.translation.enabled"
        static let correctionTranslationTarget = "echo.correction.translation.target"
        static let correctionStructuredOutput = "echo.correction.structuredOutput"
        static let dictionaryAutoLearnEnabled = "echo.dictionary.autoLearn.enabled"
        static let dictionaryAutoLearnRequireReview = "echo.dictionary.autoLearn.requireReview"
        static let defaultInputMode = "echo.keyboard.mode"
        static let hapticFeedback = "echo.keyboard.haptic"
        static let autoCapitalization = "echo.keyboard.autocap"
        static let pendingTranscription = "echo.ipc.pending_transcription"
        static let cloudSyncEnabled = "echo.cloud.sync.enabled"
        static let cloudSyncBaseURL = "echo.cloud.sync.baseURL"
        static let cloudUploadAudio = "echo.cloud.sync.uploadAudio"
    }

    private func applyAutoEditPreset(_ preset: AutoEditPreset) {
        guard preset != .custom else { return }
        let options = CorrectionOptions.preset(preset)
        correctionEnabled = preset != .pureTranscript
        correctionHomophonesEnabled = options.enableHomophones
        correctionPunctuationEnabled = options.enablePunctuation
        correctionFormattingEnabled = options.enableFormatting
        correctionRemoveFillerEnabled = options.enableRemoveFillerWords
        correctionRemoveRepetitionEnabled = options.enableRemoveRepetitions
        correctionRewriteIntensity = options.rewriteIntensity
        correctionTranslationEnabled = options.enableTranslation
        correctionTranslationTarget = options.translationTargetLanguage
        correctionStructuredOutputStyle = options.structuredOutputStyle
    }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) != nil ? bool(forKey: key) : defaultValue
    }
}
