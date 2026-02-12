import SwiftUI
import EchoCore
import UserNotifications

struct EchoAccountView: View {
    @EnvironmentObject private var authSession: EchoAuthSession
    @StateObject private var billing = BillingService.shared
    @State private var showAuthSheet = false
    @State private var notificationsStatus: NotificationStatus = .unknown

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EchoSectionHeading("Account")
                    notificationsCard
                    syncCard
                    billingCard
                    accountCard
                    supportCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.automatic)
            .background(EchoMobileTheme.pageBackground)
        }
        .task {
            await refreshNotificationStatus()
            await billing.refresh()
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthSheetView()
                .environmentObject(authSession)
        }
    }

    private var notificationsCard: some View {
        EchoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    EchoStatusDot(color: notificationsStatus == .enabled ? .green : .red)
                    Text("Notifications: \(notificationsStatus == .enabled ? "On" : "Off")")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Turn on notifications to get useful tips and be the first to know about new features.")
                    .font(.system(size: 14))
                    .foregroundStyle(EchoMobileTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await requestNotifications() }
                } label: {
                    Text("Turn on Notifications")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(EchoMobileTheme.cardBackground)
                        )
                }
                .buttonStyle(.plain)
                .disabled(notificationsStatus == .enabled)
            }
        }
    }

    private var syncCard: some View {
        EchoCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "icloud")
                        .foregroundStyle(EchoMobileTheme.mutedText)
                        .frame(width: 20)
                    Text("Cloud sync")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(authSession.isSignedIn ? "On" : "Off")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(authSession.isSignedIn ? .green : EchoMobileTheme.mutedText)
                }

                Text(authSession.isSignedIn ? "Signed in as \(authSession.displayName)." : "Sign in to sync history across devices.")
                    .font(.system(size: 13))
                    .foregroundStyle(EchoMobileTheme.mutedText)
            }
        }
    }

    private var accountCard: some View {
        EchoCard {
            VStack(spacing: 0) {
                Button {
                    showAuthSheet = true
                } label: {
                    rowLabel(
                        icon: "person.crop.circle",
                        title: authSession.isSignedIn ? authSession.displayName : "Sign in",
                        trailing: true
                    )
                }
                .buttonStyle(.plain)

                Divider()

                NavigationLink {
                    SettingsView()
                } label: {
                    rowLabel(icon: "gearshape", title: "Settings", trailing: true)
                }

                Divider()

                NavigationLink {
                    EchoAboutView()
                } label: {
                    rowLabel(icon: "info.circle", title: "About", trailing: true)
                }

                if authSession.isSignedIn {
                    Divider()
                    Button(role: .destructive) {
                        authSession.signOut()
                    } label: {
                        rowLabel(
                            icon: "rectangle.portrait.and.arrow.right",
                            title: "Sign Out",
                            trailing: false,
                            titleColor: .red
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var billingCard: some View {
        EchoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(EchoMobileTheme.mutedText)
                        .frame(width: 20)
                    Text("Subscription")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(billingTierText)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(billing.snapshot?.hasActiveSubscription == true ? .green : EchoMobileTheme.mutedText)
                }

                Text(billingStatusText)
                    .font(.system(size: 13))
                    .foregroundStyle(EchoMobileTheme.mutedText)

                Button {
                    Task { await billing.refresh() }
                } label: {
                    Text("Refresh Plan Status")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(EchoMobileTheme.cardBackground)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!authSession.isSignedIn)
            }
        }
    }

    private var supportCard: some View {
        EchoCard {
            VStack(spacing: 0) {
                Link(destination: URL(string: "https://github.com/guixiang123124/Echo")!) {
                    rowLabel(icon: "book", title: "Help center", trailingExternal: true)
                }

                Divider()

                Link(destination: URL(string: "https://github.com/guixiang123124/Echo/releases")!) {
                    rowLabel(icon: "square.and.pencil", title: "Release notes", trailingExternal: true)
                }
            }
        }
    }

    private func rowLabel(
        icon: String,
        title: String,
        trailing: Bool = false,
        trailingExternal: Bool = false,
        titleColor: Color = .primary
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(EchoMobileTheme.mutedText)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(titleColor)
            Spacer()
            if trailing {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 13, weight: .semibold))
            }
            if trailingExternal {
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
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

    private var billingTierText: String {
        billing.snapshot?.tier.uppercased() ?? "FREE"
    }

    private var billingStatusText: String {
        switch billing.status {
        case .idle:
            return "Plan status is ready."
        case .disabled(let reason):
            return reason
        case .loading:
            return "Loading subscription status..."
        case .loaded(let date):
            return "Last updated \(date.formatted(date: .omitted, time: .shortened))"
        case .error(let message):
            return message
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
