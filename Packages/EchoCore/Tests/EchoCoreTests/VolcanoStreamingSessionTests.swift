import Testing
@testable import EchoCore

@Suite("VolcanoStreamingSession stop result selection")
struct VolcanoStreamingSessionTests {

    @Test("stop prefers final result when both final and partial are available")
    func stopPrefersFinalResult() {
        let partial = TranscriptionResult(text: "partial text", language: .unknown, isFinal: false)
        let final = TranscriptionResult(text: "final text", language: .unknown, isFinal: true)

        let selected = VolcanoStreamingSession.preferredStopResult(final: final, partial: partial)

        #expect(selected?.text == "final text")
        #expect(selected?.isFinal == true)
    }

    @Test("stop falls back to partial result when final is missing")
    func stopFallsBackToPartialResult() {
        let partial = TranscriptionResult(text: "partial text", language: .unknown, isFinal: false)

        let selected = VolcanoStreamingSession.preferredStopResult(final: nil, partial: partial)

        #expect(selected?.text == "partial text")
        #expect(selected?.isFinal == false)
    }

    @Test("stop returns nil when neither final nor partial result exists")
    func stopReturnsNilWhenNoResults() {
        let selected = VolcanoStreamingSession.preferredStopResult(final: nil, partial: nil)

        #expect(selected == nil)
    }
}
