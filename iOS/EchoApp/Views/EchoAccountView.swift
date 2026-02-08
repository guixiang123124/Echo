import SwiftUI
import EchoCore
import UserNotifications

struct EchoAccountView: View {
    @EnvironmentObject private var authSession: EchoAuthSession
    @State private var showAuthSheet = false
    @State private var notificationsStatus: NotificationStatus = .unknown

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    notificationsCard
                    accountCard
                    supportCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await refreshNotificationStatus() }
        .sheet(isPresented: $showAuthSheet) {
            AuthSheetView()
                .environmentObject(authSession)
        }
    }

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(notificationsStatus == .enabled ? Color(.systemGreen) : Color(.systemRed))
                    .frame(width: 10, height: 10)
                Text("Notifications: \(notificationsStatus == .enabled ? "On" : "Off")")
                    .font(.headline)
            }

            Text("Turn on notifications to get useful tips and be the first to know about new features.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await requestNotifications() }
            } label: {
                Text("Turn on Notifications")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
            }
            .buttonStyle(.plain)
            .disabled(notificationsStatus == .enabled)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var accountCard: some View {
        VStack(spacing: 0) {
            Button {
                showAuthSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(authSession.isSignedIn ? authSession.displayName : "Sign in")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)

            Divider()

            NavigationLink {
                SettingsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Settings")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }

            Divider()

            NavigationLink {
                EchoAboutView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("About")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }

            if authSession.isSignedIn {
                Divider()
                Button(role: .destructive) {
                    authSession.signOut()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .frame(width: 24)
                        Text("Sign Out")
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var supportCard: some View {
        VStack(spacing: 0) {
            Link(destination: URL(string: "https://github.com/guixiang123124/Echo")!) {
                HStack(spacing: 12) {
                    Image(systemName: "book")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Help center")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }

            Divider()

            Link(destination: URL(string: "https://github.com/guixiang123124/Echo/releases")!) {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Release notes")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Notifications

    private enum NotificationStatus: Equatable {
        case unknown
        case enabled
        case disabled
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsStatus = .enabled
        case .denied, .notDetermined:
            notificationsStatus = .disabled
        @unknown default:
            notificationsStatus = .unknown
        }
    }

    private func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            notificationsStatus = granted ? .enabled : .disabled
        } catch {
            notificationsStatus = .disabled
        }
    }
}

private struct EchoAboutView: View {
    var body: some View {
        List {
            Section("Echo") {
                Text("Voice-first typing, polished with AI.")
            }
            Section("Version") {
                HStack {
                    Text("App")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About")
    }
}

