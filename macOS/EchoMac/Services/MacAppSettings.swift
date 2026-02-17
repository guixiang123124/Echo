import Foundation
import SwiftUI
import EchoCore

/// macOS-specific settings for Echo
public final class MacAppSettings: ObservableObject {
    public static let shared = MacAppSettings()
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyType = "hotkeyType"
        static let recordingMode = "recordingMode"
        static let selectedASRProvider = "selectedASRProvider"
        static let asrMode = "echo.asr.mode"
        static let asrLanguage = "asrLanguage"
        static let openAITranscriptionModel = "echo.asr.openaiModel"
        static let deepgramModel = "echo.asr.deepgramModel"
        static let selectedCorrectionProvider = "selectedCorrectionProvider"
        static let correctionEnabled = "correctionEnabled"
        static let correctionHomophones = "correctionHomophones"
        static let correctionPunctuation = "correctionPunctuation"
        static let correctionFormatting = "correctionFormatting"
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
                return "Use Volcano/Alibaba for ASR with a domestic LLM for edits."
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
        } else if defaults.string(forKey: Keys.selectedASRProvider) == "apple_speech" {
            defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
        }
        if defaults.object(forKey: Keys.asrLanguage) == nil {
            defaults.set("auto", forKey: Keys.asrLanguage)
        }
        if defaults.object(forKey: Keys.asrMode) == nil {
            defaults.set(ASRMode.batch.rawValue, forKey: Keys.asrMode)
        }
        if defaults.object(forKey: Keys.openAITranscriptionModel) == nil {
            defaults.set("gpt-4o-transcribe", forKey: Keys.openAITranscriptionModel)
        }
        if defaults.object(forKey: Keys.deepgramModel) == nil {
            defaults.set("nova-3", forKey: Keys.deepgramModel)
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
        if defaults.object(forKey: Keys.cloudSyncBaseURL) == nil {
            defaults.set("", forKey: Keys.cloudSyncBaseURL)
        }
        if defaults.object(forKey: Keys.cloudUploadAudio) == nil {
            defaults.set(false, forKey: Keys.cloudUploadAudio)
        }
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
            if value == "apple_speech" || value == "apple_legacy" {
                return "openai_whisper"
            }
            return value
        }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.selectedASRProvider)
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

    public var autoEditOptions: CorrectionOptions {
        CorrectionOptions(
            enableHomophones: correctionHomophonesEnabled,
            enablePunctuation: correctionPunctuationEnabled,
            enableFormatting: correctionFormattingEnabled
        )
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

    private func isDomesticASRProvider(_ providerId: String) -> Bool {
        providerId == "volcano" || providerId == "aliyun"
    }
}
