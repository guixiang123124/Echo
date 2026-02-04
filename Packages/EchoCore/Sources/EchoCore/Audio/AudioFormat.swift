import AVFoundation
import Foundation

/// Audio format utilities and conversions
public enum AudioFormatHelper {
    /// Create AVAudioFormat for standard ASR input (16kHz mono 16-bit PCM)
    public static func asrInputFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
    }

    /// Create AVAudioFormat matching a given AudioStreamFormat
    public static func avFormat(from streamFormat: AudioStreamFormat) -> AVAudioFormat? {
        let commonFormat: AVAudioCommonFormat
        switch streamFormat.bitsPerSample {
        case 16:
            commonFormat = .pcmFormatInt16
        case 32:
            commonFormat = .pcmFormatFloat32
        default:
            return nil
        }

        return AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: streamFormat.sampleRate,
            channels: AVAudioChannelCount(streamFormat.channelCount),
            interleaved: true
        )
    }

    /// Convert AVAudioPCMBuffer to Data
    public static func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        if buffer.format.isInterleaved {
            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let mData = audioBuffer.mData else { return nil }
            let byteCount = frameLength * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            return Data(bytes: mData, count: byteCount)
        }

        guard let channelData = buffer.int16ChannelData else { return nil }
        return Data(
            bytes: channelData[0],
            count: frameLength * MemoryLayout<Int16>.size
        )
    }

    /// Calculate duration from data size and format
    public static func duration(
        dataSize: Int,
        format: AudioStreamFormat = .default
    ) -> TimeInterval {
        guard format.bytesPerSecond > 0 else { return 0 }
        return TimeInterval(dataSize) / TimeInterval(format.bytesPerSecond)
    }

    /// Build a WAV file (header + PCM data) for a given audio chunk
    public static func wavData(for audio: AudioChunk) -> Data {
        var header = Data()
        let dataSize = UInt32(audio.data.count)
        let sampleRate = UInt32(audio.format.sampleRate)
        let channels = UInt16(audio.format.channelCount)
        let bitsPerSample = UInt16(audio.format.bitsPerSample)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        header.append("RIFF")
        header.appendLittleEndian(UInt32(36 + dataSize))
        header.append("WAVE")
        header.append("fmt ")
        header.appendLittleEndian(UInt32(16)) // Subchunk1 size
        header.appendLittleEndian(UInt16(1))  // PCM format
        header.appendLittleEndian(channels)
        header.appendLittleEndian(sampleRate)
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)
        header.append("data")
        header.appendLittleEndian(dataSize)

        var wav = Data()
        wav.append(header)
        wav.append(audio.data)
        return wav
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<T>.size))
    }
}
