import Testing
@testable import TypelessCore

@Suite("TranscriptionResult Tests")
struct TranscriptionResultTests {

    @Test("Creates transcription with all fields")
    func createTranscription() {
        let result = TranscriptionResult(
            text: "Hello world",
            language: .english,
            isFinal: true,
            wordConfidences: [
                WordConfidence(word: "Hello", confidence: 0.95),
                WordConfidence(word: "world", confidence: 0.88)
            ]
        )

        #expect(result.text == "Hello world")
        #expect(result.language == .english)
        #expect(result.isFinal == true)
        #expect(result.wordConfidences.count == 2)
    }

    @Test("Calculates average confidence correctly")
    func averageConfidence() {
        let result = TranscriptionResult(
            text: "test",
            language: .english,
            isFinal: true,
            wordConfidences: [
                WordConfidence(word: "a", confidence: 0.8),
                WordConfidence(word: "b", confidence: 0.6)
            ]
        )

        #expect(result.averageConfidence == 0.7)
    }

    @Test("Returns 1.0 average confidence when no word confidences")
    func emptyConfidence() {
        let result = TranscriptionResult(
            text: "test",
            language: .english,
            isFinal: true
        )

        #expect(result.averageConfidence == 1.0)
    }

    @Test("Identifies low confidence words")
    func lowConfidenceWords() {
        let result = TranscriptionResult(
            text: "test",
            language: .chinese,
            isFinal: true,
            wordConfidences: [
                WordConfidence(word: "你", confidence: 0.95),
                WordConfidence(word: "好", confidence: 0.5),
                WordConfidence(word: "吗", confidence: 0.3)
            ]
        )

        #expect(result.lowConfidenceWords.count == 2)
    }

    @Test("WordConfidence detects low confidence")
    func wordConfidenceLowDetection() {
        let high = WordConfidence(word: "hello", confidence: 0.9)
        let low = WordConfidence(word: "wrold", confidence: 0.4)

        #expect(!high.isLowConfidence)
        #expect(low.isLowConfidence)
    }
}

@Suite("RecognizedLanguage Tests")
struct RecognizedLanguageTests {

    @Test("All languages have display names")
    func displayNames() {
        for lang in RecognizedLanguage.allCases {
            #expect(!lang.displayName.isEmpty)
        }
    }

    @Test("Raw values are correct")
    func rawValues() {
        #expect(RecognizedLanguage.chinese.rawValue == "zh-Hans")
        #expect(RecognizedLanguage.english.rawValue == "en")
    }
}
