import AppKit
import SwiftUI
import Combine
import EchoCore

/// Application delegate for handling app lifecycle and global hotkey setup
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // MARK: - Properties

    private var recordingPanelWindow: NSWindow?
    private var homeWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private let diagnostics = DiagnosticsState.shared
    private var lastExternalApp: NSRunningApplication?
    private var silenceMonitorTask: Task<Void, Never>?

    // Services
    private var voiceInputService: VoiceInputService?
    private var textInserter: TextInserter?
    private let settings = MacAppSettings.shared
    private let permissionManager = PermissionManager.shared
    private lazy var hotkeyMonitor = GlobalHotkeyMonitor(settings: settings)
    private let authSession = EchoAuthSession.shared
    private let cloudSync = CloudSyncService.shared

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 EchoMac starting...")

        // Initialize services
        voiceInputService = VoiceInputService(settings: settings)
        textInserter = TextInserter()

        authSession.start()
        cloudSync.configureIfNeeded()
        cloudSync.setEnabled(settings.cloudSyncEnabled)
        cloudSync.updateAuthState(user: authSession.user)

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

        NotificationCenter.default.publisher(for: .echoToggleRecording)
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

        authSession.$user
            .sink { [weak self] user in
                guard let self else { return }
                self.cloudSync.updateAuthState(user: user)
                if let user {
                    self.settings.currentUserId = user.uid
                    let name = user.displayName ?? user.email ?? user.phoneNumber ?? "Echo User"
                    self.settings.userDisplayName = name
                    Task { await RecordingStore.shared.migrateUser(from: self.settings.localUserId, to: user.uid) }
                } else {
                    self.settings.switchToLocalUser()
                }
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

        print("✅ EchoMac started successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopHotkeyMonitoring()
        print("👋 EchoMac terminated")
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
                self.handleHotkeyEvent(.pressed)
            case .released:
                self.handleHotkeyEvent(.released)
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
        switch appState.recordingState {
        case .idle, .error:
            break
        default:
            return
        }

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
                startSilenceMonitorIfNeeded()
            } catch {
                print("❌ Failed to start recording: \(error)")
                diagnostics.recordError(error.localizedDescription)
                appState.recordingState = .error(error.localizedDescription)
                // Reset after a short delay so the UI isn't stuck in error state
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    await MainActor.run {
                        appState.recordingState = .idle
                        hideRecordingPanel()
                    }
                }
            }
        }
    }

    private func hotkeyReleased() {
        print("🎤 Hotkey released - stopping recording")
        diagnostics.log("Recording stop requested")
        stopSilenceMonitor()

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

    private func handleHotkeyEvent(_ event: GlobalHotkeyMonitor.HotkeyEvent) {
        diagnostics.recordHotkeyEvent(event == .pressed ? "Pressed" : "Released")

        if settings.hotkeyType == .doubleCommand {
            if event == .pressed {
                hotkeyPressed()
            } else {
                hotkeyReleased()
            }
            return
        }

        switch settings.effectiveRecordingMode {
        case .holdToTalk:
            if event == .pressed {
                hotkeyPressed()
            } else {
                hotkeyReleased()
            }
        case .toggleToTalk, .handsFree:
            if event == .pressed {
                toggleRecordingFromHotkey()
            }
        }
    }

    // MARK: - Hands-Free Silence Monitor

    private func startSilenceMonitorIfNeeded() {
        stopSilenceMonitor()

        guard settings.effectiveRecordingMode == .handsFree,
              settings.handsFreeAutoStopEnabled else {
            return
        }

        silenceMonitorTask = Task { [weak self] in
            guard let self else { return }
            let silenceDuration = settings.handsFreeSilenceDuration
            let threshold = settings.handsFreeSilenceThreshold
            let minimumDuration = settings.handsFreeMinimumDuration
            let startTime = Date()
            var lastHeard = Date()
            let gracePeriod: TimeInterval = 0.4

            while !Task.isCancelled {
                if await MainActor.run(body: { AppState.shared.recordingState }) != .listening {
                    return
                }

                let levels = await MainActor.run { self.voiceInputService?.audioLevels ?? [] }
                let recent = levels.suffix(6)
                let avg = recent.reduce(0, +) / CGFloat(max(recent.count, 1))

                if Double(avg) > threshold {
                    lastHeard = Date()
                }

                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > gracePeriod,
                   elapsed >= minimumDuration,
                   Date().timeIntervalSince(lastHeard) >= silenceDuration {
                    await MainActor.run {
                        self.diagnostics.log("Auto-stop: silence \(String(format: "%.1f", silenceDuration))s")
                        if self.settings.playSoundEffects {
                            NSSound(named: "Ping")?.play()
                        }
                        self.hotkeyReleased()
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopSilenceMonitor() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
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

        let panelView = RecordingPillView(appState: AppState.shared)
        let hostingController = NSHostingController(rootView: panelView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.borderless]
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position at bottom-center so the indicator stays close to where users type.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 240
            let windowHeight: CGFloat = 44
            let x = screenFrame.midX - windowWidth / 2
            let y = screenFrame.minY + 56
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

    func showHomeWindow() {
        ensureAppVisibleForWindow()
        if let window = homeWindow {
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = EchoHomeWindowView(settings: settings)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Echo Home"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setFrame(NSRect(x: 0, y: 0, width: 1080, height: 720), display: true)
        window.center()
        window.minSize = NSSize(width: 920, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        homeWindow = window
    }

    func showHistoryWindow() {
        ensureAppVisibleForWindow()
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let view = RecordingHistoryView()
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Echo History"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 560), display: true)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        historyWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == homeWindow {
            homeWindow = nil
        } else if window == historyWindow {
            historyWindow = nil
        }
        restoreMenuBarOnlyIfNeeded()
    }

    // MARK: - Activation Policy

    private func ensureAppVisibleForWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreMenuBarOnlyIfNeeded() {
        guard homeWindow == nil, historyWindow == nil else { return }
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Recording Panel View

struct RecordingPillView: View {
    @ObservedObject var appState: AppState
    @State private var shimmer = false

    private var isProcessing: Bool {
        switch appState.recordingState {
        case .transcribing, .correcting, .inserting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(backgroundGradient)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 5)

            content
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 200, height: 34)
        .clipShape(Capsule())
        .onAppear {
            shimmer = true
        }
    }

    private var backgroundGradient: LinearGradient {
        switch appState.recordingState {
        case .listening:
            return LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.14, blue: 0.18),
                    Color(red: 0.10, green: 0.16, blue: 0.22)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .transcribing, .correcting, .inserting:
            return LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.12, blue: 0.14),
                    Color(red: 0.08, green: 0.08, blue: 0.10)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .error:
            return LinearGradient(
                colors: [
                    Color(red: 0.54, green: 0.22, blue: 0.17),
                    Color(red: 0.77, green: 0.34, blue: 0.23)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .idle:
            return LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.14, blue: 0.16),
                    Color(red: 0.12, green: 0.12, blue: 0.14)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var content: some View {
        Group {
            switch appState.recordingState {
            case .listening:
                ListeningPillContent(levels: appState.audioLevels)
            case .transcribing, .correcting, .inserting:
                ThinkingSweepView(text: "Thinking", isAnimating: shimmer)
            case .error(let message):
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.9))
            case .idle:
                Text("Ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }
}

struct ListeningPillContent: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 6) {
            SymmetricBarsView(levels: levels, reverseWeights: false)
                .frame(width: 52, height: 14)
            Text("Listening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
            SymmetricBarsView(levels: levels, reverseWeights: true)
                .frame(width: 52, height: 14)
        }
    }
}

struct SymmetricBarsView: View {
    let levels: [CGFloat]
    let reverseWeights: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = 14
                let barWidth: CGFloat = 2.4
                let spacing: CGFloat = 2.2
                let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let midY = size.height / 2
                let maxHeight = size.height

                let samples = normalizedLevels(count: count)
                let gradient = Gradient(colors: [Color.cyan.opacity(0.9), Color.blue.opacity(0.9)])

                for index in 0..<count {
                    let base = samples[index]
                    let progress = CGFloat(index) / CGFloat(max(1, count - 1))
                    let weight = reverseWeights ? (0.45 + 0.55 * (1 - progress)) : (0.45 + 0.55 * progress)
                    let phase = time * 3.2 + Double(index) * 0.7
                    let wave = 0.65 + 0.35 * ((sin(phase) + 1) / 2)
                    let height = max(2.6, pow(base * wave * weight, 0.8) * maxHeight)
                    let x = startX + CGFloat(index) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: rect.minX, y: rect.minY),
                            endPoint: CGPoint(x: rect.minX, y: rect.maxY)
                        )
                    )
                }
            }
        }
        .drawingGroup()
    }

    private func normalizedLevels(count: Int) -> [CGFloat] {
        let trimmed = Array(levels.suffix(count))
        if trimmed.count >= count {
            return trimmed.map { max(0.12, min($0, 1.0)) }
        }
        let padding = Array(repeating: CGFloat(0.12), count: count - trimmed.count)
        return padding + trimmed.map { max(0.12, min($0, 1.0)) }
    }
}

struct ThinkingSweepView: View {
    let text: String
    let isAnimating: Bool
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.05))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.05),
                                Color.white.opacity(0.35),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * 0.5)
                    .offset(x: sweep ? geometry.size.width : -geometry.size.width * 0.6)
                    .animation(
                        .linear(duration: 1.15).repeatForever(autoreverses: false),
                        value: sweep
                    )

                HStack(spacing: 6) {
                    ThinkingDotsView()
                        .frame(width: 24, height: 8)
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    ThinkingDotsView()
                        .frame(width: 24, height: 8)
                }
            }
        }
        .frame(height: 22)
        .onAppear { sweep = isAnimating }
    }
}

