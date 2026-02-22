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
    @State private var autoEditPreset: AutoEditPreset = .smartPolish
    @State private var autoEditApplyMode: AutoEditApplyMode = .autoReplace
    @State private var correctionHomophonesEnabled = true
    @State private var correctionPunctuationEnabled = true
    @State private var correctionFormattingEnabled = true
    @State private var correctionRemoveFillerEnabled = true
    @State private var correctionRemoveRepetitionEnabled = true
    @State private var correctionRewriteIntensity: RewriteIntensity = .light
    @State private var correctionTranslationEnabled = false
    @State private var correctionTranslationTarget: TranslationTargetLanguage = .keepSource
    @State private var correctionStructuredOutputStyle: StructuredOutputStyle = .off
    @State private var dictionaryAutoLearnEnabled = true
    @State private var dictionaryAutoLearnRequireReview = true
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
                    .disabled(selectedASR == "openai_whisper")

                    Toggle("Enable StreamFast", isOn: .init(
                        get: { settings.streamFastEnabled },
                        set: { settings.streamFastEnabled = $0 }
                    ))

                    if selectedASR == "openai_whisper" {
                        Text("OpenAI Transcribe currently runs in Batch mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Deepgram / Volcano support Batch and Stream. Stream is recommended for realtime typing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Auto Edit Section
                Section("Auto Edit") {
                    Picker("Preset", selection: $autoEditPreset) {
                        ForEach(AutoEditPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .onChange(of: autoEditPreset) { _, newValue in
                        settings.autoEditPreset = newValue
                        syncAutoEditSettingsFromStore()
                    }

                    Toggle("Enable Auto Edit", isOn: $correctionEnabled)
                        .onChange(of: correctionEnabled) { _, newValue in
                            settings.correctionEnabled = newValue
                        }

                    if correctionEnabled {
                        Picker("Apply Behavior", selection: $autoEditApplyMode) {
                            ForEach(AutoEditApplyMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .onChange(of: autoEditApplyMode) { _, newValue in
                            settings.autoEditApplyMode = newValue
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

                        Toggle("Remove Filler Words", isOn: $correctionRemoveFillerEnabled)
                            .onChange(of: correctionRemoveFillerEnabled) { _, newValue in
                                settings.correctionRemoveFillerEnabled = newValue
                            }

                        Toggle("Remove Repetitions", isOn: $correctionRemoveRepetitionEnabled)
                            .onChange(of: correctionRemoveRepetitionEnabled) { _, newValue in
                                settings.correctionRemoveRepetitionEnabled = newValue
                            }

                        Picker("Rewrite Intensity", selection: $correctionRewriteIntensity) {
                            ForEach(RewriteIntensity.allCases) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .onChange(of: correctionRewriteIntensity) { _, newValue in
                            settings.correctionRewriteIntensity = newValue
                        }

                        Picker("Structured Output", selection: $correctionStructuredOutputStyle) {
                            ForEach(StructuredOutputStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .onChange(of: correctionStructuredOutputStyle) { _, newValue in
                            settings.correctionStructuredOutputStyle = newValue
                        }

                        Toggle("Translate in Auto Edit", isOn: $correctionTranslationEnabled)
                            .onChange(of: correctionTranslationEnabled) { _, newValue in
                                settings.correctionTranslationEnabled = newValue
                            }

                        if correctionTranslationEnabled {
                            Picker("Target Language", selection: $correctionTranslationTarget) {
                                ForEach(TranslationTargetLanguage.allCases) { language in
                                    Text(language.displayName).tag(language)
                                }
                            }
                            .onChange(of: correctionTranslationTarget) { _, newValue in
                                settings.correctionTranslationTarget = newValue
                            }
                        }

                        Toggle("Dictionary Auto Learn", isOn: $dictionaryAutoLearnEnabled)
                            .onChange(of: dictionaryAutoLearnEnabled) { _, newValue in
                                settings.dictionaryAutoLearnEnabled = newValue
                            }

                        Toggle("Auto Learn Requires Review", isOn: $dictionaryAutoLearnRequireReview)
                            .onChange(of: dictionaryAutoLearnRequireReview) { _, newValue in
                                settings.dictionaryAutoLearnRequireReview = newValue
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
                syncAutoEditSettingsFromStore()
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
                if newValue == "openai_whisper" {
                    settings.preferStreaming = false
                } else if !settings.preferStreaming {
                    settings.preferStreaming = true
                }
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

    private func syncAutoEditSettingsFromStore() {
        autoEditPreset = settings.autoEditPreset
        autoEditApplyMode = settings.autoEditApplyMode
        correctionEnabled = settings.correctionEnabled
        correctionHomophonesEnabled = settings.correctionHomophonesEnabled
        correctionPunctuationEnabled = settings.correctionPunctuationEnabled
        correctionFormattingEnabled = settings.correctionFormattingEnabled
        correctionRemoveFillerEnabled = settings.correctionRemoveFillerEnabled
        correctionRemoveRepetitionEnabled = settings.correctionRemoveRepetitionEnabled
        correctionRewriteIntensity = settings.correctionRewriteIntensity
        correctionTranslationEnabled = settings.correctionTranslationEnabled
        correctionTranslationTarget = settings.correctionTranslationTarget
        correctionStructuredOutputStyle = settings.correctionStructuredOutputStyle
        dictionaryAutoLearnEnabled = settings.dictionaryAutoLearnEnabled
        dictionaryAutoLearnRequireReview = settings.dictionaryAutoLearnRequireReview
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
                                  let nonce = currentNonce else {
                                authSession.errorMessage = "Apple sign-in missing nonce."
                                return
                            }
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
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter { !$0.windows.isEmpty }

        guard let root = activeScenes
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?.rootViewController
            ?? activeScenes
                .flatMap(\.windows)
                .first(where: { $0.rootViewController != nil })?.rootViewController else {
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
