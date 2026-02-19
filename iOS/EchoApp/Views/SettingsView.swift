import SwiftUI
import EchoCore
import AuthenticationServices
import GoogleSignIn
import UIKit

struct SettingsView: View {
    @State private var settings = AppSettings()
    @StateObject private var authSession = EchoAuthSession.shared
    @StateObject private var cloudSync = CloudSyncService.shared
    @State private var showAuthSheet = false
    @State private var selectedASR: String = ""
    @State private var correctionEnabled = true
    @State private var correctionHomophonesEnabled = true
    @State private var correctionPunctuationEnabled = true
    @State private var correctionFormattingEnabled = true
    @State private var autoEditQuickMode: AutoEditQuickMode = .balanced
    @State private var selectedCorrection: String = ""
    @State private var hapticEnabled = true
    @State private var cloudSyncBaseURL = ""
    @State private var cloudUploadAudioEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if cloudSyncBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Cloud backend not configured. Local history still works.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if authSession.isSignedIn {
                        HStack {
                            Text("Signed in")
                            Spacer()
                            Text(authSession.displayName)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Sign in to sync history across devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Sync History to Cloud", isOn: Binding(
                        get: { settings.cloudSyncEnabled },
                        set: { newValue in
                            settings.cloudSyncEnabled = newValue
                            CloudSyncService.shared.setEnabled(newValue)
                            BillingService.shared.setEnabled(newValue)
                        }
                    ))

                    TextField("Cloud API URL (Railway)", text: $cloudSyncBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: cloudSyncBaseURL) { _, newValue in
                            settings.cloudSyncBaseURL = newValue
                            authSession.configureBackend(baseURL: newValue)
                            cloudSync.configure(
                                baseURLString: newValue,
                                uploadAudio: cloudUploadAudioEnabled
                            )
                            BillingService.shared.configure(baseURLString: newValue)
                        }

                    Toggle("Upload audio to cloud (optional)", isOn: $cloudUploadAudioEnabled)
                        .onChange(of: cloudUploadAudioEnabled) { _, newValue in
                            settings.cloudUploadAudioEnabled = newValue
                            cloudSync.configure(
                                baseURLString: cloudSyncBaseURL,
                                uploadAudio: newValue
                            )
                        }

                    Button(authSession.isSignedIn ? "Switch User" : "Sign In") {
                        showAuthSheet = true
                    }

                    if authSession.isSignedIn {
                        Button("Sign Out") { authSession.signOut() }
                            .foregroundStyle(.red)
                    }
                }

                // ASR Provider Section
                Section("Speech Recognition") {
                    Picker("Provider", selection: $selectedASR) {
                        ForEach(AvailableProviders.asrProviders) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }

                    Toggle("Prefer Streaming", isOn: .init(
                        get: { settings.preferStreaming },
                        set: { settings.preferStreaming = $0 }
                    ))
                }

                // Auto Edit Section
                Section("Auto Edit") {
                    Toggle("Enable Auto Edit", isOn: $correctionEnabled)
                        .onChange(of: correctionEnabled) { _, newValue in
                            settings.correctionEnabled = newValue
                        }

                    if correctionEnabled {
                        Picker("Quick Mode", selection: $autoEditQuickMode) {
                            ForEach(AutoEditQuickMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: autoEditQuickMode) { _, newValue in
                            applyQuickMode(newValue)
                        }

                        Toggle("Fix Homophones", isOn: $correctionHomophonesEnabled)
                            .onChange(of: correctionHomophonesEnabled) { _, newValue in
                                settings.correctionHomophonesEnabled = newValue
                            }

                        Toggle("Fix Punctuation", isOn: $correctionPunctuationEnabled)
                            .onChange(of: correctionPunctuationEnabled) { _, newValue in
                                settings.correctionPunctuationEnabled = newValue
                            }

                        Toggle("Fix Formatting", isOn: $correctionFormattingEnabled)
                            .onChange(of: correctionFormattingEnabled) { _, newValue in
                                settings.correctionFormattingEnabled = newValue
                            }

                        Picker("Provider", selection: $selectedCorrection) {
                            ForEach(AvailableProviders.correctionProviders) { provider in
                                Text(provider.displayName).tag(provider.id)
                            }
                        }
                    }
                }

                // API Keys Section
                Section("API Keys") {
                    NavigationLink("Manage API Keys") {
                        ProviderSettingsView()
                    }
                }

                // Keyboard Section
                Section("Keyboard") {
                    Toggle("Haptic Feedback", isOn: $hapticEnabled)
                        .onChange(of: hapticEnabled) { _, newValue in
                            settings.hapticFeedbackEnabled = newValue
                        }

                    Toggle("Auto-Capitalization", isOn: .init(
                        get: { settings.autoCapitalizationEnabled },
                        set: { settings.autoCapitalizationEnabled = $0 }
                    ))

                    Picker("Default Input", selection: .init(
                        get: { settings.defaultInputMode },
                        set: { settings.defaultInputMode = $0 }
                    )) {
                        Text("English").tag("english")
                        Text("Chinese (Pinyin)").tag("pinyin")
                    }
                }

                // Setup Guide
                Section("Setup") {
                    NavigationLink("How to Enable Keyboard") {
                        KeyboardSetupGuide()
                    }
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                selectedASR = settings.selectedASRProvider
                correctionEnabled = settings.correctionEnabled
                correctionHomophonesEnabled = settings.correctionHomophonesEnabled
                correctionPunctuationEnabled = settings.correctionPunctuationEnabled
                correctionFormattingEnabled = settings.correctionFormattingEnabled
                autoEditQuickMode = resolveQuickMode()
                selectedCorrection = settings.selectedCorrectionProvider
                hapticEnabled = settings.hapticFeedbackEnabled
                cloudSyncBaseURL = settings.cloudSyncBaseURL
                cloudUploadAudioEnabled = settings.cloudUploadAudioEnabled

                authSession.configureBackend(baseURL: cloudSyncBaseURL)
                cloudSync.configure(
                    baseURLString: cloudSyncBaseURL,
                    uploadAudio: cloudUploadAudioEnabled
                )
                cloudSync.setEnabled(settings.cloudSyncEnabled)
                cloudSync.updateAuthState(user: authSession.user)
                BillingService.shared.configure(baseURLString: cloudSyncBaseURL)
                BillingService.shared.setEnabled(settings.cloudSyncEnabled)
                BillingService.shared.updateAuthState(user: authSession.user)
            }
            .onChange(of: selectedASR) { _, newValue in
                settings.selectedASRProvider = newValue
            }
            .onChange(of: selectedCorrection) { _, newValue in
                settings.selectedCorrectionProvider = newValue
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthSheetView()
                .environmentObject(authSession)
        }
    }

    private func applyQuickMode(_ mode: AutoEditQuickMode) {
        switch mode {
        case .balanced:
            correctionHomophonesEnabled = true
            correctionPunctuationEnabled = true
            correctionFormattingEnabled = true
        case .homophonesOnly:
            correctionHomophonesEnabled = true
            correctionPunctuationEnabled = false
            correctionFormattingEnabled = false
        case .punctuationOnly:
            correctionHomophonesEnabled = false
            correctionPunctuationEnabled = true
            correctionFormattingEnabled = false
        case .formattingOnly:
            correctionHomophonesEnabled = false
            correctionPunctuationEnabled = false
            correctionFormattingEnabled = true
        }

        settings.correctionHomophonesEnabled = correctionHomophonesEnabled
        settings.correctionPunctuationEnabled = correctionPunctuationEnabled
        settings.correctionFormattingEnabled = correctionFormattingEnabled
    }

    private func resolveQuickMode() -> AutoEditQuickMode {
        let homophones = correctionHomophonesEnabled
        let punctuation = correctionPunctuationEnabled
        let formatting = correctionFormattingEnabled

        if homophones && punctuation && formatting { return .balanced }
        if homophones && !punctuation && !formatting { return .homophonesOnly }
        if punctuation && !homophones && !formatting { return .punctuationOnly }
        if formatting && !homophones && !punctuation { return .formattingOnly }

        return .balanced
    }
}

