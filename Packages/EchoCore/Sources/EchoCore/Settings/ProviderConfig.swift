import Foundation

/// Configuration for an ASR or LLM provider
public struct ProviderConfig: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let type: ProviderType
    public let isEnabled: Bool
    public let requiresApiKey: Bool

    public init(
        id: String,
        displayName: String,
        type: ProviderType,
        isEnabled: Bool = false,
        requiresApiKey: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.isEnabled = isEnabled
        self.requiresApiKey = requiresApiKey
    }

    /// Return a new config with updated enabled state (immutable)
    public func withEnabled(_ enabled: Bool) -> ProviderConfig {
        ProviderConfig(
            id: id,
            displayName: displayName,
            type: type,
            isEnabled: enabled,
            requiresApiKey: requiresApiKey
        )
    }
}

/// Type of provider
public enum ProviderType: String, Sendable, Equatable, Codable, CaseIterable {
    case asr = "asr"
    case correction = "correction"
}

/// All available provider definitions
public enum AvailableProviders {
    public static let asrProviders: [ProviderConfig] = [
        ProviderConfig(
            id: "apple_speech",
            displayName: "Apple Speech (On-Device)",
            type: .asr,
            isEnabled: true,
            requiresApiKey: false
        ),
        ProviderConfig(
            id: "whisperkit",
            displayName: "WhisperKit (Offline)",
            type: .asr,
            isEnabled: false,
            requiresApiKey: false
        ),
        ProviderConfig(
            id: "openai_whisper",
            displayName: "OpenAI Whisper",
            type: .asr,
            isEnabled: false,
            requiresApiKey: true
        ),
        ProviderConfig(
            id: "deepgram",
            displayName: "Deepgram Nova-3",
            type: .asr,
            isEnabled: false,
            requiresApiKey: true
        ),
        ProviderConfig(
            id: "iflytek",
            displayName: "iFlytek (讯飞)",
            type: .asr,
            isEnabled: false,
            requiresApiKey: true
        ),
        ProviderConfig(
            id: "volcano",
            displayName: "Volcano Engine (火山引擎)",
            type: .asr,
            isEnabled: false,
            requiresApiKey: true
        )
    ]

    public static let correctionProviders: [ProviderConfig] = [
        ProviderConfig(
            id: "openai_gpt",
            displayName: "OpenAI GPT-4o",
            type: .correction,
            isEnabled: false,
            requiresApiKey: true
        ),
        ProviderConfig(
            id: "claude",
            displayName: "Claude",
            type: .correction,
            isEnabled: false,
            requiresApiKey: true
        ),
        ProviderConfig(
            id: "doubao",
            displayName: "Doubao (豆包)",
            type: .correction,
            isEnabled: false,
            requiresApiKey: true
        )
    ]
}
