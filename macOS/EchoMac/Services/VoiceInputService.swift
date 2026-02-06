import Foundation
import EchoCore

/// Service that manages voice input using EchoCore
/// Coordinates audio capture, speech recognition, and LLM correction
@MainActor
public final class VoiceInputService: ObservableObject {
    // MARK: - Published State

    @Published public private(set) var isRecording = false
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var isCorrecting = false
    @Published public private(set) var partialTranscription = ""
    @Published public private(set) var finalTranscription = ""
    @Published public private(set) var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published public private(set) var errorMessage: String?

    // MARK: - Dependencies

    private var audioCaptureService: AudioCaptureService
    private let settings: MacAppSettings
    private let keyStore: SecureKeyStore
    private let contextStore: ContextMemoryStore
    private let recordingStore: RecordingStore

    // Audio buffer for transcription
    private var audioChunks: [AudioChunk] = []
    private var audioUpdateTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var activeProvider: (any ASRProvider)?

    // MARK: - Initialization

    public init(settings: MacAppSettings = MacAppSettings()) {
        self.settings = settings
        self.audioCaptureService = AudioCaptureService()
        self.keyStore = SecureKeyStore()
        self.contextStore = ContextMemoryStore()
        self.recordingStore = RecordingStore.shared

        Task {
            await contextStore.load()
        }
    }

    // MARK: - Recording Control

    /// Start voice recording
    public func startRecording() async throws {
        guard !isRecording else { return }

        errorMessage = nil
        audioChunks = []
        partialTranscription = ""

        do {
            // Recreate audio capture service per session to avoid stale engine state
            audioCaptureService = AudioCaptureService()

            // Request permissions if needed
            let micPermission = await audioCaptureService.requestPermission()
            guard micPermission else {
                throw VoiceInputError.permissionDenied("Microphone access denied")
            }

            // Resolve ASR provider
            guard let provider = resolveASRProvider() else {
                throw VoiceInputError.noASRProvider
            }
            activeProvider = provider

            // Start audio capture
            try audioCaptureService.startRecording()

            // Start collecting audio chunks
            startAudioCollection()

            // Start audio level monitoring
            startAudioLevelMonitoring()

            isRecording = true
            print("🎤 Recording started")
        } catch {
            activeProvider = nil
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            throw error
        }
    }

