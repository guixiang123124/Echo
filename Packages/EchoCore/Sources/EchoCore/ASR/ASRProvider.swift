import Foundation

/// Protocol for all speech-to-text providers (both on-device and cloud)
public protocol ASRProvider: Sendable {
    /// Unique identifier for this provider
    var id: String { get }

    /// Human-readable display name
    var displayName: String { get }

    /// Whether this provider supports real-time streaming
    var supportsStreaming: Bool { get }

    /// Whether this provider requires network connectivity
    var requiresNetwork: Bool { get }

    /// Languages supported by this provider
    var supportedLanguages: Set<String> { get }

    /// Whether this provider is currently available (e.g., API key configured, model downloaded)
    var isAvailable: Bool { get }

    /// Transcribe a complete audio chunk (batch mode)
    func transcribe(audio: AudioChunk) async throws -> TranscriptionResult

    /// Start streaming transcription, returning partial results as they arrive
    func startStreaming() -> AsyncStream<TranscriptionResult>

    /// Feed audio data into an active streaming session
    func feedAudio(_ chunk: AudioChunk) async throws

    /// Stop an active streaming session and return the final result
    func stopStreaming() async throws -> TranscriptionResult?
}

/// Errors that can occur during ASR operations
public enum ASRError: Error, Sendable, Equatable, LocalizedError {
    case providerNotAvailable(String)
    case microphoneAccessDenied
    case audioFormatUnsupported
    case networkUnavailable
    case apiKeyMissing
    case apiError(String)
    case transcriptionFailed(String)
    case streamingNotSupported
    case noAudioData
    case timeout

    public var errorDescription: String? {
        switch self {
        case .providerNotAvailable(let name):
            return "ASR provider '\(name)' is not available"
        case .microphoneAccessDenied:
            return "Microphone access was denied"
        case .audioFormatUnsupported:
            return "Audio format is not supported by this provider"
        case .networkUnavailable:
            return "Network connection is required but unavailable"
        case .apiKeyMissing:
            return "API key is not configured for this provider"
        case .apiError(let message):
            return "API error: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .streamingNotSupported:
            return "This provider does not support streaming"
        case .noAudioData:
            return "No audio data provided"
        case .timeout:
            return "Transcription timed out"
        }
    }
}
