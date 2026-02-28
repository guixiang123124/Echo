import SwiftUI
import UIKit
import EchoCore

@main
struct EchoApp: App {
    @UIApplicationDelegateAdaptor(AppURLBridge.self) private var appDelegate
    @StateObject private var authSession = EchoAuthSession.shared

    init() {
        let settings = AppSettings()
        EchoAuthSession.shared.configureBackend(baseURL: settings.cloudSyncBaseURL)
        EchoAuthSession.shared.start()
        CloudSyncService.shared.configure(
            baseURLString: settings.cloudSyncBaseURL,
            uploadAudio: settings.cloudUploadAudioEnabled
        )
        CloudSyncService.shared.setEnabled(settings.cloudSyncEnabled)
        CloudSyncService.shared.updateAuthState(user: EchoAuthSession.shared.user)
        BillingService.shared.configure(baseURLString: settings.cloudSyncBaseURL)
        BillingService.shared.setEnabled(settings.cloudSyncEnabled)
        BillingService.shared.updateAuthState(user: EchoAuthSession.shared.user)
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(authSession)
        }
    }
}

private final class AppURLBridge: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let intent = url.keyboardLaunchIntent else {
            return false
        }

        let bridge = AppGroupBridge()
        bridge.setPendingLaunchIntent(intent)
        bridge.markLaunchAcknowledged()

        // For voice intents, auto-return to the calling app after acknowledging
        if intent == .voice || intent == .voiceControl {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                application.perform(Selector(("suspend")))
            }
        }

        return true
    }
}

private extension URL {
    var keyboardLaunchIntent: AppGroupBridge.LaunchIntent? {
        guard let scheme = scheme,
              scheme == "echo" || scheme == "echoapp" else {
            return nil
        }

        let route = (host?.isEmpty == false ? host : pathComponents.dropFirst().first)?.lowercased()
        switch route {
        case "voice":
            return .voice
        case "settings":
            return .settings
        default:
            return nil
        }
    }
}
