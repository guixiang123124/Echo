import SwiftUI
import EchoCore

@main
struct EchoApp: App {
    @StateObject private var authSession = EchoAuthSession.shared

    init() {
        let settings = AppSettings()
        FirebaseBootstrapper.configureIfPossible()
        EchoAuthSession.shared.start()
        CloudSyncService.shared.configureIfNeeded()
        CloudSyncService.shared.setEnabled(settings.cloudSyncEnabled)
        CloudSyncService.shared.updateAuthState(user: EchoAuthSession.shared.user)
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(authSession)
        }
    }
}
