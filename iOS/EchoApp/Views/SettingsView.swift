import SwiftUI
import EchoCore

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var selectedASR: String = ""
    @State private var correctionEnabled = true
    @State private var correctionHomophonesEnabled = true
    @State private var correctionPunctuationEnabled = true
    @State private var correctionFormattingEnabled = true
    @State private var autoEditQuickMode: AutoEditQuickMode = .balanced
    @State private var selectedCorrection: String = ""
    @State private var hapticEnabled = true

    var body: some View {
        NavigationStack {
            List {
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
            }
            .onChange(of: selectedASR) { _, newValue in
                settings.selectedASRProvider = newValue
            }
            .onChange(of: selectedCorrection) { _, newValue in
                settings.selectedCorrectionProvider = newValue
            }
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
                    setupStep(number: 5, text: "Tap 'Echo' and enable 'Allow Full Access'")
                    setupStep(number: 6, text: "Switch to Echo using the globe key")
                }
                .padding(.vertical, 8)
            } header: {
                Text("Setup Steps")
            } footer: {
                Text("Full Access is required for voice input and cloud-based speech recognition.")
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
