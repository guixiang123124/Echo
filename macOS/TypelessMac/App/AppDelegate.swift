import AppKit
import SwiftUI
import Combine

/// Application delegate for handling app lifecycle and global hotkey setup
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // MARK: - Properties

    private var recordingPanelWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private let diagnostics = DiagnosticsState.shared
    private var lastExternalApp: NSRunningApplication?

    // Services
    private var voiceInputService: VoiceInputService?
    private var textInserter: TextInserter?
    private let settings = MacAppSettings.shared
    private let permissionManager = PermissionManager.shared
    private lazy var hotkeyMonitor = GlobalHotkeyMonitor(settings: settings)

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 TypelessMac starting...")

        // Initialize services
        voiceInputService = VoiceInputService(settings: settings)
        textInserter = TextInserter()

        // Bind voice input state to app state for UI
        if let voiceInputService {
            voiceInputService.$audioLevels
                .sink { AppState.shared.audioLevels = $0 }
                .store(in: &cancellables)

            voiceInputService.$partialTranscription
                .sink { AppState.shared.partialTranscription = $0 }
                .store(in: &cancellables)

            voiceInputService.$finalTranscription
                .sink { AppState.shared.finalTranscription = $0 }
                .store(in: &cancellables)

            voiceInputService.$errorMessage
                .compactMap { $0 }
                .sink { [weak self] message in
                    self?.diagnostics.recordError(message)
                }
                .store(in: &cancellables)
        }

        // Check permissions
        permissionManager.checkAllPermissions()

        // React to permission changes
        permissionManager.$inputMonitoringGranted
            .removeDuplicates()
            .sink { [weak self] inputMonitoringGranted in
                guard let self else { return }
                if inputMonitoringGranted {
                    self.startHotkeyMonitoring()
                } else {
                    self.stopHotkeyMonitoring()
                }
            }
            .store(in: &cancellables)

        hotkeyMonitor.$isMonitoring
            .sink { [weak self] isMonitoring in
                self?.diagnostics.updateMonitoring(isMonitoring)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .typelessToggleRecording)
            .sink { [weak self] _ in
                self?.toggleManualRecording()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.permissionManager.checkAllPermissions()
                self.startHotkeyMonitoring()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                guard let self else { return }
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.lastExternalApp = app
                }
            }
            .store(in: &cancellables)

        // Setup hotkey monitoring (if already authorized)
        startHotkeyMonitoring()

        print("✅ TypelessMac started successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopHotkeyMonitoring()
        print("👋 TypelessMac terminated")
    }

    // MARK: - Hotkey Monitoring

    private func startHotkeyMonitoring() {
        guard permissionManager.inputMonitoringGranted else {
            print("⚠️ Hotkey monitoring disabled - missing Input Monitoring permission")
            diagnostics.updateMonitoring(false, reason: "missing input monitoring permission")
            return
        }

        hotkeyMonitor.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .pressed:
                self.diagnostics.recordHotkeyEvent("Pressed")
                self.toggleRecordingFromHotkey()
            case .released:
                self.diagnostics.recordHotkeyEvent("Released")
            }
        }
    }

    private func stopHotkeyMonitoring() {
        hotkeyMonitor.stop()
        diagnostics.updateMonitoring(false)
    }

    // MARK: - Recording Control

    private func hotkeyPressed() {
        print("🎤 Hotkey pressed - starting recording")
        diagnostics.log("Recording start requested")
        captureInsertionTarget()

        let appState = AppState.shared
        guard appState.recordingState == .idle else { return }

        Task { @MainActor in
            // Update state
            appState.recordingState = .listening

            // Play sound
            if settings.playSoundEffects {
                NSSound(named: "Morse")?.play()
            }

            // Show recording panel
            if settings.showRecordingPanel {
                showRecordingPanel()
            }

            // Start recording
            do {
                try await voiceInputService?.startRecording()
            } catch {
                print("❌ Failed to start recording: \(error)")
                diagnostics.recordError(error.localizedDescription)
                appState.recordingState = .error(error.localizedDescription)
            }
        }
    }

    private func hotkeyReleased() {
        print("🎤 Hotkey released - stopping recording")
        diagnostics.log("Recording stop requested")

        let appState = AppState.shared
        guard appState.recordingState == .listening else { return }

        Task { @MainActor in
            // Update state
            appState.recordingState = .transcribing

            do {
                // Stop recording and transcribe
                let text = try await voiceInputService?.stopRecording() ?? ""

                if text.isEmpty {
                    print("⚠️ No text transcribed")
                    appState.recordingState = .idle
                    hideRecordingPanel()
                    return
                }

                print("📝 Transcribed: \(text)")
                diagnostics.log("Transcription completed")

                // Re-activate the last external app (in case menu bar stole focus)
                await reactivateInsertionTarget()

                // Insert text
                appState.recordingState = .inserting
                await textInserter?.insert(text, restoreClipboard: false)
                diagnostics.log("Inserted text (\(text.count) chars)")

                // Play completion sound
                if settings.playSoundEffects {
                    NSSound(named: "Glass")?.play()
                }

                // Done
                appState.recordingState = .idle
                hideRecordingPanel()

            } catch {
                print("❌ Transcription failed: \(error)")
                diagnostics.recordError(error.localizedDescription)
                appState.recordingState = .error(error.localizedDescription)

                // Reset after delay
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await MainActor.run {
                        appState.recordingState = .idle
                        hideRecordingPanel()
                    }
                }
            }
        }
    }

    // MARK: - Manual Recording (No Hotkey)

    private func toggleManualRecording() {
        let state = AppState.shared.recordingState
        switch state {
        case .idle, .error:
            diagnostics.log("Manual recording start requested")
            hotkeyPressed()
        case .listening:
            diagnostics.log("Manual recording stop requested")
            hotkeyReleased()
        case .transcribing, .correcting, .inserting:
            diagnostics.log("Manual recording ignored (busy)")
        }
    }

    private func toggleRecordingFromHotkey() {
        let state = AppState.shared.recordingState
        switch state {
        case .idle, .error:
            diagnostics.log("Hotkey toggle -> start recording")
            hotkeyPressed()
        case .listening:
            diagnostics.log("Hotkey toggle -> stop recording")
            hotkeyReleased()
        case .transcribing, .correcting, .inserting:
            diagnostics.log("Hotkey toggle ignored (busy)")
        }
    }

    // MARK: - Focus Management

    private func captureInsertionTarget() {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = frontApp
        }
    }

    private func reactivateInsertionTarget() async {
        guard let app = lastExternalApp else { return }
        app.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(80))
    }

    // MARK: - Recording Panel

    private func showRecordingPanel() {
        guard recordingPanelWindow == nil else {
            recordingPanelWindow?.orderFront(nil)
            return
        }

        let panelView = RecordingOrbView(appState: AppState.shared)
        let hostingController = NSHostingController(rootView: panelView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.borderless]
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position near top-right
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 140
            let windowHeight: CGFloat = 140
            let x = screenFrame.maxX - windowWidth - 24
            let y = screenFrame.maxY - windowHeight - 64
            window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
        }

        window.orderFront(nil)
        recordingPanelWindow = window
    }

    private func hideRecordingPanel() {
        recordingPanelWindow?.orderOut(nil)
        recordingPanelWindow = nil
    }

    // MARK: - History Window

    func showHistoryWindow() {
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = RecordingHistoryView()
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Typeless History"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 560), display: true)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.makeKeyAndOrderFront(nil)
        historyWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == historyWindow {
            historyWindow = nil
        }
    }
}

