import Testing
@testable import EchoCore

@Suite("CorrectionResult Tests")
struct CorrectionResultTests {

    @Test("Detects when text was modified")
    func wasModified() {
        let modified = CorrectionResult(
            originalText: "他在跑步",
            correctedText: "他在跑步。"
        )

        #expect(modified.wasModified)
    }

    @Test("Detects when text was not modified")
    func wasNotModified() {
        let unmodified = CorrectionResult(
            originalText: "Hello world",
            correctedText: "Hello world"
        )

        #expect(!unmodified.wasModified)
    }

    @Test("Unchanged factory creates pass-through result")
    func unchanged() {
        let result = CorrectionResult.unchanged("test text")

        #expect(result.originalText == "test text")
        #expect(result.correctedText == "test text")
        #expect(!result.wasModified)
        #expect(result.corrections.isEmpty)
    }

    @Test("Stores corrections with types")
    func correctionsWithTypes() {
        let corrections = [
            Correction(
                original: "在",
                replacement: "再",
                type: .homophone,
                confidence: 0.95
            ),
            Correction(
                original: "",
                replacement: "。",
                type: .punctuation,
                confidence: 0.9
            )
        ]

        let result = CorrectionResult(
            originalText: "在见",
            correctedText: "再见。",
            corrections: corrections
        )

        #expect(result.corrections.count == 2)
        #expect(result.corrections[0].type == .homophone)
        #expect(result.corrections[1].type == .punctuation)
    }
}

@Suite("CorrectionType Tests")
struct CorrectionTypeTests {

    @Test("All correction types exist")
    func allTypes() {
        #expect(CorrectionType.allCases.count == 6)
    }
}