struct ThinkingDotsView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = 4
                let spacing: CGFloat = 4
                let radius: CGFloat = 2.2
                let totalWidth = CGFloat(count) * radius * 2 + CGFloat(count - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let centerY = size.height / 2

                for index in 0..<count {
                    let phase = time * 3 + Double(index) * 0.6
                    let pulse = 0.6 + 0.4 * ((sin(phase) + 1) / 2)
                    let alpha = 0.35 + 0.55 * ((sin(phase) + 1) / 2)
                    let r = radius * pulse
                    let x = startX + CGFloat(index) * (radius * 2 + spacing) + radius - r
                    let rect = CGRect(x: x, y: centerY - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(Color.cyan.opacity(alpha)))
                }
            }
        }
    }
}

struct WaveformLineView: Shape {
    var samples: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }

        let midY = rect.midY
        let stepX = rect.width / CGFloat(samples.count - 1)

        path.move(to: CGPoint(x: rect.minX, y: midY))

        for (index, level) in samples.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let amplitude = max(0.05, min(level, 1.0)) * rect.height * 0.45
            let y = midY - amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }

        return path
    }
}

// MARK: - Home Window

private enum HomeSection: String, CaseIterable, Identifiable {
    case home
    case history
    case dictionary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .history:
            return "History"
        case .dictionary:
            return "Dictionary"
        }
    }

    var icon: String {
        switch self {
        case .home:
            return "house"
        case .history:
            return "clock.arrow.circlepath"
        case .dictionary:
            return "book.closed"
        }
    }
}