// MARK: - Recording Panel View

struct RecordingOrbView: View {
    @ObservedObject var appState: AppState

    private let orbGradient = LinearGradient(
        colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.8), Color.teal.opacity(0.75)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            Circle()
                .fill(orbGradient)
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)

            pulseRing

            if appState.recordingState == .listening {
                OrbWaveformView(levels: appState.audioLevels)
                    .frame(width: 90, height: 34)
            } else if appState.recordingState == .transcribing || appState.recordingState == .correcting {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                statusIcon
            }
        }
        .frame(width: 140, height: 140)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch appState.recordingState {
        case .listening:
            Image(systemName: "mic.fill")
                .font(.system(size: 28))
                .foregroundColor(.white)
        case .transcribing:
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundColor(.white)
        case .correcting:
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundColor(.white)
        case .inserting:
            Image(systemName: "text.cursor")
                .font(.system(size: 28))
                .foregroundColor(.white)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.white)
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 28))
                .foregroundColor(.white)
        }
    }

    private var pulseRing: some View {
        let level = max(0.1, appState.audioLevels.last ?? 0)
        return Circle()
            .stroke(Color.white.opacity(0.35), lineWidth: 2)
            .scaleEffect(1 + level * 0.6)
            .opacity(0.8 - level * 0.4)
            .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct OrbWaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<levels.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.9))
                        .frame(
                            width: (geometry.size.width - CGFloat(levels.count - 1) * 2) / CGFloat(levels.count),
                            height: max(4, levels[index] * geometry.size.height)
                        )
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let typelessToggleRecording = Notification.Name("typeless.toggleRecording")
    static let typelessRecordingSaved = Notification.Name("typeless.recordingSaved")
}
