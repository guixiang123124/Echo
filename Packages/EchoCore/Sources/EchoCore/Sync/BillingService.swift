import Foundation

public struct BillingSnapshot: Codable, Sendable {
    public struct Subscription: Codable, Sendable {
        public let id: String
        public let status: String
        public let tier: String
        public let priceId: String?
        public let currentPeriodEnd: Date?
        public let cancelAtPeriodEnd: Bool
    }

    public let tier: String
    public let hasActiveSubscription: Bool
    public let subscription: Subscription?
}

@MainActor
public final class BillingService: ObservableObject {
    public static let shared = BillingService()

    public enum Status: Equatable {
        case idle
        case disabled(String)
        case loading
        case loaded(Date)
        case error(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var snapshot: BillingSnapshot?
    @Published public private(set) var isConfigured = false
    @Published public private(set) var isSignedIn = false

    private var endpointBaseURL: URL?
    private var isEnabled = true

    private init() {}

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        updateDerivedState()
    }

    public func updateAuthState(user: EchoUser?) {
        isSignedIn = user != nil
        updateDerivedState()
    }

    public func configure(baseURLString: String?) {
        let normalized = normalize(baseURLString)
        endpointBaseURL = normalized.flatMap(URL.init(string:))
        isConfigured = endpointBaseURL != nil
        updateDerivedState()
    }

    public func configureIfNeeded() {
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: "echo.cloud.sync.baseURL")
        configure(baseURLString: baseURL)
    }

    public func refresh() async {
        guard isEnabled else {
            status = .disabled("Billing disabled")
            snapshot = nil
            return
        }

        guard let endpointBaseURL else {
            status = .disabled("Cloud backend not configured")
            snapshot = nil
            return
        }

        guard let accessToken = EchoAuthSession.shared.accessToken else {
            status = .disabled("Sign in to load plan")
            snapshot = nil
            return
        }

        status = .loading

        do {
            let requestURL = URL(string: "/v1/billing/status", relativeTo: endpointBaseURL)
            guard let requestURL else {
                throw BillingError.invalidEndpoint
            }

            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BillingError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let raw = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw BillingError.server(raw)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(BillingSnapshot.self, from: data)
            snapshot = decoded
            status = .loaded(Date())
        } catch {
            snapshot = nil
            status = .error(error.localizedDescription)
        }
    }
}

private extension BillingService {
    func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    func updateDerivedState() {
        if !isEnabled {
            status = .disabled("Billing disabled")
            return
        }
        if !isConfigured {
            status = .disabled("Cloud backend not configured")
            return
        }
        if !isSignedIn {
            status = .disabled("Sign in to load plan")
            return
        }
        if case .loaded = status {
            return
        }
        if case .loading = status {
            return
        }
        status = .idle
    }
}

private enum BillingError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Billing endpoint is invalid."
        case .invalidResponse:
            return "Billing response is invalid."
        case .server(let message):
            return message
        }
    }
}
