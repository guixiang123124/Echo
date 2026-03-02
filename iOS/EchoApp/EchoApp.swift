import SwiftUI
import UIKit
import EchoCore

@main
struct EchoApp: App {
   @UIApplicationDelegateAdaptor(AppURLBridge.self) private var appDelegate
   @StateObject private var authSession = EchoAuthSession.shared
   @StateObject private var backgroundDictation = BackgroundDictationService()

   init() {
       EmbeddedKeyProvider.shared.seedKeychainIfNeeded()
       let settings = AppSettings()
       settings.normalizeOpenAIModel()
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
               .environmentObject(backgroundDictation)
               .onAppear {
                   backgroundDictation.activate(authSession: authSession)
               }
       }
   }
}

private final class AppURLBridge: NSObject, UIApplicationDelegate {
   func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
       print("[EchoApp] application(_:open:options:) received \(url.absoluteString)")

       guard let intent = url.keyboardLaunchIntent else {
           return false
       }

       print("[EchoApp] application open URL parsed intent: \(intent.rawValue)")
       let bridge = AppGroupBridge()

       let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
       let sourceAppFromURL = queryItems?.first(where: { $0.name == "hostBundle" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
       let hostPIDFromURL = queryItems?.first(where: { $0.name == "hostPID" })?.value.flatMap { Int32($0) }

       func isValidHostBundle(_ bundleID: String?) -> Bool {
           guard let bundleID, !bundleID.isEmpty else { return false }
           return bundleID != Bundle.main.bundleIdentifier
               && !bundleID.hasPrefix("com.apple.")
               && !bundleID.hasSuffix(".keyboard")
       }

       // Prefer explicit host bundle info from URL, then sourceApplication.
       if isValidHostBundle(sourceAppFromURL) {
           print("[EchoApp] captured host bundle from URL: \(sourceAppFromURL!)")
           bridge.setReturnAppBundleID(sourceAppFromURL!)
           bridge.clearReturnAppPID()
           bridge.appendDebugEvent("host bundle captured from URL: \(sourceAppFromURL!)", source: "mainapp", category: "MainView.Return")
       } else if isValidHostBundle(options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String) {
           if let sourceApp = options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String {
               print("[EchoApp] captured sourceApplication for return flow: \(sourceApp)")
               bridge.setReturnAppBundleID(sourceApp)
               bridge.clearReturnAppPID()
               bridge.appendDebugEvent("sourceApplication captured for return: \(sourceApp)", source: "mainapp", category: "MainView.Return")
           }
       } else if let sourceApp = options[UIApplication.OpenURLOptionsKey.sourceApplication] as? String, !sourceApp.isEmpty {
           print("[EchoApp] sourceApplication ignored for return flow: \(sourceApp)")
           bridge.appendDebugEvent("sourceApplication ignored for return: \(sourceApp)", source: "mainapp", category: "MainView.Return")
       }

       if let hostPIDFromURL, hostPIDFromURL > 0, bridge.returnAppBundleID == nil {
           print("[EchoApp] captured host PID from URL: \(hostPIDFromURL)")
           bridge.setReturnAppPID(hostPIDFromURL)
           bridge.appendDebugEvent("host PID captured from URL: \(hostPIDFromURL)", source: "mainapp", category: "MainView.Return")
       }

       bridge.setPendingLaunchIntent(intent)
       bridge.markLaunchAcknowledged()
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
