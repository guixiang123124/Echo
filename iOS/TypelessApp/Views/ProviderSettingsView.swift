import SwiftUI
import TypelessCore

struct ProviderSettingsView: View {
    @State private var apiKeys: [String: String] = [:]
    private let keyStore = SecureKeyStore()

    private var allProviders: [ProviderConfig] {
        AvailableProviders.asrProviders.filter(\.requiresApiKey)
            + AvailableProviders.correctionProviders.filter(\.requiresApiKey)
    }

    var body: some View {
        List {
            Section {
                Text("API keys are stored securely in your device's Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Speech Recognition Providers") {
                ForEach(AvailableProviders.asrProviders.filter(\.requiresApiKey)) { provider in
                    apiKeyRow(for: provider)
                }
            }

            Section("AI Correction Providers") {
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
                    TextField("Enter API Key", text: binding(for: provider.id))
                        .font(.caption)
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
    }

    private func saveKey(for providerId: String) {
        guard let key = apiKeys[providerId], !key.isEmpty else { return }
        try? keyStore.store(key: key, for: providerId)
    }

    private func removeKey(for providerId: String) {
        try? keyStore.delete(for: providerId)
        apiKeys[providerId] = nil
    }
}
