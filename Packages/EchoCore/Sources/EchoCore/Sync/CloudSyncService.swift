import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFirestoreSwift
import FirebaseStorage

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

    private let deviceId = UUID().uuidString
    private var isEnabled: Bool = true

    private init() {}

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            status = .disabled("Sync disabled")
        }
    }

    public func updateAuthState(user: User?) {
        isSignedIn = user != nil
        if user == nil {
            status = .disabled("Sign in to sync")
        }
    }

    public func configureIfNeeded() {
        isConfigured = FirebaseBootstrapper.configureIfPossible()
        if !isConfigured {
            status = .disabled("Firebase not configured")
        }
    }

    public func syncRecording(_ payload: CloudRecording, audioURL: URL?) async {
        guard isEnabled else {
            status = .disabled("Sync disabled")
            return
        }

        guard FirebaseApp.app() != nil else {
            status = .disabled("Firebase not configured")
            return
        }

        guard let user = Auth.auth().currentUser else {
            status = .disabled("Sign in to sync")
            return
        }

        status = .syncing

        do {
            var updatedPayload = payload
            var storagePath: String?
            var downloadURL: String?

            if let audioURL {
                let storage = Storage.storage()
                let ref = storage.reference().child("users/\(user.uid)/recordings/\(payload.id).wav")
                _ = try await ref.putFileAsync(from: audioURL)
                storagePath = ref.fullPath
                downloadURL = try await ref.downloadURL().absoluteString
            }

            updatedPayload = CloudRecording(
                id: payload.id,
                createdAt: payload.createdAt,
                duration: payload.duration,
                sampleRate: payload.sampleRate,
                channelCount: payload.channelCount,
                bitsPerSample: payload.bitsPerSample,
                encoding: payload.encoding,
                asrProviderId: payload.asrProviderId,
                asrProviderName: payload.asrProviderName,
                correctionProviderId: payload.correctionProviderId,
                transcriptRaw: payload.transcriptRaw,
                transcriptFinal: payload.transcriptFinal,
                wordCount: payload.wordCount,
                status: payload.status,
                error: payload.error,
                audioStoragePath: storagePath,
                audioDownloadURL: downloadURL,
                deviceId: payload.deviceId
            )

            let db = Firestore.firestore()
            let doc = db.collection("users")
                .document(user.uid)
                .collection("recordings")
                .document(payload.id)
            try doc.setData(from: updatedPayload, merge: true)

            let now = Date()
            lastSync = now
            status = .synced(now)
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
