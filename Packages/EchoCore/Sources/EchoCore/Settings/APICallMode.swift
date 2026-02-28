import Foundation

/// Controls how ASR and LLM API calls are routed.
public enum APICallMode: String, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }
    /// Device calls provider APIs directly using API keys stored in Keychain.
    case clientDirect = "client_direct"

    /// Device sends audio/text to the Railway backend which holds API keys server-side.
    case backendProxy = "backend_proxy"

    public var displayName: String {
        switch self {
        case .clientDirect: return "Direct (Client API Keys)"
        case .backendProxy: return "Backend Proxy (Railway)"
        }
    }

    public var description: String {
        switch self {
        case .clientDirect:
            return "API calls go directly from this device to providers. Requires API keys in Settings."
        case .backendProxy:
            return "API calls go through your Railway backend. Keys are managed server-side."
        }
    }
}
