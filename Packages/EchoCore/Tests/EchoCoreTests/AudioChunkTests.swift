import Foundation
import Testing
@testable import EchoCore

@Suite("AudioChunk Tests")
struct AudioChunkTests {

    @Test("Creates chunk with default format")
    func defaultFormat() {
        let data = Data(repeating: 0, count: 32000)
        let chunk = AudioChunk(data: data, duration: 1.0)

        #expect(chunk.format == .default)
        #expect(chunk.duration == 1.0)
        #expect(chunk.sizeInBytes == 32000)
        #expect(!chunk.isEmpty)
    }

    @Test("Empty check works")
    func emptyCheck() {
        let empty = AudioChunk(data: Data(), duration: 0)
        let nonEmpty = AudioChunk(data: Data([1, 2, 3]), duration: 0.001)

        #expect(empty.isEmpty)
        #expect(!nonEmpty.isEmpty)
    }
}

@Suite("AudioStreamFormat Tests")
struct AudioStreamFormatTests {

    @Test("Default format is 16kHz mono 16-bit PCM")
    func defaultFormat() {
        let format = AudioStreamFormat.default

        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)
        #expect(format.bitsPerSample == 16)
        #expect(format.encoding == .linearPCM)
    }

    @Test("Calculates bytes per second correctly")
    func bytesPerSecond() {
        let format = AudioStreamFormat.default

        // 16000 samples/s * 1 channel * 2 bytes/sample = 32000 bytes/s
        #expect(format.bytesPerSecond == 32000)
    }

    @Test("Custom format works")
    func customFormat() {
        let format = AudioStreamFormat(
            sampleRate: 44100,
            channelCount: 2,
            bitsPerSample: 16,
            encoding: .linearPCM
        )

        #expect(format.bytesPerSecond == 176400)
    }
}

@Suite("AudioFormatHelper Tests")
struct AudioFormatHelperTests {

    @Test("Calculates duration from data size")
    func duration() {
        let duration = AudioFormatHelper.duration(dataSize: 32000)

        #expect(duration == 1.0) // 32000 bytes / 32000 bytes/s = 1s
    }

    @Test("Handles zero bytes per second")
    func zeroBytesPerSecond() {
        let format = AudioStreamFormat(
            sampleRate: 0,
            channelCount: 0,
            bitsPerSample: 0
        )

        let duration = AudioFormatHelper.duration(dataSize: 100, format: format)
        #expect(duration == 0)
    }
}
