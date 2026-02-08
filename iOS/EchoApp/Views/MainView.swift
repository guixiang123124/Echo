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
                    Label("History", systemImage: "clock")
                }
                .tag(Tab.history)

            EchoDictionaryView()
                .tabItem {
                    Label("Dictionary", systemImage: "book")
                }
                .tag(Tab.dictionary)

            EchoAccountView()
                .tabItem {
                    Label("Account", systemImage: "person")
                }
                .tag(Tab.account)
        }
        .onReceive(authSession.$user) { user in
            CloudSyncService.shared.updateAuthState(user: user)
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
