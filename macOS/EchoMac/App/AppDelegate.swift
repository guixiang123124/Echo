import AppKit
import SwiftUI
import Combine

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

    // Services
    private var voiceInputService: VoiceInputService?
    private var textInserter: TextInserter?
    private let settings = MacAppSettings.shared
    private let permissionManager = PermissionManager.shared
    private lazy var hotkeyMonitor = GlobalHotkeyMonitor(settings: settings)

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 EchoMac starting...")

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
            let windowWidth: CGFloat = 420
            let windowHeight: CGFloat = 108
            let x = screenFrame.midX - windowWidth / 2
            let y = screenFrame.minY + 44
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
        if let window = homeWindow {
            window.makeKeyAndOrderFront(nil)
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

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        homeWindow = window
    }

    func showHistoryWindow() {
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
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
        historyWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == homeWindow {
            homeWindow = nil
        } else if window == historyWindow {
            historyWindow = nil
        }
    }
}

// MARK: - Recording Panel View

struct RecordingPillView: View {
    @ObservedObject var appState: AppState
    @State private var spin = false
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
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(backgroundGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 22, y: 10)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(isProcessing && spin ? 360 : 0))
                        .animation(
                            isProcessing
                                ? .linear(duration: 1.0).repeatForever(autoreverses: false)
                                : .default,
                            value: spin
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(titleText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)

                    if appState.recordingState == .listening {
                        PillWaveformView(levels: appState.audioLevels)
                            .frame(height: 20)
                    } else if isProcessing {
                        processingLine
                    } else if case .error(let message) = appState.recordingState {
                        Text(message)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(Color.white.opacity(0.84))
                    } else {
                        Text("Ready when you are")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.84))
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 420, height: 108)
        .onAppear {
            spin = true
            shimmer = true
        }
    }

    private var backgroundGradient: LinearGradient {
        switch appState.recordingState {
        case .listening:
            return LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.35, blue: 0.92),
                    Color(red: 0.17, green: 0.65, blue: 0.88),
                    Color(red: 0.24, green: 0.76, blue: 0.56)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .transcribing, .correcting, .inserting:
            return LinearGradient(
                colors: [
                    Color(red: 0.19, green: 0.18, blue: 0.43),
                    Color(red: 0.37, green: 0.22, blue: 0.66),
                    Color(red: 0.58, green: 0.33, blue: 0.78)
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
                    Color(red: 0.17, green: 0.28, blue: 0.45),
                    Color(red: 0.16, green: 0.44, blue: 0.56)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var titleText: String {
        switch appState.recordingState {
        case .listening:
            return "Listening"
        case .transcribing, .correcting, .inserting:
            return "Transcribe & Rewrite"
        case .error:
            return "Couldn’t Process Audio"
        case .idle:
            return "Ready"
        }
    }

    private var iconName: String {
        switch appState.recordingState {
        case .listening:
            return "mic.fill"
        case .transcribing, .correcting, .inserting:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "mic"
        }
    }

    private var processingLine: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 9)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color.white.opacity(0.95),
                                Color.white.opacity(0.15)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * 0.42, height: 9)
                    .offset(x: shimmer ? geometry.size.width * 0.55 : -geometry.size.width * 0.2)
                    .animation(
                        .easeInOut(duration: 1.15).repeatForever(autoreverses: false),
                        value: shimmer
                    )
            }
        }
        .frame(height: 9)
    }
}

struct PillWaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            let samples = levels.suffix(18)
            HStack(spacing: 3) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 4, height: barHeight(for: level, maxHeight: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.08), value: levels)
        }
    }

    private func barHeight(for level: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let normalized = max(0.08, min(level, 1.0))
        return max(4, normalized * maxHeight)
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

    var totalMinutes: Int {
        Int(entries.reduce(0) { $0 + $1.duration } / 60.0)
    }

    var totalWords: Int {
        entries.reduce(0) { $0 + max(0, $1.wordCount) }
    }

    var totalSessions: Int {
        entries.count
    }

    func refresh() {
        Task { await reload() }
    }

    private func reload() async {
        isLoading = true
        entries = await RecordingStore.shared.fetchRecent(limit: 300)
        isLoading = false
    }
}

struct EchoHomeWindowView: View {
    @ObservedObject var settings: MacAppSettings
    @StateObject private var model = HomeDashboardViewModel()
    @State private var selectedSection: HomeSection = .home
    @State private var newTerm: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        .frame(minWidth: 920, minHeight: 620)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .echoRecordingSaved)) { _ in
            model.refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Echo")
                    .font(.system(size: 32, weight: .bold))
                Text("Speak naturally, write perfectly")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            ForEach(HomeSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                        Text(section.title)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(selectedSection == section ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Controls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("AI Correction", isOn: Binding(
                    get: { settings.correctionEnabled },
                    set: { settings.correctionEnabled = $0 }
                ))
                .toggleStyle(.switch)

                Toggle("Show Recording Pill", isOn: Binding(
                    get: { settings.showRecordingPanel },
                    set: { settings.showRecordingPanel = $0 }
                ))
                .toggleStyle(.switch)
            }
        }
        .padding(20)
        .frame(width: 250)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.09),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

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
            Text("Home")
                .font(.system(size: 40, weight: .bold))
            Text("Your speech typing command center.")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                HomeMetricCard(title: "Total dictation time", value: "\(model.totalMinutes) min", icon: "clock")
                HomeMetricCard(title: "Words transcribed", value: "\(max(model.totalWords, settings.totalWordsTranscribed))", icon: "mic")
                HomeMetricCard(title: "Sessions", value: "\(model.totalSessions)", icon: "waveform.path.ecg")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Pipeline")
                    .font(.headline)
                Text(settings.correctionEnabled
                    ? "Whisper transcription + optional AI rewrite enabled"
                    : "Whisper-only transcription enabled (raw output)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
            )
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.system(size: 34, weight: .bold))
                Spacer()
                Button("Refresh") {
                    model.refresh()
                }
            }

            if model.isLoading {
                ProgressView()
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if model.entries.isEmpty {
                Text("No recordings yet.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            } else {
                ForEach(model.entries.prefix(40)) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(entry.createdAt.formatted(.dateTime.month().day().hour().minute()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1fs", entry.duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.status.capitalized)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(entry.status == "success" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                )
                        }

                        if let finalText = entry.transcriptFinal, !finalText.isEmpty {
                            Text(finalText)
                                .font(.body)
                        } else if let rawText = entry.transcriptRaw, !rawText.isEmpty {
                            Text(rawText)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        } else if let error = entry.error, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
                    )
                }
            }
        }
    }

    private var dictionaryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictionary")
                .font(.system(size: 34, weight: .bold))
            Text("Add custom words to keep names and terminology stable during rewriting.")
                .foregroundStyle(.secondary)

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

            if settings.customTerms.isEmpty {
                Text("No custom terms yet.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ForEach(settings.customTerms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button("Remove") {
                            settings.removeCustomTerm(term)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }
}

private struct HomeMetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .bold))
            Text(title)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
        )
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let echoToggleRecording = Notification.Name("echo.toggleRecording")
    static let echoRecordingSaved = Notification.Name("echo.recordingSaved")
}