@MainActor
private final class HomeDashboardViewModel: ObservableObject {
    @Published var entries: [RecordingStore.RecordingEntry] = []
    @Published var isLoading = false
    @Published var storageInfo: RecordingStore.StorageInfo?

    var totalMinutes: Int {
        max(0, Int(entries.reduce(0) { $0 + $1.duration } / 60.0))
    }

    var totalWords: Int {
        entries.reduce(0) { $0 + max(0, $1.wordCount) }
    }

    var totalSessions: Int {
        entries.count
    }

    var averageWPM: Int {
        guard totalMinutes > 0 else { return 0 }
        return max(0, Int(Double(totalWords) / Double(totalMinutes)))
    }

    var timeSavedMinutes: Int {
        // Rough estimate against a 180 WPM typing baseline
        guard totalWords > 0 else { return 0 }
        return max(0, Int(Double(totalWords) / 180.0))
    }

    func refresh(userId: String?) {
        Task { await reload(userId: userId) }
    }

    private func reload(userId: String?) async {
        isLoading = true
        entries = await RecordingStore.shared.fetchRecent(limit: 300, userId: userId)
        storageInfo = await RecordingStore.shared.storageInfo()
        isLoading = false
    }
}

struct EchoHomeWindowView: View {
    @ObservedObject var settings: MacAppSettings
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var authSession: EchoAuthSession
    @EnvironmentObject var cloudSync: CloudSyncService
    @StateObject private var model = HomeDashboardViewModel()
    @State private var selectedSection: HomeSection = .home
    @State private var newTerm: String = ""
    @State private var dictionaryFilter: DictionaryFilter = .all
    @State private var retentionOption: HistoryRetention = .forever
    @State private var showAuthSheet = false

