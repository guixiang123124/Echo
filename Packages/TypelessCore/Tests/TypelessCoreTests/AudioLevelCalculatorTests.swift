import Foundation
import Testing
@testable import TypelessCore

@Suite("AudioLevelCalculator Tests")
struct AudioLevelCalculatorTests {

    @Test("Returns 0 for empty data")
    func emptyData() {
        let level = AudioLevelCalculator.rmsLevel(from: Data())
        #expect(level == 0)
    }

    @Test("Returns 0 for silence (all zeros)")
    func silence() {
        let data = Data(repeating: 0, count: 1000)
        let level = AudioLevelCalculator.rmsLevel(from: data)
        #expect(level == 0)
    }

    @Test("Returns positive level for non-zero samples")
    func nonZeroSamples() {
        // Create Int16 samples with value 1000
        var data = Data()
        let sampleValue: Int16 = 1000
        for _ in 0..<100 {
            var value = sampleValue
            data.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }
        let level = AudioLevelCalculator.rmsLevel(from: data)
        #expect(level > 0)
        #expect(level <= 1.0)
    }

    @Test("Louder audio produces higher levels")
    func loudnessOrdering() {
        // Quiet samples
        var quietData = Data()
        let quietValue: Int16 = 500
        for _ in 0..<100 {
            var value = quietValue
            quietData.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }

        // Loud samples
        var loudData = Data()
        let loudValue: Int16 = 5000
        for _ in 0..<100 {
            var value = loudValue
            loudData.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }

        let quietLevel = AudioLevelCalculator.rmsLevel(from: quietData)
        let loudLevel = AudioLevelCalculator.rmsLevel(from: loudData)
        #expect(loudLevel > quietLevel)
    }

    @Test("Peak level returns max amplitude normalized")
    func peakLevel() {
        var data = Data()
        let values: [Int16] = [100, 5000, -3000, 200]
        for var value in values {
            data.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }

        let peak = AudioLevelCalculator.peakLevel(from: data)
        let expected = CGFloat(Double(5000) / Double(Int16.max))
        #expect(abs(peak - expected) < 0.001)
    }

    @Test("RMS level from AudioChunk works")
    func rmsFromChunk() {
        var data = Data()
        let sampleValue: Int16 = 2000
        for _ in 0..<50 {
            var value = sampleValue
            data.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }
        let chunk = AudioChunk(data: data, duration: 0.003)
        let level = AudioLevelCalculator.rmsLevel(from: chunk)
        #expect(level > 0)
    }

    @Test("Level is clamped to 1.0 for very loud signals")
    func clampToOne() {
        var data = Data()
        let maxValue: Int16 = Int16.max
        for _ in 0..<100 {
            var value = maxValue
            data.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }
        let level = AudioLevelCalculator.rmsLevel(from: data)
        #expect(level == 1.0)
    }

    @Test("Single sample data works")
    func singleSample() {
        var data = Data()
        var value: Int16 = 4000
        data.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))

        let level = AudioLevelCalculator.rmsLevel(from: data)
        #expect(level > 0)
    }
}
