import SwiftUI
import Cocoa
import EchoCore

/// Main entry point for Echo macOS menu bar app
@main
struct EchoMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var permissionManager = PermissionManager.shared
    @StateObject private var settings = MacAppSettings.shared
    @StateObject private var diagnostics = DiagnosticsState.shared
    @StateObject private var authSession = EchoAuthSession.shared
    @StateObject private var cloudSync = CloudSyncService.shared
    @StateObject private var billing = BillingService.shared

    var body: some Scene {
        // Menu Bar Extra - the main UI
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(settings)
                .environmentObject(diagnostics)
                .environmentObject(authSession)
                .environmentObject(cloudSync)
                .environmentObject(billing)
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Settings {
            SettingsWindowView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(settings)
                .environmentObject(diagnostics)
                .environmentObject(authSession)
                .environmentObject(cloudSync)
                .environmentObject(billing)
        }

        Window("Echo Home", id: "echo-home") {
            EchoHomeWindowView(settings: settings)
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(settings)
                .environmentObject(diagnostics)
                .environmentObject(authSession)
                .environmentObject(cloudSync)
                .environmentObject(billing)
                .preferredColorScheme(.light)
                .environment(\.colorScheme, .light)
        }
        .defaultSize(width: 1080, height: 720)

        Window("Echo History", id: "echo-history") {
            RecordingHistoryView()
                .environmentObject(appState)
                .environmentObject(permissionManager)
                .environmentObject(settings)
                .environmentObject(diagnostics)
                .environmentObject(authSession)
                .environmentObject(cloudSync)
                .environmentObject(billing)
                .preferredColorScheme(.light)
                .environment(\.colorScheme, .light)
        }
        .defaultSize(width: 760, height: 560)
    }

    /// Menu bar icon that changes based on recording state
    @ViewBuilder
    private var menuBarIcon: some View {
        HStack(spacing: 4) {
            switch appState.recordingState {
            case .idle:
                Image(systemName: "mic")
                    .symbolRenderingMode(.hierarchical)
            case .listening:
                Image(systemName: "mic.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.red)
            case .transcribing, .correcting:
                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
            case .inserting:
                Image(systemName: "text.cursor")
                    .symbolRenderingMode(.hierarchical)
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
