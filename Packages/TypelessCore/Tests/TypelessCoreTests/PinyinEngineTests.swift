import Testing
@testable import TypelessCore

@Suite("PinyinEngine Tests")
struct PinyinEngineTests {

    @Test("Appending characters returns candidates")
    func appendCharacter() async {
        let engine = PinyinEngine()

        let candidates = await engine.appendCharacter("n")
        #expect(!candidates.isEmpty)

        let moreCandidates = await engine.appendCharacter("i")
        #expect(!moreCandidates.isEmpty)

        // "ni" should include 你
        let hasNi = moreCandidates.contains { $0.text == "你" }
        #expect(hasNi)
    }

    @Test("Selecting candidate returns text and clears buffer")
    func selectCandidate() async {
        let engine = PinyinEngine()

        _ = await engine.appendCharacter("n")
        _ = await engine.appendCharacter("i")

        let selected = await engine.selectCandidate(at: 0)
        #expect(selected != nil)

        let input = await engine.currentInput
        #expect(input.isEmpty)
    }

    @Test("Selecting invalid index returns nil")
    func selectInvalidIndex() async {
        let engine = PinyinEngine()

        _ = await engine.appendCharacter("a")
        let result = await engine.selectCandidate(at: 999)

        #expect(result == nil)
    }

    @Test("Delete last character updates candidates")
    func deleteLastCharacter() async {
        let engine = PinyinEngine()

        _ = await engine.appendCharacter("n")
        _ = await engine.appendCharacter("i")
        _ = await engine.deleteLastCharacter()

        let input = await engine.currentInput
        #expect(input == "n")
    }

    @Test("Delete on empty buffer returns empty")
    func deleteEmpty() async {
        let engine = PinyinEngine()

        let candidates = await engine.deleteLastCharacter()
        #expect(candidates.isEmpty)
    }

    @Test("Clear resets everything")
    func clearEngine() async {
        let engine = PinyinEngine()

        _ = await engine.appendCharacter("n")
        _ = await engine.appendCharacter("i")
        await engine.clear()

        let input = await engine.currentInput
        let candidates = await engine.candidates

        #expect(input.isEmpty)
        #expect(candidates.isEmpty)
    }

    @Test("Common pinyin lookups work")
    func commonLookups() async {
        let engine = PinyinEngine()

        // Test "nihao" (你好)
        for char in "nihao" {
            _ = await engine.appendCharacter(String(char))
        }

        let candidates = await engine.candidates
        let hasNihao = candidates.contains { $0.text == "你好" }
        #expect(hasNihao)
    }
}
