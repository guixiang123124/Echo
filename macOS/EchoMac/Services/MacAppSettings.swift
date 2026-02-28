import Foundation
import SwiftUI
import EchoCore

/// macOS-specific settings for Echo
public final class MacAppSettings: ObservableObject {
    public static let shared = MacAppSettings()
    private static let streamCapableProviders: Set<String> = ["volcano", "deepgram"]
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyType = "hotkeyType"
        static let recordingMode = "recordingMode"
        static let selectedASRProvider = "selectedASRProvider"
        static let asrMode = "echo.asr.mode"
        static let streamFastEnabled = "echo.asr.streamFastEnabled"
        static let asrLanguage = "asrLanguage"
        static let openAITranscriptionModel = "echo.asr.openaiModel"
        static let deepgramModel = "echo.asr.deepgramModel"
        static let selectedCorrectionProvider = "selectedCorrectionProvider"
        static let correctionEnabled = "correctionEnabled"
        static let autoEditPreset = "echo.correction.preset"
        static let autoEditApplyMode = "echo.correction.applyMode"
        static let correctionHomophones = "correctionHomophones"
        static let correctionPunctuation = "correctionPunctuation"
        static let correctionFormatting = "correctionFormatting"
        static let correctionRemoveFiller = "echo.correction.removeFiller"
        static let correctionRemoveRepetition = "echo.correction.removeRepetition"
        static let correctionRewriteIntensity = "echo.correction.rewriteIntensity"
        static let correctionTranslationEnabled = "echo.correction.translation.enabled"
        static let correctionTranslationTarget = "echo.correction.translation.target"
        static let correctionStructuredOutput = "echo.correction.structuredOutput"
        static let dictionaryAutoLearnEnabled = "echo.dictionary.autoLearn.enabled"
        static let dictionaryAutoLearnRequireReview = "echo.dictionary.autoLearn.requireReview"
        static let launchAtLogin = "launchAtLogin"
        static let showRecordingPanel = "showRecordingPanel"
        static let playSound = "playSound"
        static let customTerms = "customTerms"
        static let totalWordsTranscribed = "totalWordsTranscribed"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let handsFreeAutoStop = "handsFreeAutoStop"
        static let handsFreeSilenceDuration = "handsFreeSilenceDuration"
        static let handsFreeSilenceThreshold = "handsFreeSilenceThreshold"
        static let handsFreeMinimumDuration = "handsFreeMinimumDuration"
        static let historyRetentionDays = "echo.history.retentionDays"
        static let userId = "echo.user.id"
        static let userDisplayName = "echo.user.displayName"
        static let localUserId = "echo.user.localId"
        static let cloudSyncEnabled = "echo.cloud.sync.enabled"
        static let cloudSyncBaseURL = "echo.cloud.sync.baseURL"
        static let cloudUploadAudio = "echo.cloud.sync.uploadAudio"
        static let apiCallMode = "echo.api.callMode"
    }

    // MARK: - Hotkey Types

    public enum HotkeyType: String, CaseIterable, Identifiable {
        case fn = "fn"
        case rightOption = "rightOption"
        case leftOption = "leftOption"
        case rightCommand = "rightCommand"
        case doubleCommand = "doubleCommand"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .fn:
                return "Fn Key"
            case .rightOption:
                return "Option (Either)"
            case .leftOption:
                return "Option (Either, legacy)"
            case .rightCommand:
                return "Command (Either)"
            case .doubleCommand:
                return "Double-tap Command"
            }
        }

        public var shortDescription: String {
            switch self {
            case .fn:
                return "Press Fn to start/stop"
            case .rightOption:
                return "Press Option to start/stop"
            case .leftOption:
                return "Press Option to start/stop"
            case .rightCommand:
                return "Press Command to start/stop"
            case .doubleCommand:
                return "Double-tap Command to toggle"
            }
        }

        public var keyDisplayName: String {
            switch self {
            case .fn:
                return "Fn"
            case .rightOption, .leftOption:
                return "Option"
            case .rightCommand, .doubleCommand:
                return "Command"
            }
        }
    }

    // MARK: - Recording Modes

    public enum RecordingMode: String, CaseIterable, Identifiable {
        case holdToTalk = "holdToTalk"
        case toggleToTalk = "toggleToTalk"
        case handsFree = "handsFree"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .holdToTalk:
                return "Hold to Talk"
            case .toggleToTalk:
                return "Tap to Toggle"
            case .handsFree:
                return "Hands-Free"
            }
        }

        public var description: String {
            switch self {
            case .holdToTalk:
                return "Hold the hotkey to record, release to transcribe."
            case .toggleToTalk:
                return "Tap once to start, tap again to stop and transcribe."
            case .handsFree:
                return "Tap once to start, tap again to stop. Best for long dictations."
            }
        }
    }

    // MARK: - ASR Modes

    public enum ASRMode: String, CaseIterable, Identifiable {
        case batch
        case stream

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .batch:
                return "Batch"
            case .stream:
                return "Stream (Realtime)"
            }
        }
    }

    // MARK: - Pipeline Presets

    public enum PipelinePreset: String, CaseIterable, Identifiable {
        case domestic
        case whisperOnly
        case whisperPlusEdit
        case custom

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .domestic:
                return "Domestic"
            case .whisperOnly:
                return "Whisper Only"
            case .whisperPlusEdit:
                return "Whisper + Auto Edit"
            case .custom:
                return "Custom"
            }
        }

        public var description: String {
            switch self {
            case .domestic:
                return "Use Volcano Engine for ASR with a domestic LLM for edits."
            case .whisperOnly:
                return "Use Whisper transcription without Auto Edit."
            case .whisperPlusEdit:
                return "Use Whisper for ASR, then optionally apply Auto Edit."
            case .custom:
                return "Manually choose ASR and Auto Edit settings."
            }
        }
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    // MARK: - Initialization

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Set default values if not already set
        if defaults.object(forKey: Keys.hotkeyType) == nil {
            defaults.set(HotkeyType.fn.rawValue, forKey: Keys.hotkeyType)
        }
        if defaults.object(forKey: Keys.recordingMode) == nil {
            defaults.set(RecordingMode.holdToTalk.rawValue, forKey: Keys.recordingMode)
        }
        if defaults.object(forKey: Keys.selectedASRProvider) == nil {
            defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
        } else if !["openai_whisper", "deepgram", "volcano"].contains(defaults.string(forKey: Keys.selectedASRProvider) ?? "") {
            defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
        }
        if defaults.object(forKey: Keys.asrLanguage) == nil {
            defaults.set("auto", forKey: Keys.asrLanguage)
        }
        if defaults.object(forKey: Keys.asrMode) == nil {
            defaults.set(ASRMode.batch.rawValue, forKey: Keys.asrMode)
        }
        if defaults.object(forKey: Keys.streamFastEnabled) == nil {
            defaults.set(true, forKey: Keys.streamFastEnabled)
        }
        if defaults.object(forKey: Keys.openAITranscriptionModel) == nil {
            defaults.set("gpt-4o-transcribe", forKey: Keys.openAITranscriptionModel)
        }
        if defaults.object(forKey: Keys.deepgramModel) == nil {
            defaults.set("nova-3", forKey: Keys.deepgramModel)
        }
        if defaults.object(forKey: Keys.autoEditPreset) == nil {
            defaults.set(AutoEditPreset.smartPolish.rawValue, forKey: Keys.autoEditPreset)
        }
        if defaults.object(forKey: Keys.autoEditApplyMode) == nil {
            defaults.set(AutoEditApplyMode.autoReplace.rawValue, forKey: Keys.autoEditApplyMode)
        }
        if defaults.object(forKey: Keys.correctionEnabled) == nil {
            defaults.set(true, forKey: Keys.correctionEnabled)
        }
        if defaults.object(forKey: Keys.correctionHomophones) == nil {
            defaults.set(true, forKey: Keys.correctionHomophones)
        }
        if defaults.object(forKey: Keys.correctionPunctuation) == nil {
            defaults.set(true, forKey: Keys.correctionPunctuation)
        }
        if defaults.object(forKey: Keys.correctionFormatting) == nil {
            defaults.set(true, forKey: Keys.correctionFormatting)
        }
        if defaults.object(forKey: Keys.correctionRemoveFiller) == nil {
            defaults.set(true, forKey: Keys.correctionRemoveFiller)
        }
        if defaults.object(forKey: Keys.correctionRemoveRepetition) == nil {
            defaults.set(true, forKey: Keys.correctionRemoveRepetition)
        }
        if defaults.object(forKey: Keys.correctionRewriteIntensity) == nil {
            defaults.set(RewriteIntensity.light.rawValue, forKey: Keys.correctionRewriteIntensity)
        }
        if defaults.object(forKey: Keys.correctionTranslationEnabled) == nil {
            defaults.set(false, forKey: Keys.correctionTranslationEnabled)
        }
        if defaults.object(forKey: Keys.correctionTranslationTarget) == nil {
            defaults.set(TranslationTargetLanguage.keepSource.rawValue, forKey: Keys.correctionTranslationTarget)
        }
        if defaults.object(forKey: Keys.correctionStructuredOutput) == nil {
            defaults.set(StructuredOutputStyle.off.rawValue, forKey: Keys.correctionStructuredOutput)
        }
        if defaults.object(forKey: Keys.dictionaryAutoLearnEnabled) == nil {
            defaults.set(true, forKey: Keys.dictionaryAutoLearnEnabled)
        }
        if defaults.object(forKey: Keys.dictionaryAutoLearnRequireReview) == nil {
            defaults.set(true, forKey: Keys.dictionaryAutoLearnRequireReview)
        }
        if defaults.object(forKey: Keys.showRecordingPanel) == nil {
            defaults.set(true, forKey: Keys.showRecordingPanel)
        }
        if defaults.object(forKey: Keys.playSound) == nil {
            defaults.set(true, forKey: Keys.playSound)
        }
        if defaults.object(forKey: Keys.handsFreeAutoStop) == nil {
            defaults.set(true, forKey: Keys.handsFreeAutoStop)
        }
        if defaults.object(forKey: Keys.handsFreeSilenceDuration) == nil {
            defaults.set(1.2, forKey: Keys.handsFreeSilenceDuration)
        }
        if defaults.object(forKey: Keys.handsFreeSilenceThreshold) == nil {
            defaults.set(0.05, forKey: Keys.handsFreeSilenceThreshold)
        }
        if defaults.object(forKey: Keys.handsFreeMinimumDuration) == nil {
            defaults.set(0.8, forKey: Keys.handsFreeMinimumDuration)
        }
        if defaults.object(forKey: Keys.historyRetentionDays) == nil {
            defaults.set(7, forKey: Keys.historyRetentionDays)
        }
        if defaults.object(forKey: Keys.userId) == nil {
            defaults.set(UUID().uuidString, forKey: Keys.userId)
        }
        if defaults.object(forKey: Keys.localUserId) == nil {
            defaults.set(UUID().uuidString, forKey: Keys.localUserId)
        }
        if defaults.object(forKey: Keys.userDisplayName) == nil {
            defaults.set("Local User", forKey: Keys.userDisplayName)
        }
        if defaults.object(forKey: Keys.cloudSyncEnabled) == nil {
            defaults.set(true, forKey: Keys.cloudSyncEnabled)
        }
        let existingCloudBaseURL = defaults.string(forKey: Keys.cloudSyncBaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingCloudBaseURL.isEmpty, let bundled = Self.bundledCloudAPIBaseURL() {
            defaults.set(bundled, forKey: Keys.cloudSyncBaseURL)
        } else if defaults.object(forKey: Keys.cloudSyncBaseURL) == nil {
            defaults.set("", forKey: Keys.cloudSyncBaseURL)
        }
        if defaults.object(forKey: Keys.cloudUploadAudio) == nil {
            defaults.set(false, forKey: Keys.cloudUploadAudio)
        }
    }

    private static func bundledCloudAPIBaseURL() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CLOUD_API_BASE_URL") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    // MARK: - Hotkey Settings

    public var hotkeyType: HotkeyType {
        get {
            guard let rawValue = defaults.string(forKey: Keys.hotkeyType),
                  let type = HotkeyType(rawValue: rawValue) else {
                return .fn
            }
            return type
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.hotkeyType)
        }
    }

    // MARK: - User Profile

    public var currentUserId: String {
        get {
            defaults.string(forKey: Keys.userId) ?? UUID().uuidString
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.userId)
        }
    }

    public var localUserId: String {
        get {
            defaults.string(forKey: Keys.localUserId) ?? UUID().uuidString
        }
        set {
            defaults.set(newValue, forKey: Keys.localUserId)
        }
    }

    public func switchToLocalUser() {
        currentUserId = localUserId
        userDisplayName = "Local User"
    }

    public var userDisplayName: String {
        get {
            defaults.string(forKey: Keys.userDisplayName) ?? "Local User"
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.userDisplayName)
        }
    }

    public var recordingMode: RecordingMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.recordingMode),
                  let mode = RecordingMode(rawValue: rawValue) else {
                return .holdToTalk
            }
            return mode
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.recordingMode)
        }
    }

    public var effectiveRecordingMode: RecordingMode {
        if hotkeyType == .doubleCommand {
            return .toggleToTalk
        }
        return recordingMode
    }

    public var hotkeyHint: String {
        if hotkeyType == .doubleCommand {
            return "Double-tap Command to toggle"
        }

        let keyName = hotkeyType.keyDisplayName
        switch effectiveRecordingMode {
        case .holdToTalk:
            return "Hold \(keyName) to speak"
        case .toggleToTalk:
            return "Tap \(keyName) to start/stop"
        case .handsFree:
            return "Hands-free: tap \(keyName) to start/stop"
        }
    }

    // MARK: - ASR Settings

    public var selectedASRProvider: String {
        get {
            let value = defaults.string(forKey: Keys.selectedASRProvider) ?? "openai_whisper"
            if value != "openai_whisper", value != "deepgram", value != "volcano" {
                return "openai_whisper"
            }
            return value
        }
        set {
            objectWillChange.send()
            let normalized = (newValue == "deepgram" || newValue == "volcano") ? newValue : "openai_whisper"
            defaults.set(normalized, forKey: Keys.selectedASRProvider)
            if normalized == "openai_whisper", asrMode == .stream {
                defaults.set(ASRMode.batch.rawValue, forKey: Keys.asrMode)
            }
        }
    }

    public var asrMode: ASRMode {
        get {
            guard let raw = defaults.string(forKey: Keys.asrMode),
                  let mode = ASRMode(rawValue: raw) else {
                return .batch
            }
            return mode
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.asrMode)
            switch newValue {
            case .batch:
                // Product requirement: switching to Batch defaults to OpenAI.
                defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
            case .stream:
                let provider = defaults.string(forKey: Keys.selectedASRProvider) ?? "openai_whisper"
                if !Self.streamCapableProviders.contains(provider) {
                    // Product requirement: switching to Stream defaults to Volcano.
                    defaults.set("volcano", forKey: Keys.selectedASRProvider)
                }
            }
        }
    }

    public var streamFastEnabled: Bool {
        get { defaults.object(forKey: Keys.streamFastEnabled) == nil ? true : defaults.bool(forKey: Keys.streamFastEnabled) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.streamFastEnabled)
        }
    }

    public var pipelinePreset: PipelinePreset {
        get { currentPipelinePreset() }
        set {
            objectWillChange.send()
            applyPipelinePreset(newValue)
        }
    }

    public var asrLanguage: String {
        get { defaults.string(forKey: Keys.asrLanguage) ?? "auto" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.asrLanguage)
        }
    }

    public var openAITranscriptionModel: String {
        get { defaults.string(forKey: Keys.openAITranscriptionModel) ?? "gpt-4o-transcribe" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.openAITranscriptionModel)
        }
    }

    public var deepgramModel: String {
        get { defaults.string(forKey: Keys.deepgramModel) ?? "nova-3" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.deepgramModel)
        }
    }

    // MARK: - Correction Settings

    public var selectedCorrectionProvider: String {
        get { defaults.string(forKey: Keys.selectedCorrectionProvider) ?? "openai_gpt" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.selectedCorrectionProvider)
        }
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
            objectWillChange.send()
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
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.autoEditApplyMode)
        }
    }

    public var correctionEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionEnabled) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.correctionEnabled)
        }
    }

    public var correctionHomophonesEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionHomophones) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.correctionHomophones)
        }
    }

    public var correctionPunctuationEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionPunctuation) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.correctionPunctuation)
        }
    }

    public var correctionFormattingEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionFormatting) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.correctionFormatting)
        }
    }

    public var correctionRemoveFillerEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionRemoveFiller) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.correctionRemoveFiller)
        }
    }

    public var correctionRemoveRepetitionEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionRemoveRepetition) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.correctionRemoveRepetition)
        }
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
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.correctionRewriteIntensity)
        }
    }

    public var correctionTranslationEnabled: Bool {
        get { defaults.bool(forKey: Keys.correctionTranslationEnabled) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.correctionTranslationEnabled)
        }
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
            objectWillChange.send()
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
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.correctionStructuredOutput)
        }
    }

    public var autoEditOptions: CorrectionOptions {
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
        get { defaults.bool(forKey: Keys.dictionaryAutoLearnEnabled) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.dictionaryAutoLearnEnabled)
        }
    }

    public var dictionaryAutoLearnRequireReview: Bool {
        get { defaults.bool(forKey: Keys.dictionaryAutoLearnRequireReview) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.dictionaryAutoLearnRequireReview)
        }
    }

    // MARK: - General Settings

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.launchAtLogin)
        }
    }

    public var showRecordingPanel: Bool {
        get { defaults.bool(forKey: Keys.showRecordingPanel) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.showRecordingPanel)
        }
    }

    public var historyRetentionDays: Int {
        get {
            let value = defaults.integer(forKey: Keys.historyRetentionDays)
            return value == 0 ? 7 : value
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.historyRetentionDays)
        }
    }

    public var playSoundEffects: Bool {
        get { defaults.bool(forKey: Keys.playSound) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.playSound)
        }
    }

    // MARK: - Cloud Sync

    public var cloudSyncEnabled: Bool {
        get { defaults.bool(forKey: Keys.cloudSyncEnabled) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.cloudSyncEnabled)
        }
    }

    public var cloudSyncBaseURL: String {
        get { defaults.string(forKey: Keys.cloudSyncBaseURL) ?? "" }
        set {
            objectWillChange.send()
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.cloudSyncBaseURL)
        }
    }

    public var cloudUploadAudioEnabled: Bool {
        get { defaults.bool(forKey: Keys.cloudUploadAudio) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.cloudUploadAudio)
        }
    }

    /// How ASR/LLM API calls are routed (client-direct vs backend proxy)
    public var apiCallMode: APICallMode {
        get {
            guard let rawValue = defaults.string(forKey: Keys.apiCallMode),
                  let mode = APICallMode(rawValue: rawValue) else {
                return .clientDirect
            }
            return mode
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Keys.apiCallMode)
        }
    }

    /// Normalize OpenAI model names that may use aliases.
    public func normalizeOpenAIModel() {
        let raw = defaults.string(forKey: Keys.openAITranscriptionModel) ?? "gpt-4o-transcribe"
        let aliasMap: [String: String] = [
            "gpt-4o": "gpt-4o-transcribe",
            "gpt-4o-mini": "gpt-4o-mini-transcribe",
            "whisper": "whisper-1"
        ]
        if let normalized = aliasMap[raw] {
            objectWillChange.send()
            defaults.set(normalized, forKey: Keys.openAITranscriptionModel)
        }
    }

    // MARK: - Hands-Free Auto Stop

    public var handsFreeAutoStopEnabled: Bool {
        get { defaults.bool(forKey: Keys.handsFreeAutoStop) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.handsFreeAutoStop)
        }
    }

    public var handsFreeSilenceDuration: Double {
        get { defaults.double(forKey: Keys.handsFreeSilenceDuration) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.handsFreeSilenceDuration)
        }
    }

    public var handsFreeSilenceThreshold: Double {
        get { defaults.double(forKey: Keys.handsFreeSilenceThreshold) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.handsFreeSilenceThreshold)
        }
    }

    public var handsFreeMinimumDuration: Double {
        get { defaults.double(forKey: Keys.handsFreeMinimumDuration) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.handsFreeMinimumDuration)
        }
    }

    // MARK: - Custom Dictionary

    public var customTerms: [String] {
        get { defaults.stringArray(forKey: Keys.customTerms) ?? [] }
        set { defaults.set(newValue, forKey: Keys.customTerms) }
    }

    public func addCustomTerm(_ term: String) {
        var terms = customTerms
        if !terms.contains(term) {
            terms.append(term)
            customTerms = terms
        }
    }

    public func removeCustomTerm(_ term: String) {
        var terms = customTerms
        terms.removeAll { $0 == term }
        customTerms = terms
    }

    // MARK: - Statistics

    public var totalWordsTranscribed: Int {
        get { defaults.integer(forKey: Keys.totalWordsTranscribed) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.totalWordsTranscribed)
        }
    }

    public func addWordsTranscribed(_ count: Int) {
        totalWordsTranscribed += count
    }

    // MARK: - Setup State

    public var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedSetup) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.hasCompletedSetup)
        }
    }

    public func markSetupComplete() {
        hasCompletedSetup = true
    }

    // MARK: - Pipeline Helpers

    private func currentPipelinePreset() -> PipelinePreset {
        if isDomesticASRProvider(selectedASRProvider) {
            return .domestic
        }

        if selectedASRProvider == "openai_whisper" {
            return correctionEnabled ? .whisperPlusEdit : .whisperOnly
        }

        return .custom
    }

    private func applyPipelinePreset(_ preset: PipelinePreset) {
        switch preset {
        case .domestic:
            if !isDomesticASRProvider(selectedASRProvider) {
                selectedASRProvider = "volcano"
            }
            asrMode = .stream
            correctionEnabled = true
            if selectedCorrectionProvider == "openai_gpt" || selectedCorrectionProvider.isEmpty {
                selectedCorrectionProvider = "doubao"
            }
        case .whisperOnly:
            selectedASRProvider = "openai_whisper"
            correctionEnabled = false
        case .whisperPlusEdit:
            selectedASRProvider = "openai_whisper"
            correctionEnabled = true
            if selectedCorrectionProvider.isEmpty || selectedCorrectionProvider == "doubao" {
                selectedCorrectionProvider = "openai_gpt"
            }
        case .custom:
            break
        }
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
        if preset == .streamFast {
            streamFastEnabled = true
        }
    }

    private func isDomesticASRProvider(_ providerId: String) -> Bool {
        providerId == "volcano"
    }
}
