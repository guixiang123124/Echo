import SwiftUI
import AVFoundation
import EchoCore

/// Menu bar dropdown view
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var diagnostics: DiagnosticsState

    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var testResult: String = ""
    @State private var isTestingMic: Bool = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status section
            statusSection

            Divider()
                .padding(.vertical, 4)

            // Manual record control
            recordingControlSection

            Divider()
                .padding(.vertical, 4)

            // Test button - NEW!
            testSection

            Divider()
                .padding(.vertical, 4)

            // Quick actions
            quickActionsSection

            Divider()
                .padding(.vertical, 4)

            // Permission status
            permissionStatusSection

            Divider()
                .padding(.vertical, 4)

            // Diagnostics
            diagnosticsSection

            Divider()
                .padding(.vertical, 4)

            // Settings and quit
            bottomSection
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.recordingState.statusMessage)
                        .font(.headline)
                    Text(settings.hotkeyHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.2))
                .frame(width: 32, height: 32)

            Image(systemName: statusIconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(statusColor)
        }
    }

    private var statusIconName: String {
        switch appState.recordingState {
        case .idle:
            return "mic"
        case .listening:
            return "mic.fill"
        case .transcribing, .correcting:
            return "waveform"
        case .inserting:
            return "text.cursor"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch appState.recordingState {
        case .idle:
            return .secondary
        case .listening:
            return .red
        case .transcribing, .correcting, .inserting:
            return .blue
        case .error:
            return .orange
        }
    }

    // MARK: - Test Section (NEW!)

    private var recordingControlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .echoToggleRecording, object: nil)
            } label: {
                HStack {
                    Image(systemName: recordingControlIcon)
                        .foregroundColor(recordingControlColor)
                    Text(recordingControlTitle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(recordingControlColor.opacity(0.12))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(isRecordingControlDisabled)
            .padding(.horizontal, 8)
        }
    }

    private var recordingControlTitle: String {
        switch appState.recordingState {
        case .idle, .error:
            return "Start Recording"
        case .listening:
            return "Stop Recording"
        case .transcribing, .correcting, .inserting:
            return "Processing..."
        }
    }

    private var recordingControlIcon: String {
        switch appState.recordingState {
        case .idle, .error:
            return "record.circle.fill"
        case .listening:
            return "stop.circle.fill"
        case .transcribing, .correcting, .inserting:
            return "hourglass.circle.fill"
        }
    }

    private var recordingControlColor: Color {
        switch appState.recordingState {
        case .idle, .error:
            return .red
        case .listening:
            return .red
        case .transcribing, .correcting, .inserting:
            return .blue
        }
    }

    private var isRecordingControlDisabled: Bool {
        switch appState.recordingState {
        case .transcribing, .correcting, .inserting:
            return true
        case .idle, .listening, .error:
            return false
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Test Recording Button
            Button {
                startTestRecording()
            } label: {
                HStack {
                    Image(systemName: isTestingMic ? "stop.circle.fill" : "play.circle.fill")
                        .foregroundColor(isTestingMic ? .red : .green)
                    Text(isTestingMic ? "Stop Test" : "🎤 Test Recording (3 sec)")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            // Test result
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func startTestRecording() {
        if isTestingMic {
            // Stop test
            testTask?.cancel()
            testTask = nil
            isTestingMic = false
            testResult = "Test stopped"
            return
        }

        isTestingMic = true
        testResult = "🎤 Recording for 3 seconds..."

        testTask = Task {
            do {
                let captureService = AudioCaptureService()
                let micStatus = await captureService.requestPermission()
                guard micStatus else {
                    await MainActor.run {
                        testResult = "❌ Microphone permission denied"
                        isTestingMic = false
                    }
                    return
                }

                await MainActor.run {
                    testResult = "🎤 Listening... speak now!"
                    appState.recordingState = .listening
                }

                var chunks: [AudioChunk] = []
                let collectTask = Task {
                    for await chunk in captureService.audioChunks {
                        chunks.append(chunk)
                    }
                }

                try captureService.startRecording()

                // Record for 3 seconds
                try await Task.sleep(for: .seconds(3))

                captureService.stopRecording()
                try? await Task.sleep(for: .milliseconds(120))
                collectTask.cancel()

                if Task.isCancelled {
                    await MainActor.run {
                        appState.recordingState = .idle
                        isTestingMic = false
                    }
                    return
                }

                let combinedData = chunks.reduce(Data()) { $0 + $1.data }
                let totalDuration = chunks.reduce(0) { $0 + $1.duration }
                let format = chunks.first?.format ?? .default
                let combinedChunk = AudioChunk(
                    data: combinedData,
                    format: format,
                    duration: totalDuration
                )

                let whisperLanguage = whisperLanguageCode(from: settings.asrLanguage)
                let keyStore = SecureKeyStore()
                let whisperAPIKey = try? keyStore.retrieve(for: "openai_whisper")
                let whisperProvider = OpenAIWhisperProvider(
                    keyStore: keyStore,
                    language: whisperLanguage,
                    apiKey: whisperAPIKey
                )

                if let whisperAPIKey, !whisperAPIKey.isEmpty {
                    await MainActor.run {
                        testResult = "⏳ Transcribing with Whisper..."
                    }

                    let result = try await whisperProvider.transcribe(audio: combinedChunk)
                    let text = result.text

                    await MainActor.run {
                        appState.recordingState = .idle
                        isTestingMic = false
                        if text.isEmpty {
                            testResult = "⚠️ No speech detected. Try speaking louder."
                        } else {
                            testResult = "✅ Result: \(text)"
                        }
                    }
                } else {
                    await MainActor.run {
                        appState.recordingState = .idle
                        isTestingMic = false
                        if combinedData.isEmpty {
                            testResult = "⚠️ No audio captured. Check microphone input."
                        } else {
                            let durationText = String(format: "%.2f", totalDuration)
                            testResult = "✅ Recorded \(durationText)s (\(combinedData.count) bytes). Set OpenAI API key to transcribe."
                        }
                    }
                }

            } catch {
                await MainActor.run {
                    testResult = "❌ Error: \(error.localizedDescription)"
                    appState.recordingState = .idle
                    isTestingMic = false
                }
            }
        }
    }

    private func whisperLanguageCode(from setting: String) -> String? {
        switch setting {
        case "en-US":
            return "en"
        case "zh-CN", "zh-TW":
            return "zh"
        case "ja-JP":
            return "ja"
        case "ko-KR":
            return "ko"
        default:
            return nil
        }
    }

    // MARK: - Permission Status Section (NEW!)

    private var permissionStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Permissions")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            HStack(spacing: 12) {
                permissionBadge(
                    name: "Accessibility",
                    granted: permissionManager.accessibilityGranted,
                    action: { permissionManager.requestAccessibilityPermission() }
                )
                permissionBadge(
                    name: "Input",
                    granted: permissionManager.inputMonitoringGranted,
                    action: { permissionManager.requestInputMonitoringPermission() }
                )
                permissionBadge(
                    name: "Microphone",
                    granted: permissionManager.microphoneGranted,
                    action: { Task { _ = await permissionManager.requestMicrophonePermission() } }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button {
                permissionManager.checkAllPermissions()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh Permissions")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func permissionBadge(name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(granted ? .green : .red)
                Text(name)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Correction toggle
            Toggle(isOn: Binding(
                get: { settings.correctionEnabled },
                set: { settings.correctionEnabled = $0 }
            )) {
                Label("Auto Edit", systemImage: "wand.and.stars")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Text(settings.correctionEnabled ? "Mode: Whisper + Auto Edit" : "Mode: Whisper only")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            // Recording panel toggle
            Toggle(isOn: Binding(
                get: { settings.showRecordingPanel },
                set: { settings.showRecordingPanel = $0 }
            )) {
                Label("Show Panel", systemImage: "rectangle.on.rectangle")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Sound effects toggle
            Toggle(isOn: Binding(
                get: { settings.playSoundEffects },
                set: { settings.playSoundEffects = $0 }
            )) {
                Label("Sound Effects", systemImage: "speaker.wave.2")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            HStack {
                Text("Hotkey Monitor")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(diagnostics.isHotkeyMonitoring ? "On" : "Off")
                    .font(.caption)
                    .foregroundColor(diagnostics.isHotkeyMonitoring ? .green : .red)
            }
            .padding(.horizontal, 12)

            HStack {
                Text("Last Hotkey")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(diagnostics.lastHotkeyEvent)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)

            if let error = diagnostics.lastError, !error.isEmpty {
                Text("Last Error: \(error)")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
            }

            if !diagnostics.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(diagnostics.entries.suffix(5)) { entry in
                        Text("\(entry.timestamp.formatted(.dateTime.hour().minute().second())) \(entry.message)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 12)
            }

            HStack {
                Spacer()
                Button("Clear Logs") {
                    diagnostics.clear()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Statistics
            if settings.totalWordsTranscribed > 0 {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(.secondary)
                    Text("\(settings.totalWordsTranscribed) words transcribed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Divider()
                    .padding(.vertical, 4)
            }

            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openHomeWindow()
                }
            } label: {
                HStack {
                    Image(systemName: "house")
                    Text("Open Echo Home")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // Settings button
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openHistoryWindow()
                }
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("History...")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // Settings button
            Button {
                dismiss()
                openSettings()
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            // Quit button
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit Echo")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func openHomeWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "echo-home")
    }

    private func openHistoryWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "echo-history")
    }
}
