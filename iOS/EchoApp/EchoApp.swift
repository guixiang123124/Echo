import SwiftUI
import EchoCore

@main
struct EchoApp: App {
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
