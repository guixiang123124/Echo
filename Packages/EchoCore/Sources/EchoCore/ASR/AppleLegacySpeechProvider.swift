import Foundation
import Speech

/// ASR provider using Apple's SFSpeechRecognizer (available iOS 17+)
public final class AppleLegacySpeechProvider: NSObject, ASRProvider, @unchecked Sendable {
    public let id = "apple_speech"
    public let displayName = "Apple Speech (On-Device)"
    public let supportsStreaming = true
    public let requiresNetwork = false
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var streamContinuation: AsyncStream<TranscriptionResult>.Continuation?

    public init(localeIdentifier: String? = "zh-Hans") {
        super.init()
        if let localeIdentifier {
            self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        } else {
            self.recognizer = SFSpeechRecognizer()
        }
    }

    public var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    /// Request speech recognition authorization
    public func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard let recognizer, recognizer.isAvailable else {
            throw ASRError.providerNotAvailable(displayName)
        }

        guard !audio.data.isEmpty else {
            throw ASRError.noAudioData
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        // Create a temporary audio buffer from the chunk data
        guard let format = AudioFormatHelper.avFormat(from: audio.format),
              let buffer = createBuffer(from: audio.data, format: format) else {
            throw ASRError.audioFormatUnsupported
        }

        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: ASRError.transcriptionFailed(error.localizedDescription))
                    return
                }

                guard let result, result.isFinal else { return }

                let transcription = self.mapResult(result, isFinal: true)
                continuation.resume(returning: transcription)
            }
        }
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { continuation in
            self.streamContinuation = continuation

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true

            self.recognitionRequest = request

            guard let recognizer = self.recognizer else {
                continuation.finish()
                return
            }

            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let transcription = self.mapResult(result, isFinal: result.isFinal)
                    continuation.yield(transcription)

                    if result.isFinal {
                        continuation.finish()
                    }
                }

                if error != nil {
                    continuation.finish()
                }
            }
        }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        guard let request = recognitionRequest,
              let format = AudioFormatHelper.avFormat(from: chunk.format),
              let buffer = createBuffer(from: chunk.data, format: format) else {
            throw ASRError.audioFormatUnsupported
        }

        request.append(buffer)
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        return nil
    }

    // MARK: - Private

    private func mapResult(_ result: SFSpeechRecognitionResult, isFinal: Bool) -> TranscriptionResult {
        let text = result.bestTranscription.formattedString

        let wordConfidences = result.bestTranscription.segments.map { segment in
            WordConfidence(
                word: segment.substring,
                confidence: Double(segment.confidence)
            )
        }

        let language = detectLanguage(text)

        return TranscriptionResult(
            text: text,
            language: language,
            isFinal: isFinal,
            wordConfidences: wordConfidences
        )
    }

    private func detectLanguage(_ text: String) -> RecognizedLanguage {
        let chinesePattern = "\\p{Han}"
        let englishPattern = "[a-zA-Z]"

        let hasChinese = text.range(of: chinesePattern, options: .regularExpression) != nil
        let hasEnglish = text.range(of: englishPattern, options: .regularExpression) != nil

        if hasChinese && hasEnglish { return .mixed }
        if hasChinese { return .chinese }
        if hasEnglish { return .english }
        return .unknown
    }

    private func createBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }

        let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frameCount > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else { return }

            if format.isInterleaved {
                let audioBuffer = buffer.audioBufferList.pointee.mBuffers
                guard let mData = audioBuffer.mData else { return }
                memcpy(mData, baseAddress, data.count)
                return
            }

            switch format.commonFormat {
            case .pcmFormatInt16:
                if let channelData = buffer.int16ChannelData {
                    memcpy(channelData[0], baseAddress, data.count)
                }
            case .pcmFormatFloat32:
                if let channelData = buffer.floatChannelData {
                    memcpy(channelData[0], baseAddress, data.count)
                }
            default:
                break
            }
        }

        return buffer
    }
}
