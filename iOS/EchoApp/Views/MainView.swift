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
        case settings
    }

    @State private var selectedTab: Tab = .home
    @State private var deepLink: DeepLink?
    @StateObject private var backgroundDictation = BackgroundDictationService()
    @EnvironmentObject var authSession: EchoAuthSession
    @Environment(\.scenePhase) private var scenePhase
    private let keyboardIntentPoll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

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
        .overlay(alignment: .top) {
            if !backgroundDictation.state.isIdle {
                BackgroundDictationOverlay(service: backgroundDictation)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(authSession.$user) { user in
            CloudSyncService.shared.updateAuthState(user: user)
            BillingService.shared.updateAuthState(user: user)
            Task { await BillingService.shared.refresh() }
        }
        .onOpenURL { url in
            guard url.scheme == "echo" || url.scheme == "echoapp" else { return }
            let route = (url.host?.isEmpty == false ? url.host : nil)
                ?? url.pathComponents.dropFirst().first
                .map { $0.lowercased() }
            guard let route else { return }

            switch route {
            case "home":
                selectedTab = .home
                deepLink = nil
            case "history":
                selectedTab = .history
                deepLink = nil
            case "dictionary":
                selectedTab = .dictionary
                deepLink = nil
            case "account":
                selectedTab = .account
                deepLink = nil
            case "voice":
                handleVoiceDeepLink()
            case "settings":
                deepLink = .settings
                AppGroupBridge().markLaunchAcknowledged()
                AppGroupBridge().clearPendingLaunchIntent()
            default:
                break
            }
        }
        .onAppear {
            backgroundDictation.activate(authSession: authSession)
            consumeKeyboardLaunchIntentIfNeeded()
        }
        .onReceive(keyboardIntentPoll) { _ in
            consumeKeyboardLaunchIntentIfNeeded()
        }
        .onChange(of: scenePhase) { _, newValue in
            switch newValue {
            case .active:
                consumeKeyboardLaunchIntentIfNeeded()
            case .background:
                backgroundDictation.deactivate()
            default:
                break
            }
        }
        .sheet(item: $deepLink) { link in
            switch link {
            case .settings:
                SettingsView()
            }
        }
    }

    // MARK: - Voice Deep Link

    /// Handle voice deep link: activate background dictation and auto-return.
    /// No longer opens a VoiceRecordingView sheet.
    private func handleVoiceDeepLink() {
        let bridge = AppGroupBridge()
        bridge.markLaunchAcknowledged()
        bridge.clearPendingLaunchIntent()

        if backgroundDictation.state.isIdle {
            // Engine will start recording when it receives the Darwin notification.
            // Activate if not already active.
            backgroundDictation.activate(authSession: authSession)
        }

        // Auto-return to the previous app after a brief delay
        autoReturn()
    }

    /// Suspend the app to return to the previous app (keyboard host).
    private func autoReturn() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIApplication.shared.perform(Selector(("suspend")))
        }
    }
}

extension MainView.DeepLink: Identifiable {
    var id: String {
        switch self {
        case .settings: return "settings"
        }
    }
}

private extension MainView {
    func consumeKeyboardLaunchIntentIfNeeded() {
        let bridge = AppGroupBridge()
        guard let intent = bridge.consumePendingLaunchIntent(maxAge: 45) else {
            return
        }
        switch intent {
        case .voice, .voiceControl:
            // Activate background dictation instead of opening sheet
            handleVoiceDeepLink()
        case .settings:
            deepLink = .settings
            bridge.markLaunchAcknowledged()
        }
    }
}

// MARK: - SessionState Helper

extension BackgroundDictationService.SessionState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
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
