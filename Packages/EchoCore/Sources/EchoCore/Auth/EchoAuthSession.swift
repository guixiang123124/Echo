import Foundation
import FirebaseAuth
import AuthenticationServices

@MainActor
public final class EchoAuthSession: ObservableObject {
    public static let shared = EchoAuthSession()

    @Published public private(set) var user: User?
    @Published public private(set) var isConfigured = false
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private var authHandle: AuthStateDidChangeListenerHandle?

    private init() {}

    public var isSignedIn: Bool {
        user != nil
    }

    public var userId: String? {
        user?.uid
    }

    public var displayName: String {
        if let name = user?.displayName, !name.isEmpty { return name }
        if let email = user?.email { return email }
        if let phone = user?.phoneNumber { return phone }
        return "Signed-in user"
    }

    public func start() {
        isConfigured = FirebaseBootstrapper.configureIfPossible()
        guard isConfigured else {
            errorMessage = "Firebase not configured"
            return
        }
        if authHandle == nil {
            authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
                guard let self else { return }
                self.user = user
            }
        }
        user = Auth.auth().currentUser
    }

    public func stop() {
        if let handle = authHandle {
            Auth.auth().removeStateDidChangeListener(handle)
            authHandle = nil
        }
    }

    public func signOut() {
        errorMessage = nil
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signIn(email: String, password: String) async {
        errorMessage = nil
        guard isConfigured else {
            errorMessage = "Firebase not configured"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signUp(email: String, password: String) async {
        errorMessage = nil
        guard isConfigured else {
            errorMessage = "Firebase not configured"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await Auth.auth().createUser(withEmail: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func signInWithApple(credential: ASAuthorizationAppleIDCredential, nonce: String) async {
        errorMessage = nil
        guard isConfigured else {
            errorMessage = "Firebase not configured"
            return
        }

        guard let identityToken = credential.identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8) else {
            errorMessage = "Unable to fetch Apple identity token"
            return
        }

        let firebaseCredential = OAuthProvider.credential(
            withProviderID: "apple.com",
            idToken: tokenString,
            rawNonce: nonce
        )

        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await Auth.auth().signIn(with: firebaseCredential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

#if os(iOS)
    private var phoneVerificationId: String?

    public func startPhoneVerification(_ phoneNumber: String) async {
        errorMessage = nil
        guard isConfigured else {
            errorMessage = "Firebase not configured"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let verificationId = try await PhoneAuthProvider.provider().verifyPhoneNumber(phoneNumber, uiDelegate: nil)
            phoneVerificationId = verificationId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func verifyPhoneCode(_ code: String) async {
        errorMessage = nil
        guard isConfigured else {
            errorMessage = "Firebase not configured"
            return
        }
        guard let verificationId = phoneVerificationId else {
            errorMessage = "Missing verification request"
            return
        }
        isLoading = true
        defer { isLoading = false }
        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationId,
            verificationCode: code
        )
        do {
            _ = try await Auth.auth().signIn(with: credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
#endif
}
