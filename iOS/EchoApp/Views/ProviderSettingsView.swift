import SwiftUI
import EchoCore

struct ProviderSettingsView: View {
    @State private var apiKeys: [String: String] = [:]
    private let keyStore = SecureKeyStore()

    private var allProviders: [ProviderConfig] {
        AvailableProviders.asrProviders.filter(\.requiresApiKey)
            + AvailableProviders.correctionProviders.filter(\.requiresApiKey)
    }

    private var extraKeyIds: [String] {
        [
            "volcano_app_id",
            "volcano_access_key"
        ]
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API keys are stored securely in your device's Keychain.")
                    Text("Tip: You can reuse the same OpenAI API key for Whisper (ASR) and Auto Edit (GPT-4o).")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section("Speech Recognition Providers") {
                ForEach(AvailableProviders.asrProviders.filter(\.requiresApiKey)) { provider in
                    if provider.id == "volcano" {
                        keyPairRow(
                            title: provider.displayName,
                            firstLabel: "App ID",
                            firstKeyId: "volcano_app_id",
                            secondLabel: "Access Key",
                            secondKeyId: "volcano_access_key"
                        )
                    } else {
                        apiKeyRow(for: provider)
                    }
                }
            }

            Section("Auto Edit Providers") {
                ForEach(AvailableProviders.correctionProviders.filter(\.requiresApiKey)) { provider in
                    apiKeyRow(for: provider)
                }
            }
        }
        .navigationTitle("API Keys")
        .onAppear(perform: loadKeys)
    }

    private func apiKeyRow(for provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.displayName)
                .font(.body)

            HStack {
                if let key = apiKeys[provider.id], !key.isEmpty {
                    Text(maskedKey(key))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Remove") {
                        removeKey(for: provider.id)
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                } else {
                    SecureField("Enter API Key", text: binding(for: provider.id))
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        saveKey(for: provider.id)
                    }
                    .font(.caption)
                    .disabled((apiKeys[provider.id] ?? "").isEmpty)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func binding(for providerId: String) -> Binding<String> {
        Binding(
            get: { apiKeys[providerId] ?? "" },
            set: { apiKeys[providerId] = $0 }
        )
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    private func loadKeys() {
        for provider in allProviders {
            if keyStore.hasKey(for: provider.id) {
                apiKeys[provider.id] = (try? keyStore.retrieve(for: provider.id)) ?? ""
            }
        }
        for keyId in extraKeyIds {
            if keyStore.hasKey(for: keyId) {
                apiKeys[keyId] = (try? keyStore.retrieve(for: keyId)) ?? ""
            }
        }
    }

    private func saveKey(for providerId: String) {
        guard let key = apiKeys[providerId], !key.isEmpty else { return }
        try? keyStore.store(key: key, for: providerId)
    }

    private func removeKey(for providerId: String) {
        try? keyStore.delete(for: providerId)
        apiKeys[providerId] = nil
    }

    private func keyPairRow(
        title: String,
        firstLabel: String,
        firstKeyId: String,
        secondLabel: String,
        secondKeyId: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body)

            HStack {
                Text(firstLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("Enter \(firstLabel)", text: binding(for: firstKeyId))
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    saveKey(for: firstKeyId)
                }
                .font(.caption)
                .disabled((apiKeys[firstKeyId] ?? "").isEmpty)
            }

            HStack {
                Text(secondLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("Enter \(secondLabel)", text: binding(for: secondKeyId))
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    saveKey(for: secondKeyId)
                }
                .font(.caption)
                .disabled((apiKeys[secondKeyId] ?? "").isEmpty)
            }
        }
        .padding(.vertical, 4)
    }
}
