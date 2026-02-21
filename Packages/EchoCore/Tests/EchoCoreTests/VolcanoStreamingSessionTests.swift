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

    @Test("empty final is normalized to latest non-empty partial")
    func normalizeEmptyFinalUsesLatestPartial() {
        let partial = TranscriptionResult(text: "hello volcano", language: .unknown, isFinal: false)
        let emptyFinal = TranscriptionResult(text: "   ", language: .unknown, isFinal: true)

        let normalized = VolcanoStreamingSession.normalizedStreamingResult(emptyFinal, latestPartial: partial)

        #expect(normalized.isFinal == true)
        #expect(normalized.text == "hello volcano")
    }

    @Test("empty final stays empty when no partial exists")
    func normalizeEmptyFinalWithoutPartial() {
        let emptyFinal = TranscriptionResult(text: "", language: .unknown, isFinal: true)

        let normalized = VolcanoStreamingSession.normalizedStreamingResult(emptyFinal, latestPartial: nil)

        #expect(normalized.isFinal == true)
        #expect(normalized.text.isEmpty)
    }
}

@Suite("VolcanoASRProvider streaming resource mapping")
struct VolcanoASRProviderStreamingResourceTests {

    @Test("maps bigasr auc resources to seedasr sauc duration")
    func mapBigasrAucToSeedasrSauc() {
        #expect(VolcanoASRProvider.mapStreamingResourceId("volc.bigasr.auc_turbo") == "volc.seedasr.sauc.duration")
        #expect(VolcanoASRProvider.mapStreamingResourceId("volc.bigasr.auc") == "volc.seedasr.sauc.duration")
    }

    @Test("keeps non-bigasr sauc resources unchanged")
    func keepSaucResource() {
        #expect(VolcanoASRProvider.mapStreamingResourceId("volc.seedasr.sauc.duration") == "volc.seedasr.sauc.duration")
    }

    @Test("maps generic auc suffix to sauc duration")
    func mapGenericAucSuffix() {
        #expect(VolcanoASRProvider.mapStreamingResourceId("volc.foobar.auc_turbo") == "volc.foobar.sauc.duration")
    }
}