    /// Stop recording and begin transcription
    public func stopRecording() async throws -> String {
        guard isRecording else { return "" }

        isRecording = false
        // Stop audio capture first so we can flush any in-flight buffers
        audioCaptureService.stopRecording()
        // Give the tap a brief moment to deliver any final chunks
        for _ in 0..<4 where audioChunks.isEmpty {
            try? await Task.sleep(for: .milliseconds(80))
        }
        stopAudioLevelMonitoring()
        stopAudioCollection()

        print("🎤 Recording stopped, starting transcription...")

        // Transcribe the audio
        isTranscribing = true
        defer { isTranscribing = false }

        var providerForStorage: (any ASRProvider)?
        var rawTranscript: String?
        var finalTranscriptValue: String?
        let correctionProviderId = settings.correctionEnabled ? settings.selectedCorrectionProvider : nil

        do {
            // Combine all audio chunks
            guard !audioChunks.isEmpty else {
                throw VoiceInputError.noAudioData
            }

            // Combine chunks into a single chunk for batch transcription
            let combinedData = audioChunks.reduce(Data()) { $0 + $1.data }
            let totalDuration = audioChunks.reduce(0) { $0 + $1.duration }
            let format = audioChunks.first?.format ?? .default

            DiagnosticsState.shared.log(
                "Audio captured: chunks=\(audioChunks.count), bytes=\(combinedData.count), duration=\(String(format: "%.2f", totalDuration))s"
            )

            let combinedChunk = AudioChunk(
                data: combinedData,
                format: format,
                duration: totalDuration
            )

            // Resolve ASR provider
            let provider = activeProvider ?? resolveASRProvider()
            activeProvider = nil
            guard let provider else {
                throw VoiceInputError.noASRProvider
            }
            providerForStorage = provider

            // Transcribe
            let transcription = try await provider.transcribe(audio: combinedChunk)
            rawTranscript = transcription.text
            var result = transcription.text

            // Apply LLM correction if enabled and provider is available
            if settings.correctionEnabled,
               let correctionProvider = resolveCorrectionProvider() {
                isCorrecting = true
                defer { isCorrecting = false }

                do {
                    await contextStore.updateUserTerms(settings.customTerms)
                    let context = await contextStore.currentContext()
                    let pipeline = CorrectionPipeline(provider: correctionProvider)
                    let correction = try await pipeline.process(
                        transcription: transcription,
                        context: context,
                        options: settings.autoEditOptions
                    )
                    result = correction.correctedText
                } catch {
                    print("⚠️ Correction failed, using raw transcription: \(error)")
                }
            }

            await contextStore.addTranscription(result)
            let wordCount = result.split { $0.isWhitespace }.count
            if wordCount > 0 {
                settings.addWordsTranscribed(wordCount)
            } else {
                settings.addWordsTranscribed(result.count)
            }
            finalTranscription = result
            finalTranscriptValue = result

            Task {
                await recordingStore.saveRecording(
                    audio: combinedChunk,
                    asrProviderId: provider.id,
                    asrProviderName: provider.displayName,
                    correctionProviderId: correctionProviderId,
                    transcriptRaw: rawTranscript,
                    transcriptFinal: finalTranscriptValue,
                    error: nil
                )
            }
            return result
        } catch {
            let errorString = error.localizedDescription
            if !audioChunks.isEmpty {
                let fallbackProviderId = providerForStorage?.id ?? "openai_whisper"
                let fallbackProviderName = providerForStorage?.displayName ?? "OpenAI Whisper"
                let combinedData = audioChunks.reduce(Data()) { $0 + $1.data }
                let totalDuration = audioChunks.reduce(0) { $0 + $1.duration }
                let format = audioChunks.first?.format ?? .default
                let combinedChunk = AudioChunk(
                    data: combinedData,
                    format: format,
                    duration: totalDuration
                )

                Task {
                    await recordingStore.saveRecording(
                        audio: combinedChunk,
                        asrProviderId: fallbackProviderId,
                        asrProviderName: fallbackProviderName,
                        correctionProviderId: correctionProviderId,
                        transcriptRaw: rawTranscript,
                        transcriptFinal: finalTranscriptValue,
                        error: errorString
                    )
                }
            }
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Cancel recording without transcription
    public func cancelRecording() {
        guard isRecording else { return }

        isRecording = false
        activeProvider = nil
        stopAudioLevelMonitoring()
        stopAudioCollection()
        audioCaptureService.stopRecording()
        audioChunks = []
        partialTranscription = ""

        print("🎤 Recording cancelled")
    }

    // MARK: - Audio Collection

    private func startAudioCollection() {
        recordingTask = Task {
            for await chunk in audioCaptureService.audioChunks {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.audioChunks.append(chunk)
                }
            }
        }
    }

    private func stopAudioCollection() {
        recordingTask?.cancel()
        recordingTask = nil
    }

    // MARK: - Audio Level Monitoring
    private var smoothedLevel: CGFloat = 0

    private func startAudioLevelMonitoring() {
        audioUpdateTask = Task {
            while !Task.isCancelled && isRecording {
                // Calculate audio level from recent chunks
                let level = calculateCurrentAudioLevel()
                updateAudioLevels(with: level)

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopAudioLevelMonitoring() {
        audioUpdateTask?.cancel()
        audioUpdateTask = nil
        smoothedLevel = 0
        audioLevels = Array(repeating: 0, count: 30)
    }

    private func calculateCurrentAudioLevel() -> CGFloat {
        // Get the most recent audio chunk
        guard let lastChunk = audioChunks.last else { return 0 }

        // Calculate RMS level from the audio data
        let samples = lastChunk.data.withUnsafeBytes { buffer -> [Int16] in
            Array(buffer.bindMemory(to: Int16.self))
        }

        guard !samples.isEmpty else { return 0 }

        // Calculate RMS
        let sumOfSquares = samples.reduce(0.0) { sum, sample in
            let floatSample = Double(sample) / Double(Int16.max)
            return sum + floatSample * floatSample
        }
        let rms = sqrt(sumOfSquares / Double(samples.count))

        // Convert to 0-1 range with some scaling
        return CGFloat(min(1.0, rms * 3.0))
    }

    private func updateAudioLevels(with newLevel: CGFloat) {
        let alpha: CGFloat = 0.22
        smoothedLevel = (smoothedLevel * (1 - alpha)) + (newLevel * alpha)
        var levels = audioLevels
        levels.removeFirst()
        levels.append(smoothedLevel)
        audioLevels = levels
    }

    // MARK: - Configuration

    public func updateSettings() {
        // Re-initialize providers if needed
    }

    // MARK: - Provider Resolution

    private func resolveASRProvider() -> (any ASRProvider)? {
        switch settings.selectedASRProvider {
        case "volcano":
            guard let appId = try? keyStore.retrieve(for: "volcano_app_id"),
                  let accessKey = try? keyStore.retrieve(for: "volcano_access_key"),
                  !appId.isEmpty,
                  !accessKey.isEmpty else {
                return nil
            }
            return VolcanoASRProvider(appId: appId, accessKey: accessKey)
        case "aliyun":
            guard let appKey = try? keyStore.retrieve(for: "aliyun_app_key"),
                  let token = try? keyStore.retrieve(for: "aliyun_token"),
                  !appKey.isEmpty,
                  !token.isEmpty else {
                return nil
            }
            return AliyunASRProvider(appKey: appKey, token: token)
        default:
            guard let apiKey = try? keyStore.retrieve(for: "openai_whisper"),
                  !apiKey.isEmpty else {
                return nil
            }
            return OpenAIWhisperProvider(
                keyStore: keyStore,
                language: whisperLanguageCode(from: settings.asrLanguage),
                apiKey: apiKey,
                model: settings.openAITranscriptionModel
            )
        }
    }

    private func whisperLanguageCode(from setting: String) -> String? {
        switch setting {
        case "en-US":
            return "en"
        case "zh-CN", "zh-TW":
            return "zh"
        case "ja-JP":
            return "ja"
        case "ko-KR":
            return "ko"
        default:
            return nil
        }
    }

    private func resolveCorrectionProvider() -> (any CorrectionProvider)? {
        let provider: any CorrectionProvider
        switch settings.selectedCorrectionProvider {
        case "openai_gpt":
            provider = OpenAICorrectionProvider(
                keyStore: keyStore,
                apiKey: try? keyStore.retrieve(for: "openai_gpt")
            )
        case "claude":
            provider = ClaudeCorrectionProvider(keyStore: keyStore)
        case "doubao":
            provider = DoubaoCorrectionProvider(keyStore: keyStore)
        case "qwen":
            provider = QwenCorrectionProvider(keyStore: keyStore)
        default:
            return nil
        }

        return provider.isAvailable ? provider : nil
    }
}

// MARK: - Errors

public enum VoiceInputError: LocalizedError {
    case permissionDenied(String)
    case noASRProvider
    case recordingFailed
    case transcriptionFailed
    case noAudioData

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let reason):
            return "Permission denied: \(reason)"
        case .noASRProvider:
            return "ASR provider is not configured. Add your API credentials in Settings."
        case .recordingFailed:
            return "Failed to record audio"
        case .transcriptionFailed:
            return "Failed to transcribe audio"
        case .noAudioData:
            return "No audio data recorded"
        }
    }
}
