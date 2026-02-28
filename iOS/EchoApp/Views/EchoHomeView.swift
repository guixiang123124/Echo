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
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    actionRow
                    setupCard
                    statusCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Echo")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSetupGuide = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("More options")
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
            .background(EchoMobileTheme.pageBackground)
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
        EchoCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(EchoMobileTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(EchoMobileTheme.accentSoft)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set up Echo Keyboard")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("It will be one tap away in all your apps.")
                            .font(.system(size: 14))
                            .foregroundStyle(EchoMobileTheme.mutedText)
                    }
                    Spacer()
                }

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(EchoMobileTheme.heroGradient)
                    .overlay(
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Hold space to dictate", systemImage: "waveform")
                            Label("Release to transcribe", systemImage: "sparkles")
                            Label("Auto insert into text fields", systemImage: "text.cursor")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(12),
                        alignment: .leading
                    )
                    .frame(height: 132)

                Button {
                    openAppSettings()
                } label: {
                    Text("Add Echo Keyboard")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(.label))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                showVoiceTest = true
            } label: {
                Label("Try Voice", systemImage: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.label))
                    )
            }
            .buttonStyle(.plain)

            Button {
                openAppSettings()
            } label: {
                Label("Add Keyboard", systemImage: "keyboard")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(EchoMobileTheme.cardBackground)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var setupCard: some View {
        EchoCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard setup")
                    .font(.system(size: 18, weight: .semibold))
                Text("Echo works best as your system keyboard. Add it once, then switch with the globe key.")
                    .font(.system(size: 14))
                    .foregroundStyle(EchoMobileTheme.mutedText)

                VStack(alignment: .leading, spacing: 8) {
                    setupStep(1, "Open Settings")
                    setupStep(2, "General > Keyboard > Keyboards")
                    setupStep(3, "Add New Keyboard... > Echo")
                    setupStep(4, "(Recommended) Enable Allow Full Access for Voice + AI")
                }
                .padding(.top, 2)

                Button {
                    showSetupGuide = true
                } label: {
                    Text("Having trouble?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(EchoMobileTheme.mutedText)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func setupStep(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(EchoMobileTheme.accent))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
        }
    }

    private var statusCard: some View {
        EchoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Database & Sync")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    EchoStatusDot(color: syncColor)
                }

                statusRow("Local history", icon: "internaldrive", value: localStatusText)
                statusRow("Cloud sync", icon: "icloud", value: syncStatusText)

                if authSession.isSignedIn {
                    statusRow("Signed in", icon: "person.crop.circle", value: authSession.displayName)
                } else {
                    Text("Sign in on the Account tab to sync history across devices.")
                        .font(.system(size: 13))
                        .foregroundStyle(EchoMobileTheme.mutedText)
                }

                if !settings.cloudSyncEnabled {
                    Text("Cloud sync is disabled in Settings.")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func statusRow(_ title: String, icon: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 14))
                .foregroundStyle(EchoMobileTheme.mutedText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
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

    private var syncColor: Color {
        switch cloudSync.status {
        case .error:
            return .red
        case .disabled:
            return .gray
        case .syncing:
            return .blue
        case .synced:
            return .green
        case .idle:
            return .gray
        }
    }

    private func openAppSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
