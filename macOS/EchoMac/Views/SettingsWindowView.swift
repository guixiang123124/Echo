import SwiftUI
import EchoCore

/// Main settings window view with tab navigation
struct SettingsWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var settings: MacAppSettings

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .environmentObject(settings)
                .environmentObject(permissionManager)

            ASRSettingsTab()
                .tabItem {
                    Label("Speech", systemImage: "waveform")
                }
                .environmentObject(settings)

            CorrectionSettingsTab()
                .tabItem {
                    Label("AI Editing", systemImage: "sparkles")
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

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Activation Key", selection: $settings.hotkeyType) {
                    ForEach(MacAppSettings.HotkeyType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                Text("Press once to start recording, press again to transcribe")
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - ASR Settings Tab

struct ASRSettingsTab: View {
    @EnvironmentObject var settings: MacAppSettings

    var body: some View {
        Form {
            Section("Speech Recognition") {
                HStack {
                    Text("Provider")
                    Spacer()
                    Text("OpenAI Whisper")
                        .foregroundColor(.secondary)
                }

                ProviderKeyRow(
                    label: "OpenAI API Key",
                    providerId: "openai_whisper"
                )
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
            Section("AI Editing") {
                Toggle("Enable AI Text Editing", isOn: $settings.correctionEnabled)

                if settings.correctionEnabled {
                    Picker("AI Provider", selection: $settings.selectedCorrectionProvider) {
                        Text("OpenAI GPT-4o").tag("openai_gpt")
                        Text("Claude").tag("claude")
                        Text("豆包").tag("doubao")
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
        default:
            return "OpenAI API Key"
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