private enum AutoEditQuickMode: String, CaseIterable, Identifiable {
    case balanced
    case homophonesOnly
    case punctuationOnly
    case formattingOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .homophonesOnly:
            return "Homophones"
        case .punctuationOnly:
            return "Punctuation"
        case .formattingOnly:
            return "Formatting"
        }
    }
}

// MARK: - Auth Sheet (iOS)

struct AuthSheetView: View {
    @EnvironmentObject var authSession: EchoAuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var currentNonce: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Sign in") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)

                    HStack {
                        Button("Sign In") {
                            Task { await authSession.signIn(email: email, password: password) }
                        }
                        Button("Create Account") {
                            Task { await authSession.signUp(email: email, password: password) }
                        }
                    }

                    Text("Use your Gmail address here, or continue with Apple below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("Sign in with Google")
                            Spacer()
                        }
                    }

                    SignInWithAppleButton(.signIn) { request in
                        let nonce = NonceHelper.randomNonce()
                        currentNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = NonceHelper.sha256(nonce)
                    } onCompletion: { result in
                        switch result {
                        case .success(let auth):
                            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                                  let nonce = currentNonce else { return }
                            Task { await authSession.signInWithApple(credential: credential, nonce: nonce) }
                        case .failure(let error):
                            authSession.errorMessage = error.localizedDescription
                        }
                    }
                    .frame(height: 44)
                }

                if authSession.isLoading {
                    ProgressView()
                }

                if let error = authSession.errorMessage, !error.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func signInWithGoogle() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            authSession.errorMessage = "Unable to find active window for Google sign-in."
            return
        }

        let clientID = (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID_IOS") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String)

        if let clientID, !clientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        GIDSignIn.sharedInstance.signIn(withPresenting: root) { result, error in
            if let error {
                Task { @MainActor in
                    self.authSession.errorMessage = error.localizedDescription
                }
                return
            }

            guard let idToken = result?.user.idToken?.tokenString else {
                Task { @MainActor in
                    self.authSession.errorMessage = "Google sign-in did not return an ID token."
                }
                return
            }

            Task { @MainActor in
                await self.authSession.signInWithGoogle(idToken: idToken)
            }
        }
    }
}

// MARK: - Keyboard Setup Guide

struct KeyboardSetupGuide: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    setupStep(number: 1, text: "Open Settings app")
                    setupStep(number: 2, text: "Go to General > Keyboard > Keyboards")
                    setupStep(number: 3, text: "Tap 'Add New Keyboard...'")
                    setupStep(number: 4, text: "Select 'Echo'")
                    setupStep(number: 5, text: "(Recommended) Tap 'Echo' and enable 'Allow Full Access' to enable Voice + AI")
                    setupStep(number: 6, text: "Switch to Echo using the globe key")
                }
                .padding(.vertical, 8)
            } header: {
                Text("Setup Steps")
            } footer: {
                Text("Voice input and AI correction work best with Allow Full Access. Without it, you can still use Echo as a regular keyboard.")
            }
        }
        .navigationTitle("Keyboard Setup")
    }

    private func setupStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue))

            Text(text)
                .font(.body)
        }
    }
}