    var body: some View {
        ZStack {
            EchoHomeTheme.background
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.4)
                detail
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .onAppear {
            model.refresh(userId: settings.currentUserId)
            retentionOption = HistoryRetention.from(days: settings.historyRetentionDays)
        }
        .onChange(of: retentionOption) { _, newValue in
            settings.historyRetentionDays = newValue.days
        }
        .onReceive(NotificationCenter.default.publisher(for: .echoRecordingSaved)) { _ in
            model.refresh(userId: settings.currentUserId)
        }
        .onChange(of: settings.currentUserId) { _, newValue in
            model.refresh(userId: newValue)
        }
        // The Home UI uses a Typeless-style light theme with explicit light backgrounds.
        // Force light color scheme so system text colors stay readable even if macOS is in Dark Mode.
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $showAuthSheet) {
            AuthSheetView()
                .environmentObject(authSession)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(EchoHomeTheme.accent.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(EchoHomeTheme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Echo")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Pro Trial")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(EchoHomeTheme.accent.opacity(0.15))
                        )
                }

                Spacer()
            }

            Button {
                showAuthSheet = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(authSession.isSignedIn ? authSession.displayName : "Sign in")
                        .font(.system(size: 13, weight: .semibold))
                    Text(authSession.isSignedIn ? "Cloud sync enabled" : "Sign in to sync history")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(EchoHomeTheme.cardBackground)
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(HomeSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .font(.system(size: 14, weight: .semibold))
                            Text(section.title)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(selectedSection == section ? EchoHomeTheme.accent : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedSection == section ? EchoHomeTheme.accentSoft : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Controls")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto Edit", isOn: Binding(
                    get: { settings.correctionEnabled },
                    set: { settings.correctionEnabled = $0 }
                ))

                Toggle("Show Recording Pill", isOn: Binding(
                    get: { settings.showRecordingPanel },
                    set: { settings.showRecordingPanel = $0 }
                ))
            }
            .toggleStyle(.switch)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Text("Pro Trial")
                    .font(.headline)
                Text("5 of 30 days used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: 5, total: 30)
                    .tint(EchoHomeTheme.accent)

                Button("Upgrade") {}
                    .buttonStyle(.borderedProminent)
                    .tint(EchoHomeTheme.accent)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(EchoHomeTheme.cardBackground)
            )

            HStack(spacing: 12) {
                Button(action: {}) {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button(action: {}) {
                    Image(systemName: "tray")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button(action: { openSettings() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()
            }
        }
        .padding(20)
        .frame(width: 260)
        .background(EchoHomeTheme.sidebarBackground)
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            EchoHomeTheme.contentBackground

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedSection {
                    case .home:
                        homeContent
                    case .history:
                        historyContent
                    case .dictionary:
                        dictionaryContent
                    }
                }
                .padding(24)
            }
        }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speak naturally, write perfectly — in any app")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("\(settings.hotkeyHint). Speak naturally and release to insert your words.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ], spacing: 14) {
                PersonalizationCard(progress: 0.0)
                SyncStatusCard(
                    storageInfo: model.storageInfo,
                    syncStatus: cloudSync.status,
                    isSignedIn: authSession.isSignedIn,
                    displayName: authSession.displayName
                )
                StatCard(title: "Total dictation time", value: "\(model.totalMinutes) min", icon: "clock")
                StatCard(title: "Words dictated", value: "\(max(model.totalWords, settings.totalWordsTranscribed))", icon: "mic.fill")
                StatCard(title: "Time saved", value: "\(model.timeSavedMinutes) min", icon: "bolt.fill")
                StatCard(title: "Average dictation speed", value: "\(model.averageWPM) WPM", icon: "speedometer")
                StatCard(title: "Sessions", value: "\(model.totalSessions)", icon: "waveform.path.ecg")
            }

            HStack(spacing: 14) {
                PromoCard(
                    title: "Refer friends",
                    detail: "Get $5 credit for every invite.",
                    actionTitle: "Invite friends",
                    tint: EchoHomeTheme.blueTint
                )
                PromoCard(
                    title: "Affiliate program",
                    detail: "Earn 25% recurring commission.",
                    actionTitle: "Join now",
                    tint: EchoHomeTheme.peachTint
                )
            }
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History")
                .font(.system(size: 30, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep history")
                            .font(.headline)
                        Text("How long do you want to keep your dictation history on your device?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $retentionOption) {
                        ForEach(HistoryRetention.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Text("Your data stays private. Dictations are stored only on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(EchoHomeTheme.cardBackground)
            )

            if model.isLoading {
                ProgressView()
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if model.entries.isEmpty {
                Text("No recordings yet.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.entries.prefix(80)) { entry in
                        HistoryRow(entry: entry)
                        Divider().opacity(0.6)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(EchoHomeTheme.cardBackground)
                )
            }
        }
    }

    private var dictionaryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Dictionary")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Spacer()
                Button("New word") {
                    // Focus stays in the add field below
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                ForEach(DictionaryFilter.allCases) { filter in
                    Button(filter.title) { dictionaryFilter = filter }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(dictionaryFilter == filter ? EchoHomeTheme.accentSoft : EchoHomeTheme.cardBackground)
                        )
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: .constant(""))
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(EchoHomeTheme.cardBackground)
                )
            }

            HStack(spacing: 8) {
                TextField("Add new term", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !term.isEmpty else { return }
                    settings.addCustomTerm(term)
                    newTerm = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            let filteredTerms = filteredDictionaryTerms

            if filteredTerms.isEmpty {
                VStack(spacing: 8) {
                    Text("No words yet")
                        .font(.headline)
                    Text("Echo remembers unique names and terms you add here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(EchoHomeTheme.cardBackground)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredTerms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button("Remove") {
                                settings.removeCustomTerm(term)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        Divider().opacity(0.6)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(EchoHomeTheme.cardBackground)
                )
            }
        }
    }

    private var filteredDictionaryTerms: [String] {
        switch dictionaryFilter {
        case .all, .manual:
            return settings.customTerms
        case .autoAdded:
            return []
        }
    }
}

private enum EchoHomeTheme {
    static let background = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let sidebarBackground = Color(red: 0.95, green: 0.95, blue: 0.97)
    static let cardBackground = Color.white
    static let accent = Color(red: 0.23, green: 0.46, blue: 0.95)
    static let accentSoft = Color(red: 0.88, green: 0.92, blue: 0.99)
    static let blueTint = Color(red: 0.86, green: 0.93, blue: 0.99)
    static let peachTint = Color(red: 0.99, green: 0.93, blue: 0.89)

    static let contentBackground = LinearGradient(
        colors: [
            Color.white.opacity(0.9),
            Color.white.opacity(0.92),
            Color(red: 0.98, green: 0.98, blue: 0.99)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(EchoHomeTheme.accent)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(title)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(EchoHomeTheme.cardBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 6)
        )
    }
}

private struct PersonalizationCard: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overall personalization")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.1), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: max(0.01, progress))
                        .stroke(EchoHomeTheme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.title2.bold())
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    Text("View report")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(EchoHomeTheme.accentSoft))
                    Text("Your data stays private.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(EchoHomeTheme.cardBackground)
                .shadow(color: Color.black.opacity(0.04), radius: 10, y: 6)
        )
    }
}

