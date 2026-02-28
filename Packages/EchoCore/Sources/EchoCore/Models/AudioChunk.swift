import Foundation

/// A chunk of audio data for ASR processing
public struct AudioChunk: Sendable {
    public let data: Data
    public let format: AudioStreamFormat
    public let duration: TimeInterval
    public let timestamp: Date

    public init(
        data: Data,
        format: AudioStreamFormat = .default,
        duration: TimeInterval,
        timestamp: Date = Date()
    ) {
        self.data = data
        self.format = format
        self.duration = duration
        self.timestamp = timestamp
    }

    public var isEmpty: Bool {
        data.isEmpty
    }

    public var sizeInBytes: Int {
        data.count
    }
}

extension AudioChunk {
    /// Combine multiple audio chunks into a single chunk for batch transcription.
    public static func combine(_ chunks: [AudioChunk]) -> AudioChunk {
        let combinedData = chunks.reduce(Data()) { $0 + $1.data }
        let totalDuration = chunks.reduce(0.0) { $0 + $1.duration }
        let format = chunks.first?.format ?? .default
        return AudioChunk(data: combinedData, format: format, duration: totalDuration)
    }
}

/// Audio format specification for ASR
public struct AudioStreamFormat: Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: Int
    public let bitsPerSample: Int
    public let encoding: AudioEncoding

    public init(
        sampleRate: Double = 16000,
        channelCount: Int = 1,
        bitsPerSample: Int = 16,
        encoding: AudioEncoding = .linearPCM
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.encoding = encoding
    }

    /// Standard format for most ASR engines: 16kHz mono 16-bit PCM
    public static let `default` = AudioStreamFormat()

    public var bytesPerSecond: Int {
        Int(sampleRate) * channelCount * (bitsPerSample / 8)
    }
}

/// Audio encoding types supported by ASR providers
public enum AudioEncoding: String, Sendable, Equatable {
    case linearPCM = "linear16"
    case flac = "flac"
    case opus = "opus"
    case mp3 = "mp3"
    case aac = "aac"
}
