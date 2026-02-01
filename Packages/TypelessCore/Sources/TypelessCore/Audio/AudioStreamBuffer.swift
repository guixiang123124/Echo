import Foundation

/// Thread-safe buffer for accumulating audio data during streaming
public actor AudioStreamBuffer {
    private var buffer: Data
    private let chunkSize: Int
    private let format: AudioStreamFormat

    /// - Parameters:
    ///   - chunkSize: Number of bytes per chunk to emit (default: 0.5s of 16kHz mono 16-bit = 16000 bytes)
    ///   - format: Audio stream format
    public init(
        chunkSize: Int = 16000,
        format: AudioStreamFormat = .default
    ) {
        self.buffer = Data()
        self.chunkSize = chunkSize
        self.format = format
    }

    /// Append audio data to the buffer
    public func append(_ data: Data) {
        buffer.append(data)
    }

    /// Check if we have enough data for a chunk
    public var hasChunk: Bool {
        buffer.count >= chunkSize
    }

    /// Extract the next chunk of audio data, or nil if not enough data
    public func nextChunk() -> AudioChunk? {
        guard buffer.count >= chunkSize else { return nil }

        let chunkData = buffer.prefix(chunkSize)
        buffer = Data(buffer.dropFirst(chunkSize))

        let duration = AudioFormatHelper.duration(
            dataSize: chunkData.count,
            format: format
        )

        return AudioChunk(
            data: Data(chunkData),
            format: format,
            duration: duration
        )
    }

    /// Flush remaining data as a final chunk (may be smaller than chunkSize)
    public func flush() -> AudioChunk? {
        guard !buffer.isEmpty else { return nil }

        let remaining = buffer
        buffer = Data()

        let duration = AudioFormatHelper.duration(
            dataSize: remaining.count,
            format: format
        )

        return AudioChunk(
            data: remaining,
            format: format,
            duration: duration
        )
    }

    /// Clear the buffer
    public func clear() {
        buffer = Data()
    }

    /// Current buffer size in bytes
    public var size: Int {
        buffer.count
    }

    /// Current buffered duration
    public var bufferedDuration: TimeInterval {
        AudioFormatHelper.duration(dataSize: buffer.count, format: format)
    }
}
