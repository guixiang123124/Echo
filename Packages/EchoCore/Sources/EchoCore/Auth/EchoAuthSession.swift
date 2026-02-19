import Foundation
import AuthenticationServices
import CryptoKit

public struct EchoUser: Codable, Sendable, Equatable {
    public let uid: String
    public let email: String?
    public let phoneNumber: String?
    public let displayName: String?
    public let provider: String

    public init(
        uid: String,
        email: String? = nil,
        phoneNumber: String? = nil,
        displayName: String? = nil,
        provider: String
    ) {
        self.uid = uid
        self.email = email
        self.phoneNumber = phoneNumber
        self.displayName = displayName
        self.provider = provider
    }
}

@MainActor
public final class EchoAuthSession: ObservableObject {
    public static let shared = EchoAuthSession()

    @Published public private(set) var user: EchoUser?
    @Published public private(set) var isConfigured = false
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?
    @Published public private(set) var backendBaseURL: String = ""

    private let keyStore = SecureKeyStore(serviceName: "com.echo.auth")
    private let defaults = UserDefaults.standard
    private var accessTokenValue: String?
    private var refreshTokenValue: String?

    private enum Keys {
        static let backendBaseURL = "echo.cloud.sync.baseURL"
        static let userJSON = "auth.user.json"
        static let accessToken = "auth.access.token"
        static let refreshToken = "auth.refresh.token"
    }

    private init() {}

    public var isSignedIn: Bool {
        user != nil
    }

    public var userId: String? {
        user?.uid
    }

    public var accessToken: String? {
        accessTokenValue
    }

    public var displayName: String {
        if let name = user?.displayName, !name.isEmpty { return name }
        if let email = user?.email, !email.isEmpty { return email }
        if let phone = user?.phoneNumber, !phone.isEmpty { return phone }
        return "Signed-in user"
    }

    public func start() {
        backendBaseURL = defaults.string(forKey: Keys.backendBaseURL) ?? ""
        isConfigured = normalizedBackendURLString != nil
        restoreSession()
    }

    public func stop() {}

    public func configureBackend(baseURL: String?) {
        let normalized = normalize(baseURL)
        backendBaseURL = normalized ?? ""
        defaults.set(backendBaseURL, forKey: Keys.backendBaseURL)
        isConfigured = normalized != nil
    }

    public func signOut() {
        errorMessage = nil
        user = nil
        accessTokenValue = nil
        refreshTokenValue = nil
        try? keyStore.delete(for: Keys.userJSON)
        try? keyStore.delete(for: Keys.accessToken)
        try? keyStore.delete(for: Keys.refreshToken)
    }

    public func signIn(email: String, password: String) async {
        errorMessage = nil
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            errorMessage = "Email and password are required."
            return
        }

