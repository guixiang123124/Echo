@preconcurrency import AVFoundation
import Foundation

/// Service for capturing audio from the microphone using AVAudioEngine
public final class AudioCaptureService: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case paused
        case error(String)
    }

    private let engine: AVAudioEngine
    private let stateStream: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation
    private let audioStream: AsyncStream<AudioChunk>
    private let audioContinuation: AsyncStream<AudioChunk>.Continuation
    private let format: AudioStreamFormat

    public init(format: AudioStreamFormat = .default) {
        self.engine = AVAudioEngine()
        self.format = format

        var stateCont: AsyncStream<State>.Continuation!
        self.stateStream = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        var audioCont: AsyncStream<AudioChunk>.Continuation!
        self.audioStream = AsyncStream { audioCont = $0 }
        self.audioContinuation = audioCont
    }

    deinit {
        stateContinuation.finish()
        audioContinuation.finish()
    }

    /// Stream of state changes
    public var states: AsyncStream<State> {
        stateStream
    }

    /// Stream of audio chunks as they are captured
    public var audioChunks: AsyncStream<AudioChunk> {
        audioStream
    }

    /// Request microphone permission
    public func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Start capturing audio from the microphone
    public func startRecording() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AudioFormatHelper.avFormat(from: format) else {
            stateContinuation.yield(.error("Unsupported audio format"))
            throw ASRError.audioFormatUnsupported
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            stateContinuation.yield(.error("Cannot create audio converter"))
            throw ASRError.audioFormatUnsupported
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }
            self.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        try engine.start()
        stateContinuation.yield(.recording)
    }

    /// Stop capturing audio
    public func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stateContinuation.yield(.idle)
    }

    // MARK: - Private

    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
        )

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        var hasData = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error != nil { return }

        guard let data = AudioFormatHelper.bufferToData(convertedBuffer) else { return }

        let duration = AudioFormatHelper.duration(dataSize: data.count, format: format)

        let chunk = AudioChunk(
            data: data,
            format: format,
            duration: duration
        )

        audioContinuation.yield(chunk)
    }
}
