import Foundation

/// Confidence score for a single recognized word or segment
public struct WordConfidence: Sendable, Equatable {
    public let word: String
    public let confidence: Double
    public let range: Range<String.Index>?

    public init(word: String, confidence: Double, range: Range<String.Index>? = nil) {
        self.word = word
        self.confidence = confidence
        self.range = range
    }

    public var isLowConfidence: Bool {
        confidence < 0.7
    }
}

/// Result from an ASR transcription operation
public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let language: RecognizedLanguage
    public let isFinal: Bool
    public let wordConfidences: [WordConfidence]
    public let timestamp: Date

    public init(
        text: String,
        language: RecognizedLanguage,
        isFinal: Bool,
        wordConfidences: [WordConfidence] = [],
        timestamp: Date = Date()
    ) {
        self.text = text
        self.language = language
        self.isFinal = isFinal
        self.wordConfidences = wordConfidences
        self.timestamp = timestamp
    }

    public var averageConfidence: Double {
        guard !wordConfidences.isEmpty else { return 1.0 }
        let total = wordConfidences.reduce(0.0) { $0 + $1.confidence }
        return total / Double(wordConfidences.count)
    }

    public var lowConfidenceWords: [WordConfidence] {
        wordConfidences.filter(\.isLowConfidence)
    }

    public static func == (lhs: TranscriptionResult, rhs: TranscriptionResult) -> Bool {
        lhs.text == rhs.text
            && lhs.language == rhs.language
            && lhs.isFinal == rhs.isFinal
    }
}

/// Language detected in speech
public enum RecognizedLanguage: String, Sendable, Equatable, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"
    case mixed = "mixed"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .mixed: return "Mixed"
        case .unknown: return "Unknown"
        }
    }
}
