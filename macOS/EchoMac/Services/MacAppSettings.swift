import Foundation
import SwiftUI

/// macOS-specific settings for Echo
public final class MacAppSettings: ObservableObject {
    public static let shared = MacAppSettings()
    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyType = "hotkeyType"
        static let selectedASRProvider = "selectedASRProvider"
        static let asrLanguage = "asrLanguage"
        static let selectedCorrectionProvider = "selectedCorrectionProvider"
        static let correctionEnabled = "correctionEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let showRecordingPanel = "showRecordingPanel"
        static let playSound = "playSound"
        static let customTerms = "customTerms"
        static let totalWordsTranscribed = "totalWordsTranscribed"
        static let hasCompletedSetup = "hasCompletedSetup"
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
                return "Right Option"
            case .leftOption:
                return "Left Option"
            case .rightCommand:
                return "Right Command"
            case .doubleCommand:
                return "Double-tap Command"
            }
        }

        public var shortDescription: String {
            switch self {
            case .fn:
                return "Press Fn to start/stop"
            case .rightOption:
                return "Press Right Option to start/stop"
            case .leftOption:
                return "Press Left Option to start/stop"
            case .rightCommand:
                return "Press Right Command to start/stop"
            case .doubleCommand:
                return "Double-tap Command to toggle"
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
        if defaults.object(forKey: Keys.selectedASRProvider) == nil {
            defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
        } else if defaults.string(forKey: Keys.selectedASRProvider) == "apple_speech" {
            defaults.set("openai_whisper", forKey: Keys.selectedASRProvider)
        }
        if defaults.object(forKey: Keys.asrLanguage) == nil {
            defaults.set("auto", forKey: Keys.asrLanguage)
        }
        if defaults.object(forKey: Keys.correctionEnabled) == nil {
            defaults.set(true, forKey: Keys.correctionEnabled)
        }
        if defaults.object(forKey: Keys.showRecordingPanel) == nil {
            defaults.set(true, forKey: Keys.showRecordingPanel)
        }
        if defaults.object(forKey: Keys.playSound) == nil {
            defaults.set(true, forKey: Keys.playSound)
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

    public var asrLanguage: String {
        get { defaults.string(forKey: Keys.asrLanguage) ?? "auto" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.asrLanguage)
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

    public var playSoundEffects: Bool {
        get { defaults.bool(forKey: Keys.playSound) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.playSound)
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
}
