import SwiftUI
import EchoCore

@main
struct EchoApp: App {
    @StateObject private var authSession = EchoAuthSession.shared

    init() {
        FirebaseBootstrapper.configureIfPossible()
        EchoAuthSession.shared.start()
        CloudSyncService.shared.configureIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(authSession)
        }
    }
}
