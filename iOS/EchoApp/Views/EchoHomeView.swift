import SwiftUI
import EchoCore

struct EchoHomeView: View {
    @EnvironmentObject private var authSession: EchoAuthSession
    @StateObject private var cloudSync = CloudSyncService.shared

    @State private var storageInfo: RecordingStore.StorageInfo?
    @State private var showSetupGuide = false
    @State private var showVoiceTest = false

    private let settings = AppSettings()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    actionRow
                    setupCard
                    statusCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSetupGuide = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }
            .sheet(isPresented: $showSetupGuide) {
                NavigationStack {
                    KeyboardSetupGuide()
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("Done") { showSetupGuide = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showVoiceTest) {
                VoiceRecordingView(startForKeyboard: false)
            }
        }
        .task {
            storageInfo = await RecordingStore.shared.storageInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .echoRecordingSaved)) { _ in
            Task {
                storageInfo = await RecordingStore.shared.storageInfo()
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice-first typing")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Hold space on the Echo keyboard to dictate. Release to insert.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.54, blue: 0.95),
                            Color(red: 0.52, green: 0.35, blue: 0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                showVoiceTest = true
            } label: {
                Label("Try Voice", systemImage: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black)
                    )
            }
            .buttonStyle(.plain)

            Button {
                openAppSettings()
            } label: {
                Label("Enable Keyboard", systemImage: "keyboard")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard setup")
                .font(.headline)
            Text("Echo works best as your system keyboard. Add it once, then switch with the globe key.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                setupStep(1, "Open Settings")
                setupStep(2, "General > Keyboard > Keyboards")
                setupStep(3, "Add New Keyboard... > Echo")
                setupStep(4, "Enable Allow Full Access")
            }
            .padding(.top, 4)

            Button {
                openAppSettings()
            } label: {
                Text("Add Echo Keyboard")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black)
                    )
            }
            .buttonStyle(.plain)

            Button {
                showSetupGuide = true
            } label: {
                Text("Having trouble?")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func setupStep(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color(.systemBlue)))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Database & Sync")
                    .font(.headline)
                Spacer()
            }

            HStack {
                Label("Local history", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(localStatusText)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Cloud sync", systemImage: "icloud")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(syncStatusText)
                    .foregroundStyle(.secondary)
            }

            if authSession.isSignedIn {
                HStack {
                    Label("Signed in", systemImage: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(authSession.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Sign in on the Account tab to sync history across devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !settings.cloudSyncEnabled {
                Text("Cloud sync is disabled in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var localStatusText: String {
        guard let info = storageInfo else { return "Loading…" }
        return "\(info.entryCount) items · \(info.retentionPolicy)"
    }

    private var syncStatusText: String {
        switch cloudSync.status {
        case .idle:
            return "Idle"
        case .disabled(let reason):
            return reason
        case .syncing:
            return "Syncing…"
        case .synced(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private func openAppSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
