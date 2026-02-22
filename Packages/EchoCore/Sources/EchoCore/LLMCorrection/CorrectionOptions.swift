import Foundation

public enum AutoEditPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case pureTranscript
    case streamFast
    case smartPolish
    case deepEdit
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pureTranscript:
            return "Pure Transcript"
        case .streamFast:
            return "StreamFast"
        case .smartPolish:
            return "Smart Polish"
        case .deepEdit:
            return "Deep Edit"
        case .custom:
            return "Custom"
        }
    }

    public var description: String {
        switch self {
        case .pureTranscript:
            return "Realtime transcript + ASR finalize only. No LLM polish."
        case .streamFast:
            return "Low-latency polish with accuracy-first fixes."
        case .smartPolish:
            return "Balanced quality and speed with cleanup + light rewrite."
        case .deepEdit:
            return "Maximum rewrite and structure optimization."
        case .custom:
            return "Manual combination of Auto Edit controls."
        }
    }
}

public enum AutoEditApplyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case autoReplace
    case confirmDiff

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoReplace:
            return "Auto Replace"
        case .confirmDiff:
            return "Diff Confirm"
        }
    }
}

public enum RewriteIntensity: String, CaseIterable, Codable, Sendable, Identifiable {
    case off
    case light
    case medium
    case strong

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .light:
            return "Light"
        case .medium:
            return "Medium"
        case .strong:
            return "Strong"
        }
    }
}

public enum TranslationTargetLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case keepSource
    case english
    case chineseSimplified

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keepSource:
            return "Keep Source Language"
        case .english:
            return "English"
        case .chineseSimplified:
            return "Chinese (Simplified)"
        }
    }
}

public enum StructuredOutputStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case off
    case conciseParagraphs
    case bulletList
    case actionItems

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .conciseParagraphs:
            return "Concise Paragraphs"
        case .bulletList:
            return "Bullet List"
        case .actionItems:
            return "Action Items"
        }
    }
}

/// Options controlling which correction types are allowed in the Auto Edit pipeline.
public struct CorrectionOptions: Sendable, Equatable {
    public var enableHomophones: Bool
    public var enablePunctuation: Bool
    public var enableFormatting: Bool
    public var enableRemoveFillerWords: Bool
    public var enableRemoveRepetitions: Bool
    public var rewriteIntensity: RewriteIntensity
    public var enableTranslation: Bool
    public var translationTargetLanguage: TranslationTargetLanguage
    public var structuredOutputStyle: StructuredOutputStyle

    public init(
        enableHomophones: Bool = true,
        enablePunctuation: Bool = true,
        enableFormatting: Bool = true,
        enableRemoveFillerWords: Bool = false,
        enableRemoveRepetitions: Bool = false,
        rewriteIntensity: RewriteIntensity = .light,
        enableTranslation: Bool = false,
        translationTargetLanguage: TranslationTargetLanguage = .keepSource,
        structuredOutputStyle: StructuredOutputStyle = .off
    ) {
        self.enableHomophones = enableHomophones
        self.enablePunctuation = enablePunctuation
        self.enableFormatting = enableFormatting
        self.enableRemoveFillerWords = enableRemoveFillerWords
        self.enableRemoveRepetitions = enableRemoveRepetitions
        self.rewriteIntensity = rewriteIntensity
        self.enableTranslation = enableTranslation
        self.translationTargetLanguage = translationTargetLanguage
        self.structuredOutputStyle = structuredOutputStyle
    }

    public static let `default` = preset(.smartPolish)

    public static func preset(_ preset: AutoEditPreset) -> CorrectionOptions {
        switch preset {
        case .pureTranscript:
            return CorrectionOptions(
                enableHomophones: false,
                enablePunctuation: false,
                enableFormatting: false,
                enableRemoveFillerWords: false,
                enableRemoveRepetitions: false,
                rewriteIntensity: .off,
                enableTranslation: false,
                translationTargetLanguage: .keepSource,
                structuredOutputStyle: .off
            )
        case .streamFast:
            return CorrectionOptions(
                enableHomophones: true,
                enablePunctuation: true,
                enableFormatting: false,
                enableRemoveFillerWords: false,
                enableRemoveRepetitions: true,
                rewriteIntensity: .off,
                enableTranslation: false,
                translationTargetLanguage: .keepSource,
                structuredOutputStyle: .off
            )
        case .smartPolish:
            return CorrectionOptions(
                enableHomophones: true,
                enablePunctuation: true,
                enableFormatting: true,
                enableRemoveFillerWords: true,
                enableRemoveRepetitions: true,
                rewriteIntensity: .light,
                enableTranslation: false,
                translationTargetLanguage: .keepSource,
                structuredOutputStyle: .off
            )
        case .deepEdit:
            return CorrectionOptions(
                enableHomophones: true,
                enablePunctuation: true,
                enableFormatting: true,
                enableRemoveFillerWords: true,
                enableRemoveRepetitions: true,
                rewriteIntensity: .strong,
                enableTranslation: false,
                translationTargetLanguage: .keepSource,
                structuredOutputStyle: .bulletList
            )
        case .custom:
            return CorrectionOptions()
        }
    }

    public var isEnabled: Bool {
        enableHomophones
            || enablePunctuation
            || enableFormatting
            || enableRemoveFillerWords
            || enableRemoveRepetitions
            || rewriteIntensity != .off
            || enableTranslation
            || structuredOutputStyle != .off
    }

    public var summary: String {
        var parts: [String] = []
        if enableHomophones { parts.append("homophones") }
        if enablePunctuation { parts.append("punctuation") }
        if enableFormatting { parts.append("formatting") }
        if enableRemoveFillerWords { parts.append("filler cleanup") }
        if enableRemoveRepetitions { parts.append("repetition cleanup") }
        if rewriteIntensity != .off { parts.append("rewrite \(rewriteIntensity.rawValue)") }
        if enableTranslation { parts.append("translation \(translationTargetLanguage.rawValue)") }
        if structuredOutputStyle != .off { parts.append("structured \(structuredOutputStyle.rawValue)") }

        return parts.isEmpty ? "Disabled" : parts.joined(separator: ", ")
    }
}
