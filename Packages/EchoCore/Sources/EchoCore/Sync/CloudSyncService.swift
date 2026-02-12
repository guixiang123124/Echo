import Foundation

public struct CloudRecording: Codable, Sendable {
    public let id: String
    public let createdAt: Date
    public let duration: Double
    public let sampleRate: Double
    public let channelCount: Int
    public let bitsPerSample: Int
    public let encoding: String
    public let asrProviderId: String
    public let asrProviderName: String
    public let correctionProviderId: String?
    public let transcriptRaw: String?
    public let transcriptFinal: String?
    public let wordCount: Int
    public let status: String
    public let error: String?
    public let audioStoragePath: String?
    public let audioDownloadURL: String?
    public let deviceId: String

    public init(
        id: String,
        createdAt: Date,
        duration: Double,
        sampleRate: Double,
        channelCount: Int,
        bitsPerSample: Int,
        encoding: String,
        asrProviderId: String,
        asrProviderName: String,
        correctionProviderId: String?,
        transcriptRaw: String?,
        transcriptFinal: String?,
        wordCount: Int,
        status: String,
        error: String?,
        audioStoragePath: String?,
        audioDownloadURL: String?,
        deviceId: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.encoding = encoding
        self.asrProviderId = asrProviderId
        self.asrProviderName = asrProviderName
        self.correctionProviderId = correctionProviderId
        self.transcriptRaw = transcriptRaw
        self.transcriptFinal = transcriptFinal
        self.wordCount = wordCount
        self.status = status
        self.error = error
        self.audioStoragePath = audioStoragePath
        self.audioDownloadURL = audioDownloadURL
        self.deviceId = deviceId
    }
}

@MainActor
public final class CloudSyncService: ObservableObject {
    public static let shared = CloudSyncService()

    public enum Status: Equatable {
        case idle
        case disabled(String)
        case syncing
        case synced(Date)
        case error(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var isConfigured: Bool = false
    @Published public private(set) var isSignedIn: Bool = false

    private var endpointBaseURL: URL?
    private var uploadAudioEnabled: Bool = false
    private var isEnabled: Bool = true

    private init() {}

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        updateDerivedStatus()
    }

    public func updateAuthState(user: EchoUser?) {
        isSignedIn = user != nil
        updateDerivedStatus()
    }

    public func configure(baseURLString: String?, uploadAudio: Bool = false) {
        let normalized = normalize(baseURLString)
        endpointBaseURL = normalized.flatMap(URL.init(string:))
        uploadAudioEnabled = uploadAudio
        isConfigured = endpointBaseURL != nil
        updateDerivedStatus()
    }

    public func configureIfNeeded() {
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: "echo.cloud.sync.baseURL")
        let uploadAudio = defaults.bool(forKey: "echo.cloud.sync.uploadAudio")
        configure(baseURLString: baseURL, uploadAudio: uploadAudio)
    }

    public func syncRecording(_ payload: CloudRecording, audioURL: URL?) async {
        guard isEnabled else {
            status = .disabled("Sync disabled")
            return
        }

        guard let endpointBaseURL else {
            status = .disabled("Cloud backend not configured")
            return
        }

        guard let user = EchoAuthSession.shared.user else {
            status = .disabled("Sign in to sync")
            return
        }

        guard let accessToken = EchoAuthSession.shared.accessToken else {
            status = .disabled("No access token")
            return
        }

        status = .syncing

        do {
            let requestPayload = SyncRequestPayload(
                userId: user.uid,
                recording: payload,
                includeAudio: uploadAudioEnabled,
                audioBase64: try encodeAudioForUpload(audioURL: audioURL),
                audioFileName: audioURL?.lastPathComponent
            )

            try await postSync(
                payload: requestPayload,
                endpointBaseURL: endpointBaseURL,
                accessToken: accessToken
            )

            let now = Date()
            lastSync = now
            status = .synced(now)
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}

// MARK: - Private

private extension CloudSyncService {
    func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    func updateDerivedStatus() {
        if !isEnabled {
            status = .disabled("Sync disabled")
            return
        }
        if !isConfigured {
            status = .disabled("Cloud backend not configured")
            return
        }
        if !isSignedIn {
            status = .disabled("Sign in to sync")
            return
        }
        if case .synced = status {
            return
        }
        if case .syncing = status {
            return
        }
        status = .idle
    }

    func encodeAudioForUpload(audioURL: URL?) throws -> String? {
        guard uploadAudioEnabled, let audioURL else { return nil }

        let data = try Data(contentsOf: audioURL)
        // Keep request size bounded in app-side sync path.
        if data.count > 2_500_000 {
            return nil
        }
        return data.base64EncodedString()
    }

    func postSync(
        payload: SyncRequestPayload,
        endpointBaseURL: URL,
        accessToken: String
    ) async throws {
        let syncURL = URL(string: "/v1/sync/recordings", relativeTo: endpointBaseURL)
        guard let syncURL else {
            throw CloudSyncError.invalidEndpoint
        }

        var request = URLRequest(url: syncURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudSyncError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw CloudSyncError.server(message)
        }
    }
}

private struct SyncRequestPayload: Encodable {
    let userId: String
    let recording: CloudRecording
    let includeAudio: Bool
    let audioBase64: String?
    let audioFileName: String?
}

private enum CloudSyncError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Cloud sync endpoint is invalid."
        case .invalidResponse:
            return "Cloud sync response is invalid."
        case .server(let message):
            return message
        }
    }
}
