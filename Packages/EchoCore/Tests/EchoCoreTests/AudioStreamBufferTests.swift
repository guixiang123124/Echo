import Foundation
import Testing
@testable import EchoCore

@Suite("AudioStreamBuffer Tests")
struct AudioStreamBufferTests {

    @Test("Empty buffer has no chunks")
    func emptyBuffer() async {
        let buffer = AudioStreamBuffer(chunkSize: 100)

        let hasChunk = await buffer.hasChunk
        #expect(!hasChunk)
    }

    @Test("Buffer accumulates data until chunk size")
    func accumulatesData() async {
        let buffer = AudioStreamBuffer(chunkSize: 100)

        await buffer.append(Data(repeating: 0, count: 50))
        let hasChunk1 = await buffer.hasChunk
        #expect(!hasChunk1)

        await buffer.append(Data(repeating: 0, count: 60))
        let hasChunk2 = await buffer.hasChunk
        #expect(hasChunk2)
    }

    @Test("Next chunk returns correct size")
    func nextChunk() async {
        let buffer = AudioStreamBuffer(chunkSize: 100)

        await buffer.append(Data(repeating: 0, count: 150))

        let chunk = await buffer.nextChunk()
        #expect(chunk != nil)
        #expect(chunk?.sizeInBytes == 100)
    }

    @Test("Flush returns remaining data")
    func flush() async {
        let buffer = AudioStreamBuffer(chunkSize: 100)

        await buffer.append(Data(repeating: 0, count: 50))

        let flushed = await buffer.flush()
        #expect(flushed != nil)
        #expect(flushed?.sizeInBytes == 50)
    }

    @Test("Flush on empty buffer returns nil")
    func flushEmpty() async {
        let buffer = AudioStreamBuffer(chunkSize: 100)

        let flushed = await buffer.flush()
        #expect(flushed == nil)
    }

    @Test("Clear empties the buffer")
    func clear() async {
        let buffer = AudioStreamBuffer(chunkSize: 100)

        await buffer.append(Data(repeating: 0, count: 200))
        await buffer.clear()

        let size = await buffer.size
        #expect(size == 0)
    }

    @Test("Buffered duration calculation")
    func bufferedDuration() async {
        let format = AudioStreamFormat.default // 32000 bytes/s
        let buffer = AudioStreamBuffer(chunkSize: 16000, format: format)

        await buffer.append(Data(repeating: 0, count: 32000)) // 1 second

        let duration = await buffer.bufferedDuration
        #expect(duration == 1.0)
    }
}
