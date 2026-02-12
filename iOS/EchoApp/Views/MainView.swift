import SwiftUI
import EchoCore

struct MainView: View {
    private enum Tab: Int {
        case home = 0
        case history = 1
        case dictionary = 2
        case account = 3
    }

    fileprivate enum DeepLink {
        case voice
        case settings
    }

    @State private var selectedTab: Tab = .home
    @State private var deepLink: DeepLink?
    @EnvironmentObject var authSession: EchoAuthSession

    var body: some View {
        TabView(selection: $selectedTab) {
            EchoHomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(Tab.home)

            EchoHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
                .tag(Tab.history)

            EchoDictionaryView()
                .tabItem {
                    Label("Dictionary", systemImage: "book.closed")
                }
                .tag(Tab.dictionary)

            EchoAccountView()
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .tag(Tab.account)
        }
        .tint(.primary)
        .onReceive(authSession.$user) { user in
            CloudSyncService.shared.updateAuthState(user: user)
            BillingService.shared.updateAuthState(user: user)
            Task { await BillingService.shared.refresh() }
        }
        .onOpenURL { url in
            guard url.scheme == "echo", let host = url.host else { return }
            switch host {
            case "voice":
                deepLink = .voice
            case "settings":
                deepLink = .settings
            default:
                break
            }
        }
        .sheet(item: $deepLink) { link in
            switch link {
            case .voice:
                VoiceRecordingView(startForKeyboard: true)
            case .settings:
                SettingsView()
            }
        }
    }
}

extension MainView.DeepLink: Identifiable {
    var id: String {
        switch self {
        case .voice: return "voice"
        case .settings: return "settings"
        }
    }
}

enum EchoMobileTheme {
    static let pageBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemBackground)
    static let cardSurface = Color(.systemBackground)
    static let border = Color.black.opacity(0.06)
    static let mutedText = Color(.secondaryLabel)
    static let accent = Color(red: 0.11, green: 0.53, blue: 0.98)
    static let accentSoft = Color(red: 0.87, green: 0.94, blue: 1.0)

    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.94, green: 0.97, blue: 1.0),
            Color(red: 0.92, green: 0.93, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct EchoCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(EchoMobileTheme.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(EchoMobileTheme.border, lineWidth: 1)
            )
    }
}

struct EchoSectionHeading: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(EchoMobileTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EchoStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
