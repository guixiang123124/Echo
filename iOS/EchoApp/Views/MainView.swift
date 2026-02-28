import SwiftUI
import EchoCore
import UIKit

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
   @State private var isHandlingKeyboardVoiceIntent = false
   @EnvironmentObject var authSession: EchoAuthSession
   @EnvironmentObject var backgroundDictation: BackgroundDictationService
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
       .onReceive(authSession.$user) { user in
           CloudSyncService.shared.updateAuthState(user: user)
           BillingService.shared.updateAuthState(user: user)
           Task { await BillingService.shared.refresh() }
       }
    .onOpenURL { url in
           print("[EchoApp] onOpenURL received: \(url.absoluteString)")
           guard url.scheme == "echo" || url.scheme == "echoapp" else {
               print("[EchoApp] onOpenURL ignored due unsupported scheme: \(url.scheme ?? "<none>")")
               return
           }
           let route = (url.host?.isEmpty == false ? url.host : nil)
               ?? url.pathComponents.dropFirst().first
               .map { $0.lowercased() }
           guard let route else { return }
           print("[EchoApp] onOpenURL parsed route: \(route)")
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
               print("[EchoApp] onOpenURL unsupported route: \(route)")
               break
           }
       }
       .onAppear {
           consumeKeyboardLaunchIntentIfNeeded()
       }
       .onReceive(keyboardIntentPoll) { _ in
           consumeKeyboardLaunchIntentIfNeeded()
       }
       .onChange(of: scenePhase) { _, newValue in
           guard newValue == .active else { return }
           consumeKeyboardLaunchIntentIfNeeded()
       }
       .overlay(alignment: .top) {
           BackgroundDictationOverlay(service: backgroundDictation)
       }
       .sheet(item: $deepLink) { link in
           switch link {
           case .settings:
               SettingsView()
           }
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
    func handleVoiceDeepLink() {
        guard !isHandlingKeyboardVoiceIntent else {
            print("[EchoApp] handleVoiceDeepLink skipped: already handling")
            return
        }

        isHandlingKeyboardVoiceIntent = true
        let bridge = AppGroupBridge()
        bridge.markLaunchAcknowledged()

        Task {
            defer {
                Task { @MainActor in
                    isHandlingKeyboardVoiceIntent = false
                }
            }

            await MainActor.run {
                backgroundDictation.activate(authSession: authSession)
            }

            await backgroundDictation.startDictationForKeyboardIntent()
            var started = await waitForRecordingState(timeout: 0.8)

            if !started {
                try? await Task.sleep(nanoseconds: 150_000_000)
                started = await waitForRecordingState(timeout: 0.5)
            }

            let shouldReturn: Bool = await MainActor.run {
                switch backgroundDictation.state {
                case .recording, .transcribing, .finalizing:
                    return true
                case .error, .idle:
                    return false
                }
            }

            await MainActor.run {
                if started || shouldReturn {
                    bridge.clearPendingLaunchIntent()
                    autoReturnToHostAppIfNeeded()
                    return
                }

                if case .error = backgroundDictation.state {
                    print("[EchoApp] handleVoiceDeepLink: dictation entered error state, keeping app foreground")
                    bridge.clearPendingLaunchIntent()
                } else {
                    print("[EchoApp] handleVoiceDeepLink: dictation not started yet; keeping pending intent for retry")
                }
            }
        }
    }

    func waitForRecordingState(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .recording = backgroundDictation.state {
                return true
            }
            if case .transcribing = backgroundDictation.state {
                return true
            }
            if case .finalizing = backgroundDictation.state {
                return true
            }
            if case .error = backgroundDictation.state {
                return false
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return false
    }

    func consumeKeyboardLaunchIntentIfNeeded() {
       let bridge = AppGroupBridge()
       guard let intent = bridge.consumePendingLaunchIntent(maxAge: 30) else {
           print("[EchoApp] consumeKeyboardLaunchIntentIfNeeded: no pending intent")
           return
       }
       print("[EchoApp] consumeKeyboardLaunchIntentIfNeeded intent: \(intent)")
       switch intent {
       case .voice, .voiceControl:
           handleVoiceDeepLink()
        case .settings:
            deepLink = .settings
            bridge.markLaunchAcknowledged()
        }
    }

    func autoReturnToHostAppIfNeeded() {
        guard backgroundDictation.state.canReturnToKeyboard else {
            return
        }
        let selector = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: selector) else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            UIApplication.shared.perform(selector)
        }
    }
}

private extension BackgroundDictationService.SessionState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var canReturnToKeyboard: Bool {
        switch self {
        case .error:
            return false
        default:
            return true
        }
    }
}

enum EchoMobileTheme {
   static let pageBackground = Color(.systemGroupedBackground)
   static let cardBackground = Color(.secondarySystemBackground)
   static let cardSurface = Color(.systemBackground)
   static let border = Color(.separator).opacity(0.3)
   static let mutedText = Color(.secondaryLabel)
   static let accent = Color(red: 0.11, green: 0.53, blue: 0.98)

   static let accentSoft = Color(
       UIColor { traits in
           traits.userInterfaceStyle == .dark
               ? UIColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 1.0)
               : UIColor(red: 0.87, green: 0.94, blue: 1.0, alpha: 1.0)
       }
   )

   static let heroGradientStart = Color(
       UIColor { traits in
           traits.userInterfaceStyle == .dark
               ? UIColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1.0)
               : UIColor(red: 0.94, green: 0.97, blue: 1.0, alpha: 1.0)
       }
   )

   static let heroGradientEnd = Color(
       UIColor { traits in
           traits.userInterfaceStyle == .dark
               ? UIColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1.0)
               : UIColor(red: 0.92, green: 0.93, blue: 1.0, alpha: 1.0)
       }
   )

   static let heroGradient = LinearGradient(
       colors: [heroGradientStart, heroGradientEnd],
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