private struct SyncStatusCard: View {
    let storageInfo: RecordingStore.StorageInfo?
    let syncStatus: CloudSyncService.Status
    let isSignedIn: Bool
    let displayName: String

    private var statusText: String {
        switch syncStatus {
        case .idle:
            return "Idle"
        case .disabled(let reason):
            return reason
        case .syncing:
            return "Syncing..."
        case .synced(let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Synced at \(formatter.string(from: date))"
        case .error(let message):
            return "Sync error: \(message)"
        }
    }

    private var statusColor: Color {
        switch syncStatus {
        case .error:
            return .red
        case .disabled:
            return .secondary
        case .syncing:
            return .blue
        case .synced:
            return .green
        case .idle:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundStyle(EchoHomeTheme.accent)
                Text("Database & Sync")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(isSignedIn ? "Signed in as \(displayName)" : "Not signed in")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if let storageInfo {
                Text("Local records: \(storageInfo.entryCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(storageInfo.databaseURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(EchoHomeTheme.cardBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 10, y: 6)
        )
    }
}

private struct PromoCard: View {
    let title: String
    let detail: String
    let actionTitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(actionTitle) {}
                .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint)
        )
    }
}

private struct HistoryRow: View {
    let entry: RecordingStore.RecordingEntry

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: entry.createdAt)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(timeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if let finalText = entry.transcriptFinal, !finalText.isEmpty {
                    Text(finalText)
                        .font(.system(size: 14))
                } else if let rawText = entry.transcriptRaw, !rawText.isEmpty {
                    Text(rawText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else if let error = entry.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("No transcription available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private enum DictionaryFilter: String, CaseIterable, Identifiable {
    case all
    case autoAdded
    case manual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .autoAdded: return "Auto-added"
        case .manual: return "Manually-added"
        }
    }
}

private enum HistoryRetention: String, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case forever

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .forever: return 36500
        }
    }
    var title: String {
        switch self {
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .forever: return "Forever"
        }
    }

    static func from(days: Int) -> HistoryRetention {
        switch days {
        case 30: return .thirtyDays
        case 7: return .sevenDays
        default: return .forever
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let echoToggleRecording = Notification.Name("echo.toggleRecording")
    static let echoRecordingSaved = Notification.Name("echo.recordingSaved")
}