        if normalizedBackendURLString == nil {
            // Local-only fallback for privacy-first mode.
            let localUser = makeLocalEmailUser(email: normalizedEmail)
            persistSession(user: localUser, accessToken: nil, refreshToken: nil)
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await authenticate(
                path: "/v1/auth/login",
                payload: EmailPasswordPayload(email: normalizedEmail, password: password)
            )
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signUp(email: String, password: String) async {
        errorMessage = nil
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            errorMessage = "Email and password are required."
            return
        }

        if normalizedBackendURLString == nil {
            let localUser = makeLocalEmailUser(email: normalizedEmail)
            persistSession(user: localUser, accessToken: nil, refreshToken: nil)
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await authenticate(
                path: "/v1/auth/register",
                payload: EmailPasswordPayload(email: normalizedEmail, password: password)
            )
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signInWithApple(credential: ASAuthorizationAppleIDCredential, nonce: String) async {
        errorMessage = nil

        guard let backendBaseURL = normalizedBackendURLString else {
            errorMessage = "Apple sign-in requires Cloud API URL in Settings."
            return
        }

        guard let identityToken = credential.identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8) else {
            errorMessage = "Unable to fetch Apple identity token."
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await authenticate(
                path: "/v1/auth/apple",
                payload: AppleSignInPayload(
                    identityToken: tokenString,
                    nonce: nonce,
                    email: credential.email,
                    fullName: [credential.fullName?.givenName, credential.fullName?.familyName]
                        .compactMap { $0 }
                        .joined(separator: " ")
                ),
                baseURLString: backendBaseURL
            )
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signInWithGoogle(idToken: String) async {
        errorMessage = nil

        guard let backendBaseURL = normalizedBackendURLString else {
            errorMessage = "Google sign-in requires Cloud API URL in Settings."
            return
        }

        guard !idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Missing Google ID token."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await authenticate(
                path: "/v1/auth/google",
                payload: GoogleSignInPayload(idToken: idToken),
                baseURLString: backendBaseURL
            )
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

#if os(iOS)
    public func startPhoneVerification(_ phoneNumber: String) async {
        errorMessage = "Phone verification is not enabled in this build."
    }

    public func verifyPhoneCode(_ code: String) async {
        errorMessage = "Phone verification is not enabled in this build."
    }
#endif
}

// MARK: - Private

@MainActor
private extension EchoAuthSession {
    var normalizedBackendURLString: String? {
        normalize(backendBaseURL)
    }

    func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    func restoreSession() {
        do {
            let storedUserJSON = try keyStore.retrieve(for: Keys.userJSON)
            if let storedUserJSON, !storedUserJSON.isEmpty {
                let data = Data(storedUserJSON.utf8)
                user = try JSONDecoder().decode(EchoUser.self, from: data)
            } else {
                user = nil
            }
            accessTokenValue = try keyStore.retrieve(for: Keys.accessToken)
            refreshTokenValue = try keyStore.retrieve(for: Keys.refreshToken)
        } catch {
            user = nil
            accessTokenValue = nil
            refreshTokenValue = nil
            errorMessage = "Failed to restore session: \(error.localizedDescription)"
        }
    }

    func persistSession(user: EchoUser, accessToken: String?, refreshToken: String?) {
        self.user = user
        self.accessTokenValue = accessToken
        self.refreshTokenValue = refreshToken

        do {
            let data = try JSONEncoder().encode(user)
            if let json = String(data: data, encoding: .utf8) {
                try keyStore.store(key: json, for: Keys.userJSON)
            }
            if let accessToken {
                try keyStore.store(key: accessToken, for: Keys.accessToken)
            } else {
                try? keyStore.delete(for: Keys.accessToken)
            }
            if let refreshToken {
                try keyStore.store(key: refreshToken, for: Keys.refreshToken)
            } else {
                try? keyStore.delete(for: Keys.refreshToken)
            }
        } catch {
            errorMessage = "Failed to persist auth session: \(error.localizedDescription)"
        }
    }

    func makeLocalEmailUser(email: String) -> EchoUser {
        let digest = SHA256.hash(data: Data(email.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return EchoUser(
            uid: "local-\(hex.prefix(20))",
            email: email,
            displayName: email,
            provider: "local-email"
        )
    }

    func authenticate<T: Encodable>(
        path: String,
        payload: T,
        baseURLString: String? = nil
    ) async throws -> AuthResult {
        guard let endpointBase = baseURLString ?? normalizedBackendURLString,
              let baseURL = URL(string: endpointBase),
              let url = URL(string: path, relativeTo: baseURL) else {
            throw AuthError.backendNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AuthError.server(message)
        }

        let envelope = try JSONDecoder().decode(AuthEnvelope.self, from: data)
        guard let user = envelope.user?.toEchoUser() else {
            throw AuthError.invalidResponse
        }

        return AuthResult(
            user: user,
            accessToken: envelope.accessToken ?? envelope.token,
            refreshToken: envelope.refreshToken
        )
    }
}

private struct AuthResult: Sendable {
    let user: EchoUser
    let accessToken: String?
    let refreshToken: String?
}

private struct EmailPasswordPayload: Encodable {
    let email: String
    let password: String
}

private struct AppleSignInPayload: Encodable {
    let identityToken: String
    let nonce: String
    let email: String?
    let fullName: String?
}

private struct GoogleSignInPayload: Encodable {
    let idToken: String
}

private struct AuthEnvelope: Decodable {
    let user: EchoUserDTO?
    let accessToken: String?
    let refreshToken: String?
    let token: String?
}

private struct EchoUserDTO: Decodable {
    let id: String?
    let uid: String?
    let email: String?
    let phoneNumber: String?
    let displayName: String?
    let name: String?
    let provider: String?

    func toEchoUser() -> EchoUser? {
        let resolvedUID = uid ?? id
        guard let resolvedUID, !resolvedUID.isEmpty else { return nil }
        return EchoUser(
            uid: resolvedUID,
            email: email,
            phoneNumber: phoneNumber,
            displayName: displayName ?? name,
            provider: provider ?? "email"
        )
    }
}

private enum AuthError: LocalizedError {
    case backendNotConfigured
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "Cloud API URL is not configured."
        case .invalidResponse:
            return "Authentication response format is invalid."
        case .server(let message):
            return message
        }
    }
}
