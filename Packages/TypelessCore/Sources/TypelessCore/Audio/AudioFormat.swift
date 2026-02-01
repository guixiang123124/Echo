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
        guard let channelData = buffer.int16ChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        let data = Data(
            bytes: channelData[0],
            count: frameLength * MemoryLayout<Int16>.size
        )
        return data
    }

    /// Calculate duration from data size and format
    public static func duration(
        dataSize: Int,
        format: AudioStreamFormat = .default
    ) -> TimeInterval {
        guard format.bytesPerSecond > 0 else { return 0 }
        return TimeInterval(dataSize) / TimeInterval(format.bytesPerSecond)
    }
}
