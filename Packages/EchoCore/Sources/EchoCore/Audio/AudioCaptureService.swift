@preconcurrency import AVFoundation
import Foundation

/// Service for capturing audio from the microphone using AVAudioEngine
public final class AudioCaptureService: @unchecked Sendable {
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
    #if os(iOS)
    private var audioSessionConfigured = false
    private var interruptionObserver: NSObjectProtocol?
    #endif

    public init(format: AudioStreamFormat = .default) {
        self.engine = AVAudioEngine()
        self.format = format

        var stateCont: AsyncStream<State>.Continuation!
        self.stateStream = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        var audioCont: AsyncStream<AudioChunk>.Continuation!
        self.audioStream = AsyncStream { audioCont = $0 }
        self.audioContinuation = audioCont

        #if os(iOS)
        setupInterruptionObserver()
        #endif
    }

    deinit {
        stateContinuation.finish()
        audioContinuation.finish()
        #if os(iOS)
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
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
        #if os(iOS)
        try configureAudioSessionIfNeeded()
        #endif
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            stateContinuation.yield(.error("No available audio input format"))
            throw ASRError.audioFormatUnsupported
        }

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
            format: nil
        ) { [weak self] buffer, _ in
            guard let self else { return }
            self.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        stateContinuation.yield(.recording)
    }

    /// Stop capturing audio
    public func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        audioSessionConfigured = false
        #endif
        stateContinuation.yield(.idle)
    }

    #if os(iOS)
    private func configureAudioSessionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        if !audioSessionConfigured {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setPreferredSampleRate(format.sampleRate)
            audioSessionConfigured = true
        }
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
    }

    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioSessionInterruption(notification)
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            audioSessionConfigured = false
            stateContinuation.yield(.paused)
        case .ended:
            audioSessionConfigured = false
            stateContinuation.yield(.paused)
        @unknown default:
            break
        }
    }
    #endif

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
