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
            print("⚠️ Email Auth: Empty email or password")
            return
        }

        if normalizedBackendURLString == nil {
            // Local-only fallback for privacy-first mode.
            print("ℹ️ Email Auth: Using local-only mode (no backend configured)")
            let localUser = makeLocalEmailUser(email: normalizedEmail)
            persistSession(user: localUser, accessToken: nil, refreshToken: nil)
            return
        }

        print("ℹ️ Email Auth: Signing in user \(normalizedEmail)")

        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await authenticate(
                path: "/v1/auth/login",
                payload: EmailPasswordPayload(email: normalizedEmail, password: password)
            )
            print("✅ Email Auth: Successfully authenticated user \(result.user.uid)")
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            let detailedError = formatAuthError(error, provider: "Email")
            errorMessage = detailedError
            print("⚠️ Email Auth: Failed - \(detailedError)")
        }
    }

    public func signUp(email: String, password: String) async {
        errorMessage = nil
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            errorMessage = "Email and password are required."
            print("⚠️ Email Signup: Empty email or password")
            return
        }

        if normalizedBackendURLString == nil {
            print("ℹ️ Email Signup: Using local-only mode (no backend configured)")
            let localUser = makeLocalEmailUser(email: normalizedEmail)
            persistSession(user: localUser, accessToken: nil, refreshToken: nil)
            return
        }

        print("ℹ️ Email Signup: Registering user \(normalizedEmail)")

        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await authenticate(
                path: "/v1/auth/register",
                payload: EmailPasswordPayload(email: normalizedEmail, password: password)
            )
            print("✅ Email Signup: Successfully registered user \(result.user.uid)")
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            let detailedError = formatAuthError(error, provider: "Email")
            errorMessage = detailedError
            print("⚠️ Email Signup: Failed - \(detailedError)")
        }
    }

    public func signInWithApple(credential: ASAuthorizationAppleIDCredential, nonce: String) async {
        errorMessage = nil

        guard let backendBaseURL = normalizedBackendURLString else {
            errorMessage = "Apple sign-in requires Cloud API URL in Settings."
            print("⚠️ Apple Auth: No backend URL configured")
            return
        }

        guard let identityToken = credential.identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8) else {
            errorMessage = "Unable to fetch Apple identity token."
            print("⚠️ Apple Auth: Failed to extract identity token from credential")
            return
        }

        print("ℹ️ Apple Auth: Starting authentication with backend at \(backendBaseURL)")
        print("ℹ️ Apple Auth: User ID: \(credential.user)")

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
            print("✅ Apple Auth: Successfully authenticated user \(result.user.uid)")
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            let detailedError = formatAuthError(error, provider: "Apple")
            errorMessage = detailedError
            print("⚠️ Apple Auth: Failed - \(detailedError)")
        }
    }

    public func signInWithGoogle(idToken: String) async {
        errorMessage = nil

        guard let backendBaseURL = normalizedBackendURLString else {
            errorMessage = "Google sign-in requires Cloud API URL in Settings."
            print("⚠️ Google Auth: No backend URL configured")
            return
        }

        guard !idToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Missing Google ID token."
            print("⚠️ Google Auth: Empty ID token provided")
            return
        }

        isLoading = true
        defer { isLoading = false }

        print("ℹ️ Google Auth: Starting authentication with backend at \(backendBaseURL)")

        do {
            let result = try await authenticate(
                path: "/v1/auth/google",
                payload: GoogleSignInPayload(idToken: idToken),
                baseURLString: backendBaseURL
            )
            print("✅ Google Auth: Successfully authenticated user \(result.user.uid)")
            persistSession(user: result.user, accessToken: result.accessToken, refreshToken: result.refreshToken)
        } catch {
            let detailedError = formatAuthError(error, provider: "Google")
            errorMessage = detailedError
            print("⚠️ Google Auth: Failed - \(detailedError)")
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

        // Extract diagnostic headers
        let backendErrorCode = http.value(forHTTPHeaderField: "X-Error-Code")
        let backendErrorReason = http.value(forHTTPHeaderField: "X-Error-Reason")
        let requestId = http.value(forHTTPHeaderField: "X-Request-Id")

        guard (200..<300).contains(http.statusCode) else {
            var message = "HTTP \(http.statusCode)"

            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                message = errorResponse.message ?? errorResponse.error ?? message
                if let code = errorResponse.code {
                    message = "[\(code)] \(message)"
                }
                if let details = errorResponse.details {
                    message += " - \(details)"
                }
            } else if let plainMessage = String(data: data, encoding: .utf8), !plainMessage.isEmpty {
                message = plainMessage
            }

            // Add backend diagnostic info
            if let errorCode = backendErrorCode {
                message += " (Backend Code: \(errorCode))"
            }
            if let errorReason = backendErrorReason {
                message += " (Reason: \(errorReason))"
            }
            if let requestId {
                print("ℹ️ Auth Request ID: \(requestId)")
            }

            throw AuthError.server(message, statusCode: http.statusCode)
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

    func formatAuthError(_ error: Error, provider: String) -> String {
        if let authError = error as? AuthError {
            switch authError {
            case .backendNotConfigured:
                return "\(provider) sign-in requires Cloud API URL in Settings. Please configure it in the app settings."
            case .invalidResponse:
                return "\(provider) authentication response is invalid. Please check your backend configuration or try again."
            case .server(let message, let statusCode):
                // Format server errors for better user understanding
                if statusCode == 401 {
                    return "\(provider) authentication failed: Invalid credentials or expired token. Please try signing in again."
                } else if statusCode == 403 {
                    return "\(provider) authentication forbidden: Your account may not have permission. Contact support if this persists."
                } else if statusCode == 404 {
                    return "\(provider) authentication endpoint not found. Please verify your Cloud API URL is correct."
                } else if statusCode == 500 || statusCode == 502 || statusCode == 503 {
                    return "\(provider) service temporarily unavailable. Please try again in a few moments."
                } else if message.contains("token") || message.contains("Token") {
                    return "\(provider) token validation failed: \(message)"
                } else if message.contains("email") || message.contains("Email") {
                    return "\(provider) email verification issue: \(message)"
                } else {
                    return "\(provider) authentication failed: \(message)"
                }
            }
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection. Please check your network and try again."
            case .timedOut:
                return "\(provider) authentication timed out. Please check your connection and try again."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot connect to authentication server. Please verify your Cloud API URL."
            default:
                return "Network error during \(provider) sign-in: \(urlError.localizedDescription)"
            }
        }

        return "\(provider) sign-in error: \(error.localizedDescription)"
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
    case server(String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "Cloud API URL is not configured."
        case .invalidResponse:
            return "Authentication response format is invalid."
        case .server(let message, _):
            return message
        }
    }
}

private struct ErrorResponse: Decodable {
    let error: String?
    let message: String?
    let code: String?
    let details: String?
}
