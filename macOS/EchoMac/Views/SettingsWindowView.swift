import SwiftUI
import EchoCore
import AuthenticationServices

/// Main settings window view with tab navigation
struct SettingsWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var authSession: EchoAuthSession
    @EnvironmentObject var cloudSync: CloudSyncService

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .environmentObject(settings)
                .environmentObject(permissionManager)
                .environmentObject(authSession)
                .environmentObject(cloudSync)

            ASRSettingsTab()
                .tabItem {
                    Label("Speech", systemImage: "waveform")
                }
                .environmentObject(settings)

            CorrectionSettingsTab()
                .tabItem {
                    Label("Auto Edit", systemImage: "sparkles")
                }
                .environmentObject(settings)

            PermissionsSettingsTab()
                .tabItem {
                    Label("Permissions", systemImage: "hand.raised")
                }
                .environmentObject(permissionManager)

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var authSession: EchoAuthSession
    @EnvironmentObject var cloudSync: CloudSyncService
    @State private var showAuthSheet = false

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Activation Key", selection: $settings.hotkeyType) {
                    ForEach(MacAppSettings.HotkeyType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                Text(settings.hotkeyHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Recording Mode") {
                Picker("Mode", selection: $settings.recordingMode) {
                    ForEach(MacAppSettings.RecordingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(settings.recordingMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Hands-Free Auto Stop") {
                Toggle("Stop on Silence", isOn: $settings.handsFreeAutoStopEnabled)

                HStack {
                    Text("Silence duration")
                    Spacer()
                    Text("\(settings.handsFreeSilenceDuration, specifier: "%.1f")s")
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.handsFreeSilenceDuration, in: 0.6...3.0, step: 0.1)

                HStack {
                    Text("Silence threshold")
                    Spacer()
                    Text("\(settings.handsFreeSilenceThreshold, specifier: "%.02f")")
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.handsFreeSilenceThreshold, in: 0.02...0.2, step: 0.01)

                HStack {
                    Text("Minimum recording")
                    Spacer()
                    Text("\(settings.handsFreeMinimumDuration, specifier: "%.1f")s")
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.handsFreeMinimumDuration, in: 0.5...2.5, step: 0.1)

                Text("Lower threshold is more sensitive to quiet speech.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                Toggle("Show Menu Bar Icon", isOn: .constant(true))
                    .disabled(true)
            }

            Section("Behavior") {
                Toggle("Play Sound on Start/Stop", isOn: $settings.playSoundEffects)
                Toggle("Show Recording Indicator", isOn: $settings.showRecordingPanel)
            }

            Section("Account") {
                if !authSession.isConfigured {
                    Text("Firebase not configured. Add GoogleService-Info.plist to enable sign-in and sync.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if authSession.isSignedIn {
                    HStack {
                        Text("Signed in")
                        Spacer()
                        Text(authSession.displayName)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Sign in to sync history across devices.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Sync History to Cloud", isOn: Binding(
                    get: { settings.cloudSyncEnabled },
                    set: { newValue in
                        settings.cloudSyncEnabled = newValue
                        cloudSync.setEnabled(newValue)
                    }
                ))

                Button(authSession.isSignedIn ? "Switch User" : "Sign In") {
                    showAuthSheet = true
                }
                .buttonStyle(.bordered)

                if authSession.isSignedIn {
                    Button("Sign Out") {
                        authSession.signOut()
                    }
                    .buttonStyle(.bordered)
                }

                TextField("Display name", text: $settings.userDisplayName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("User ID")
                    Spacer()
                    Text(settings.currentUserId)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Text("Records are stored locally and tagged to this user.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showAuthSheet) {
            AuthSheetView()
                .environmentObject(authSession)
        }
    }
}

// MARK: - ASR Settings Tab

struct ASRSettingsTab: View {
    @EnvironmentObject var settings: MacAppSettings

    var body: some View {
        Form {
            Section("Pipeline Presets") {
                Picker(
                    "Preset",
                    selection: Binding(
                        get: { settings.pipelinePreset },
                        set: { settings.pipelinePreset = $0 }
                    )
                ) {
                    ForEach(MacAppSettings.PipelinePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.pipelinePreset.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Speech Recognition (ASR)") {
                Picker("Speech Recognition Provider", selection: $settings.selectedASRProvider) {
                    Text("OpenAI Transcribe").tag("openai_whisper")
                    Text("Volcano Engine (ByteDance)").tag("volcano")
                    Text("Alibaba Cloud NLS").tag("aliyun")
                }
                .pickerStyle(.menu)

                if settings.selectedASRProvider == "volcano" {
                    ProviderKeyRow(
                        label: "Volcano App ID",
                        providerId: "volcano_app_id"
                    )

                    ProviderKeyRow(
                        label: "Volcano Access Key",
                        providerId: "volcano_access_key"
                    )

                    Text("Volcano requires both App ID and Access Key.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if settings.selectedASRProvider == "aliyun" {
                    ProviderKeyRow(
                        label: "Alibaba App Key",
                        providerId: "aliyun_app_key"
                    )

                    ProviderKeyRow(
                        label: "Alibaba Token",
                        providerId: "aliyun_token"
                    )

                    Text("Alibaba NLS tokens expire; refresh the token when it changes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ProviderKeyRow(
                        label: "OpenAI API Key",
                        providerId: "openai_whisper"
                    )

                    Picker("Transcription Model", selection: $settings.openAITranscriptionModel) {
                        Text("Whisper-1 (default)").tag("whisper-1")
                        Text("GPT-4o Transcribe").tag("gpt-4o-transcribe")
                        Text("GPT-4o Mini Transcribe").tag("gpt-4o-mini-transcribe")
                    }
                    .pickerStyle(.menu)

                    Text("All OpenAI transcription models use the same API key.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Auto Edit uses a separate model configured below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Auto Edit (Optional)") {
                Toggle("Enable Auto Edit", isOn: $settings.correctionEnabled)

                Picker("Provider", selection: $settings.selectedCorrectionProvider) {
                    Text("OpenAI GPT-4o").tag("openai_gpt")
                    Text("Claude").tag("claude")
                    Text("Doubao").tag("doubao")
                    Text("Alibaba Qwen").tag("qwen")
                }
                .pickerStyle(.menu)

                Text("Fine-grained options are available in the Auto Edit tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Language") {
                Picker("Recognition Language", selection: $settings.asrLanguage) {
                    Text("Auto Detect").tag("auto")
                    Divider()
                    Text("English").tag("en-US")
                    Text("中文 (简体)").tag("zh-CN")
                    Text("中文 (繁體)").tag("zh-TW")
                    Text("日本語").tag("ja-JP")
                    Text("한국어").tag("ko-KR")
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Correction Settings Tab

struct CorrectionSettingsTab: View {
    @EnvironmentObject var settings: MacAppSettings

    var body: some View {
        Form {
            Section("Auto Edit Pipeline") {
                Toggle("Enable Auto Edit", isOn: $settings.correctionEnabled)
                Text("Fixes homophones, punctuation, and formatting based on context.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if settings.correctionEnabled {
                    HStack(spacing: 8) {
                        ForEach(AutoEditQuickMode.allCases) { mode in
                            Button(mode.title) {
                                applyQuickMode(mode)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Toggle("Fix Homophones", isOn: $settings.correctionHomophonesEnabled)
                    Toggle("Fix Punctuation", isOn: $settings.correctionPunctuationEnabled)
                    Toggle("Fix Formatting", isOn: $settings.correctionFormattingEnabled)

                    Picker("AI Provider", selection: $settings.selectedCorrectionProvider) {
                        Text("OpenAI GPT-4o").tag("openai_gpt")
                        Text("Claude").tag("claude")
                        Text("豆包").tag("doubao")
                        Text("Alibaba Qwen").tag("qwen")
                    }
                    .pickerStyle(.menu)

                    ProviderKeyRow(
                        label: providerKeyLabel(for: settings.selectedCorrectionProvider),
                        providerId: settings.selectedCorrectionProvider
                    )
                }
            }

            Section("Editing Features") {
                Toggle("Remove Filler Words (um, uh, like)", isOn: .constant(true))
                Toggle("Remove Repetitions", isOn: .constant(true))
                Toggle("Auto Punctuation", isOn: .constant(true))
                Toggle("Smart Formatting", isOn: .constant(true))
            }
            .disabled(!settings.correctionEnabled)
        }
        .formStyle(.grouped)
        .padding()
    }

    private func providerKeyLabel(for providerId: String) -> String {
        switch providerId {
        case "claude":
            return "Claude API Key"
        case "doubao":
            return "Doubao API Key"
        case "qwen":
            return "Qwen API Key"
        default:
            return "OpenAI API Key"
        }
    }

    private func applyQuickMode(_ mode: AutoEditQuickMode) {
        switch mode {
        case .balanced:
            settings.correctionHomophonesEnabled = true
            settings.correctionPunctuationEnabled = true
            settings.correctionFormattingEnabled = true
        case .homophonesOnly:
            settings.correctionHomophonesEnabled = true
            settings.correctionPunctuationEnabled = false
            settings.correctionFormattingEnabled = false
        case .punctuationOnly:
            settings.correctionHomophonesEnabled = false
            settings.correctionPunctuationEnabled = true
            settings.correctionFormattingEnabled = false
        case .formattingOnly:
            settings.correctionHomophonesEnabled = false
            settings.correctionPunctuationEnabled = false
            settings.correctionFormattingEnabled = true
        }
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

// MARK: - Permissions Settings Tab

struct PermissionsSettingsTab: View {
    @EnvironmentObject var permissionManager: PermissionManager

    var body: some View {
        Form {
            Section("Required Permissions") {
                PermissionStatusRow(
                    title: "Accessibility",
                    description: "Required for text insertion into other apps",
                    isGranted: permissionManager.accessibilityGranted,
                    onRequest: { permissionManager.requestAccessibilityPermission() }
                )

                PermissionStatusRow(
                    title: "Input Monitoring",
                    description: "Required to detect global hotkeys",
                    isGranted: permissionManager.inputMonitoringGranted,
                    onRequest: { permissionManager.requestInputMonitoringPermission() }
                )

                PermissionStatusRow(
                    title: "Microphone",
                    description: "Required for voice recording",
                    isGranted: permissionManager.microphoneGranted,
                    onRequest: {
                        Task { _ = await permissionManager.requestMicrophonePermission() }
                    }
                )
            }

            Section {
                Button("Refresh Permission Status") {
                    permissionManager.checkAllPermissions()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PermissionStatusRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}

struct ProviderKeyRow: View {
    let label: String
    let providerId: String

    @State private var storedKey: String?
    @State private var apiKey: String = ""

    private let keyStore = SecureKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                if let storedKey, !storedKey.isEmpty {
                    Text(maskedKey(storedKey))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Replace") {
                        apiKey = ""
                        self.storedKey = nil
                    }
                    .font(.caption)

                    Button("Remove") {
                        removeKey()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                } else {
                    SecureField("Enter API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        saveKey()
                    }
                    .font(.caption)
                    .disabled(apiKey.isEmpty)
                }
            }
        }
        .onAppear(perform: loadKey)
        .onChange(of: providerId) { _, _ in loadKey() }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    private func loadKey() {
        apiKey = ""
        let key = try? keyStore.retrieve(for: providerId)
        if let key, !key.isEmpty {
            storedKey = key
        } else {
            storedKey = nil
        }
    }

    private func saveKey() {
        guard !apiKey.isEmpty else { return }
        try? keyStore.store(key: apiKey, for: providerId)
        storedKey = apiKey
        apiKey = ""
    }

    private func removeKey() {
        try? keyStore.delete(for: providerId)
        storedKey = nil
        apiKey = ""
    }
}

// MARK: - About Settings Tab

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Echo")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Hold a key, speak, and your words appear as text.\nPowered by AI for natural, polished output.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Divider()
                .padding(.vertical)

            VStack(spacing: 8) {
                Link("Visit Website", destination: URL(string: "https://github.com/guixiang123124/Echo")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/guixiang123124/Echo/issues")!)
            }

            Spacer()

            Text("© 2024 Echo. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsWindowView()
        .environmentObject(AppState())
        .environmentObject(PermissionManager())
        .environmentObject(MacAppSettings())
}

// MARK: - Auth Sheet

struct AuthSheetView: View {
    @EnvironmentObject var authSession: EchoAuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AuthMode = .email
    @State private var email = ""
    @State private var password = ""
    @State private var currentNonce: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sign in to Echo")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Picker("", selection: $mode) {
                Text("Email").tag(AuthMode.email)
                Text("Phone").tag(AuthMode.phone)
            }
            .pickerStyle(.segmented)

            switch mode {
            case .email:
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        Button("Sign In") {
                            Task { await authSession.signIn(email: email, password: password) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Create Account") {
                            Task { await authSession.signUp(email: email, password: password) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            case .phone:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Phone sign-in is available on iOS.")
                        .foregroundStyle(.secondary)
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
            .frame(height: 36)

            if authSession.isLoading {
                ProgressView()
            }

            if let error = authSession.errorMessage, !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if authSession.isSignedIn {
                Divider()
                HStack {
                    Text("Signed in as \(authSession.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign Out") {
                        authSession.signOut()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private enum AuthMode: String, CaseIterable, Identifiable {
    case email
    case phone

    var id: String { rawValue }
}
