import AppKit
import CoreGraphics
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
    private var isStreamingInsertionSessionActive = false
    private var didUseStreamingKeyboardFallback = false
    private let diagnostics = DiagnosticsState.shared
    private var lastExternalApp: NSRunningApplication?
    private var silenceMonitorTask: Task<Void, Never>?
    private var lastStreamingUpdateMethod: String?
    private var isAwaitingDeferredPolish = false
    private var deferredPolishCloseTask: Task<Void, Never>?
    private var lastStreamingSanitizedText: String = ""
    private var pendingDeferredPolishText: String?
    private var pendingDeferredPolishTraceId: String?
    private var activeDeferredPolishTraceId: String?
    private var lastFinalizeTextForPolish: String = ""
    private struct AutoEditUndoSnapshot {
        let finalizedText: String
        let polishedText: String
        let traceId: String?
        let createdAt: Date
    }
    private var lastAutoEditUndoSnapshot: AutoEditUndoSnapshot?

    // Services
    private var voiceInputService: VoiceInputService?
    private var textInserter: TextInserter?
    private let settings = MacAppSettings.shared
    private let permissionManager = PermissionManager.shared
    private lazy var hotkeyMonitor = GlobalHotkeyMonitor(settings: settings)
    private let authSession = EchoAuthSession.shared
    private let cloudSync = CloudSyncService.shared
    private let billing = BillingService.shared
    private let isScreenshotAutomation: Bool = {
        ProcessInfo.processInfo.environment["ECHO_AUTOMATION_SCREENSHOT"] == "1"
            || CommandLine.arguments.contains("--automation-screenshot")
    }()
    private lazy var screenshotAutomationOutDir: URL = {
        if let idx = CommandLine.arguments.firstIndex(of: "--automation-out-dir"),
           idx + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[idx + 1])
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/EchoScreenshots", isDirectory: true)
    }()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 EchoMac starting...")
        NSApp.appearance = NSAppearance(named: .aqua)

        // Seed embedded API keys into Keychain
        EmbeddedKeyProvider.shared.seedKeychainIfNeeded()
        settings.normalizeOpenAIModel()

        // Write startup diagnostics to UserDefaults for CLI debugging
        let ks = SecureKeyStore()
        let volcAppId = (try? ks.retrieve(for: "volcano_app_id")) ?? "<missing>"
        let volcKey = (try? ks.retrieve(for: "volcano_access_key")) ?? "<missing>"
        UserDefaults.standard.set(
            "[\(Date())] provider=\(settings.selectedASRProvider) mode=\(settings.asrMode) apiCall=\(settings.apiCallMode) volcAppId=\(String(volcAppId.prefix(6)))... volcKey=\(String(volcKey.prefix(4)))...",
            forKey: "echo.debug.startupDiag"
        )

        // Initialize services
        voiceInputService = VoiceInputService(settings: settings)
        textInserter = TextInserter()

        authSession.configureBackend(baseURL: settings.cloudSyncBaseURL)
        authSession.start()
        cloudSync.configure(
            baseURLString: settings.cloudSyncBaseURL,
            uploadAudio: settings.cloudUploadAudioEnabled
        )
        cloudSync.setEnabled(settings.cloudSyncEnabled)
        cloudSync.updateAuthState(user: authSession.user)
        billing.configure(baseURLString: settings.cloudSyncBaseURL)
        billing.setEnabled(settings.cloudSyncEnabled)
        billing.updateAuthState(user: authSession.user)

        // Bind voice input state to app state for UI
        if let voiceInputService {
            voiceInputService.$audioLevels
                .sink { AppState.shared.audioLevels = $0 }
                .store(in: &cancellables)

            voiceInputService.$partialTranscription
                .sink { text in
                    if !AppState.shared.isStreamingModeActive {
                        AppState.shared.partialTranscription = text
                    }
                }
                .store(in: &cancellables)

            voiceInputService.onStreamingTextUpdate = { [weak self, weak voiceInputService] text in
                guard let self, let voiceInputService else { return }
                guard voiceInputService.isStreamingSessionActive else { return }

                let insertionText = (voiceInputService.bestStreamingPartialTranscription.isEmpty
                                     ? text
                                     : voiceInputService.bestStreamingPartialTranscription).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !insertionText.isEmpty else { return }

                Task { @MainActor in
                    await self.handleStreamingInsertionUpdate(insertionText)
                }
            }

            voiceInputService.onDeferredPolishReady = { [weak self] text, traceId in
                guard let self else { return }
                Task { @MainActor in
                    if self.isAwaitingDeferredPolish {
                        await self.handleDeferredPolishUpdate(text, traceId: traceId)
                    } else {
                        self.pendingDeferredPolishText = text
                        self.pendingDeferredPolishTraceId = traceId
                        self.diagnostics.log("Deferred polish buffered before finalize handoff")
                    }
                }
            }

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

        NotificationCenter.default.publisher(for: .echoUndoLastAutoEdit)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.undoLastAutoEdit()
                }
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
                self.billing.updateAuthState(user: user)
                Task { await self.billing.refresh() }
                if let user {
                    self.settings.currentUserId = user.uid
                    let name = user.displayName ?? user.email ?? user.phoneNumber ?? "Echo User"
                    self.settings.userDisplayName = name
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

        // Used by scripts to generate deterministic App Store screenshots.
        if isScreenshotAutomation {
            runScreenshotAutomation()
        }

        logStartupDiagnostics()
        print("✅ EchoMac started successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        voiceInputService?.onStreamingTextUpdate = nil
        voiceInputService?.onDeferredPolishReady = nil
        deferredPolishCloseTask?.cancel()
        stopHotkeyMonitoring()
        print("👋 EchoMac terminated")
    }

    private func logStartupDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let commit = resolveGitCommit() ?? "unknown"

        Task {
            let storageInfo = await RecordingStore.shared.storageInfo()
            let health = await RecordingStore.shared.schemaHealth()

            print("🧾 Startup diagnostics: version=\(version) build=\(build) commit=\(commit)")
            print("🧾 Startup diagnostics DB path: \(storageInfo.databaseURL.path)")
            print("🧾 Startup diagnostics schema version: \(health.schemaVersion)")
            print("🧾 Startup diagnostics schema required columns: \(health.requiredColumns.count)")
            print("🧾 Startup diagnostics schema missing columns: \(health.missingColumns)")

            if health.isHealthy {
                print("✅ Startup diagnostics: schema health check passed")
            } else {
                print("❌ Startup diagnostics: schema health check failed")
            }
        }
    }

    private func resolveGitCommit() -> String? {
        for candidate in resolveProjectRoots() {
            let arguments = ["-C", candidate.path, "rev-parse", "--short", "HEAD"]
            guard let resolved = runShellCommand("/usr/bin/env", arguments: ["git"] + arguments),
                  !resolved.isEmpty else {
                continue
            }
            return resolved
        }
        return nil
    }

    private func resolveProjectRoots() -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        var current = bundleURL

        candidates.append(bundleURL)
        candidates.append(cwd)
        candidates.append(cwd.appendingPathComponent("..").standardizedFileURL)
        candidates.append(cwd.appendingPathComponent("../..").standardizedFileURL)
        candidates.append(cwd.appendingPathComponent("../../..").standardizedFileURL)

        for _ in 0..<8 {
            current = current.deletingLastPathComponent()
            candidates.append(current)
            if current.path == "/" { break }
        }

        return candidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .filter { !$0.path.hasPrefix(NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData") }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(".git").path) }
    }

    private func runShellCommand(_ executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let raw = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let line = raw.split { $0 == "\n" || $0 == "\r" }.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return line?.isEmpty == false ? line : nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon should reopen the main Home window.
        showHomeWindow()
        return true
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
        case .correcting:
            diagnostics.log("Recording start during polish; cancelling pending polish and restarting")
            clearDeferredPolishState()
            appState.recordingState = .idle
            hideRecordingPanel()
        case .listening, .transcribing, .inserting:
            diagnostics.log("Recording start ignored (busy=\(String(describing: appState.recordingState)))")
            return
        default:
            diagnostics.log("Recording start ignored (unhandled busy state)")
            return
        }

        Task { @MainActor in
            // Update state
                appState.recordingState = .listening
                appState.isStreamingModeActive = settings.asrMode == .stream
                didUseStreamingKeyboardFallback = false
                textInserter?.cancelStreamingInsertion()
                textInserter?.resetStreamingFallbackState()
                lastStreamingUpdateMethod = nil
                lastStreamingSanitizedText = ""
                isAwaitingDeferredPolish = false
                deferredPolishCloseTask?.cancel()
                deferredPolishCloseTask = nil
                clearAutoEditUndoSnapshot()

                // Play sound
            if settings.playSoundEffects {
                NSSound(named: "Morse")?.play()
            }

            // Start recording
            do {
                try await voiceInputService?.startRecording()
                let isStreamingMode = voiceInputService?.isStreamingSessionActive == true
                appState.isStreamingModeActive = isStreamingMode

                if isStreamingMode,
                   let textInserter {
                    // Keep target app focused during live streaming insertion.
                    await reactivateInsertionTarget()
                    textInserter.resetStreamingFallbackState()
                    didUseStreamingKeyboardFallback = false
                    isStreamingInsertionSessionActive = false
                    lastStreamingUpdateMethod = nil
                    diagnostics.log("Streaming insertion prepared; attempting direct streaming insertion")
                    showRecordingPanel()
                } else if isStreamingMode {
                    diagnostics.log("Streaming insertion target unavailable; showing stream status panel only")
                    showRecordingPanel()
                } else if settings.showRecordingPanel {
                    showRecordingPanel()
                }

                startSilenceMonitorIfNeeded()
            } catch {
                print("❌ Failed to start recording: \(error)")
                diagnostics.recordError(error.localizedDescription)
                appState.recordingState = .error(error.localizedDescription)
                appState.isStreamingModeActive = false
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
            let wasStreamingSession = appState.isStreamingModeActive
            diagnostics.log("Stage[stream] stop mode=\(wasStreamingSession ? "stream" : "batch") autoEdit=\(settings.correctionEnabled ? "on" : "off")")

            // Update state
            appState.recordingState = .transcribing
            defer {
                if !self.isAwaitingDeferredPolish {
                    self.isStreamingInsertionSessionActive = false
                    self.didUseStreamingKeyboardFallback = false
                    self.lastStreamingUpdateMethod = nil
                }
                appState.isStreamingModeActive = false
            }

            do {
                // Stop recording and transcribe
                let finalizeStart = Date()
                let rawText = try await voiceInputService?.stopRecording() ?? ""
                let pillText = (voiceInputService?.partialTranscription ?? appState.partialTranscription)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let bestPartialText = voiceInputService?.bestStreamingPartialTranscription
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let bestObservedText = bestPartialText.count >= pillText.count ? bestPartialText : pillText
                let finalText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalizeMs = Int(Date().timeIntervalSince(finalizeStart) * 1000)
                diagnostics.log("Stage[finalize] done ms=\(finalizeMs) final_len=\(finalText.count) partial_len=\(bestObservedText.count)")
                let insertionText: String
                let shouldDeferPolish = wasStreamingSession && settings.streamFastEnabled && (voiceInputService?.hasDeferredPolish == true)
                if shouldDeferPolish {
                    activeDeferredPolishTraceId = voiceInputService?.deferredPolishTraceId
                } else {
                    activeDeferredPolishTraceId = nil
                }
                if shouldDeferPolish {
                    diagnostics.log("Stage[polish] queued")
                } else {
                    let reason: String
                    if !wasStreamingSession {
                        reason = "not_streaming"
                    } else if !settings.streamFastEnabled {
                        reason = "streamfast_off"
                    } else if !settings.correctionEnabled {
                        reason = "autoedit_off"
                    } else {
                        reason = "not_available"
                    }
                    diagnostics.log("Stage[polish] skipped reason=\(reason)")
                }

                if wasStreamingSession {
                    if !finalText.isEmpty {
                        insertionText = finalText
                        diagnostics.log("Streaming finalize completed (\(finalText.count) chars)")
                    } else {
                        insertionText = self.bestInsertionText(
                            finalText: finalText,
                            streamingText: bestObservedText
                        )
                        diagnostics.log("Streaming finalize missing; fallback to strongest partial (\(insertionText.count) chars)")
                    }
                    if shouldDeferPolish {
                        appState.recordingState = .correcting
                        showRecordingPanel()
                    }
                } else {
                    var text = finalText
                    if bestObservedText.count >= 12 && text.count + 6 <= bestObservedText.count {
                        diagnostics.log("Using best partial fallback for insertion (final=\(text.count), partial=\(bestObservedText.count))")
                        text = bestObservedText
                    }
                    insertionText = self.bestInsertionText(
                        finalText: text,
                        streamingText: bestObservedText
                    )
                }

                await reactivateInsertionTarget()

                if wasStreamingSession {
                    if didUseStreamingKeyboardFallback,
                       !isStreamingInsertionSessionActive,
                       let textInserter {
                        switch textInserter.startStreamingInsertionSession() {
                        case .attached:
                            isStreamingInsertionSessionActive = true
                            didUseStreamingKeyboardFallback = false
                            diagnostics.log("Streaming finalize recovered from keyboard fallback")
                        case .failed(let failure):
                            logStreamingInsertionFailure("final-reattach", reason: failure)
                        }
                    }

                    if insertionText.isEmpty {
                        diagnostics.log("Streaming finalize skipped to avoid empty overwrite")
                        hideRecordingPanel()
                        appState.recordingState = .idle
                        return
                    }

                    if isStreamingInsertionSessionActive && !didUseStreamingKeyboardFallback {
                        let streamOutcome: TextInserter.StreamingUpdateResult?
                        if shouldDeferPolish {
                            streamOutcome = textInserter?.updateStreamingInsertion(insertionText)
                        } else {
                            streamOutcome = textInserter?.finishStreamingInsertion(with: insertionText)
                        }

                        switch streamOutcome {
                        case .updated(let method, let characterCount):
                            if shouldDeferPolish {
                                diagnostics.log("Streaming finalize committed via \(method) (\(characterCount) chars), deferred polish pending")
                                lastFinalizeTextForPolish = insertionText
                                if activeDeferredPolishTraceId == nil {
                                    activeDeferredPolishTraceId = voiceInputService?.deferredPolishTraceId
                                }
                                isAwaitingDeferredPolish = true
                                scheduleDeferredPolishAutoClose()
                                await consumePendingDeferredPolishIfNeeded()
                            } else {
                                textInserter?.cancelStreamingInsertion()
                                diagnostics.log("Streaming final via \(method) (\(characterCount) chars)")
                            }
                            if settings.playSoundEffects {
                                NSSound(named: "Glass")?.play()
                            }
                            if shouldDeferPolish {
                                appState.recordingState = .correcting
                            } else {
                                appState.recordingState = .idle
                                hideRecordingPanel()
                            }
                            return
                        case .failed(let failure):
                            self.logStreamingInsertionFailure("final-stream", reason: failure)
                            self.didUseStreamingKeyboardFallback = true
                            textInserter?.cancelStreamingInsertion()
                            self.isStreamingInsertionSessionActive = false
                            self.isAwaitingDeferredPolish = false
                        default:
                            diagnostics.log("Streaming final stream finalization unavailable (no inserter)")
                        }
                    }

                    switch textInserter?.applyStreamingKeyboardFallback(insertionText) {
                    case .updated(let method, let characterCount):
                        if shouldDeferPolish {
                            diagnostics.log("Streaming finalize via keyboard fallback \(method) (\(characterCount) chars), deferred polish pending")
                            lastFinalizeTextForPolish = insertionText
                            if activeDeferredPolishTraceId == nil {
                                activeDeferredPolishTraceId = voiceInputService?.deferredPolishTraceId
                            }
                            isAwaitingDeferredPolish = true
                            scheduleDeferredPolishAutoClose()
                            await consumePendingDeferredPolishIfNeeded()
                        } else {
                            textInserter?.cancelStreamingInsertion()
                            diagnostics.log("Streaming final via keyboard fallback \(method) (\(characterCount) chars)")
                        }
                        if settings.playSoundEffects {
                            NSSound(named: "Glass")?.play()
                        }
                        if shouldDeferPolish {
                            appState.recordingState = .correcting
                        } else {
                            appState.recordingState = .idle
                            hideRecordingPanel()
                        }
                        return
                    case .failed(let failure):
                        self.logStreamingInsertionFailure("final-fallback", reason: failure)
                    case nil:
                        diagnostics.log("Streaming final fallback unavailable: no active inserter")
                    }
                }

                if insertionText.isEmpty {
                    print("⚠️ No text transcribed")
                    appState.recordingState = .idle
                    hideRecordingPanel()
                    appState.isStreamingModeActive = false
                    return
                }

                print("📝 Transcribed: \(insertionText)")
                diagnostics.log("Transcription completed")

                // Re-activate the last external app (in case menu bar stole focus)
                // Insert text
                appState.recordingState = .inserting
                await textInserter?.insert(insertionText, restoreClipboard: false)
                diagnostics.log("Inserted text (\(insertionText.count) chars)")

                // Play completion sound
                if settings.playSoundEffects {
                    NSSound(named: "Glass")?.play()
                }

                // Done
                appState.recordingState = .idle
                appState.isStreamingModeActive = false
                hideRecordingPanel()

            } catch {
                print("❌ Transcription failed: \(error)")
                appState.isStreamingModeActive = false
                clearDeferredPolishState()
                if self.isStreamingInsertionSessionActive {
                    textInserter?.cancelStreamingInsertion()
                    self.isStreamingInsertionSessionActive = false
                }
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

    @MainActor
    private func handleStreamingInsertionUpdate(_ text: String) async {
        guard let textInserter else { return }
        let normalizedText = sanitizeLiveStreamingInsertionText(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            previousText: lastStreamingSanitizedText
        )
        guard !normalizedText.isEmpty else { return }
        if normalizedText == lastStreamingSanitizedText { return }
        if !lastStreamingSanitizedText.isEmpty,
           normalizedText.count < lastStreamingSanitizedText.count,
           lastStreamingSanitizedText.hasPrefix(normalizedText) {
            return
        }
        lastStreamingSanitizedText = normalizedText

        await reactivateInsertionTarget()

        func applyKeyboardFallback(_ insertionText: String, stage: String) {
            let fallbackOutcome = textInserter.applyStreamingKeyboardFallback(insertionText)
            switch fallbackOutcome {
            case .updated(let method, let characterCount):
                if self.lastStreamingUpdateMethod != method {
                    self.lastStreamingUpdateMethod = method
                    diagnostics.log("Streaming insertion fallback-\(stage) via \(method) (\(characterCount) chars)")
                }
                self.didUseStreamingKeyboardFallback = true
                self.isStreamingInsertionSessionActive = false
            case .failed(let failure):
                self.logStreamingInsertionFailure("fallback-\(stage)", reason: failure)
                self.didUseStreamingKeyboardFallback = false
            }
        }

        func attachStreamingSession() async -> Bool {
            let start = Date()
            switch textInserter.startStreamingInsertionSession() {
            case .attached:
                self.isStreamingInsertionSessionActive = true
                self.lastStreamingUpdateMethod = nil
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                diagnostics.log("Streaming insertion attached (\(elapsed)ms)")
                return true
            case .failed(let failure):
                self.logStreamingInsertionFailure("attach", reason: failure)
                return false
            }
        }

        if didUseStreamingKeyboardFallback {
            if !isStreamingInsertionSessionActive {
                if lastExternalApp == nil { captureInsertionTarget() }
                let reattached = await attachStreamingSession()
                if reattached {
                    didUseStreamingKeyboardFallback = false
                    diagnostics.log("Streaming insertion recovered from keyboard fallback")
                } else {
                    applyKeyboardFallback(normalizedText, stage: "update")
                    return
                }
            } else {
                didUseStreamingKeyboardFallback = false
            }
        }

        if !isStreamingInsertionSessionActive {
            if lastExternalApp == nil { captureInsertionTarget() }
            let attached = await attachStreamingSession()
            if !attached {
                applyKeyboardFallback(normalizedText, stage: "attach")
                return
            }
        }

        func applyStreamingUpdate() -> TextInserter.StreamingUpdateResult {
            textInserter.updateStreamingInsertion(normalizedText)
        }

        let outcome = applyStreamingUpdate()
        switch outcome {
        case .updated(let method, let characterCount):
            if method.hasPrefix("keyboard-fallback") {
                didUseStreamingKeyboardFallback = true
            } else {
                didUseStreamingKeyboardFallback = false
            }

            if self.lastStreamingUpdateMethod != method {
                self.lastStreamingUpdateMethod = method
                diagnostics.log("Streaming insertion update via \(method) (\(characterCount) chars)")
            }
        case .failed(let failure):
            if failure.category == .focus || failure.category == .selection || failure.category == .accessibility {
                diagnostics.log("Streaming insertion \(failure.category.rawValue) failed, retry attach")

                textInserter.cancelStreamingInsertion()
                self.isStreamingInsertionSessionActive = false
                self.lastStreamingUpdateMethod = nil

                guard await attachStreamingSession() else {
                    applyKeyboardFallback(normalizedText, stage: "retry-attach")
                    return
                }

                switch applyStreamingUpdate() {
                case .updated(let method, let characterCount):
                    if method.hasPrefix("keyboard-fallback") {
                        didUseStreamingKeyboardFallback = true
                    } else {
                        didUseStreamingKeyboardFallback = false
                    }

                    if self.lastStreamingUpdateMethod != method {
                        self.lastStreamingUpdateMethod = method
                        diagnostics.log("Streaming insertion update via \(method) (\(characterCount) chars)")
                    }
                case .failed(let retryFailure):
                    textInserter.cancelStreamingInsertion()
                    self.isStreamingInsertionSessionActive = false
                    self.lastStreamingUpdateMethod = nil
                    self.logStreamingInsertionFailure("update", reason: retryFailure)
                    applyKeyboardFallback(normalizedText, stage: "retry")
                }
                return
            }

            applyKeyboardFallback(normalizedText, stage: "update")
            textInserter.cancelStreamingInsertion()
            self.isStreamingInsertionSessionActive = false
            self.lastStreamingUpdateMethod = nil
            self.logStreamingInsertionFailure("update", reason: failure)
        }
    }

    @MainActor
    private func handleDeferredPolishUpdate(_ text: String, traceId: String? = nil) async {
        guard isAwaitingDeferredPolish else { return }
        let resolvedTraceId = (traceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? traceId
            : activeDeferredPolishTraceId
        if let resolvedTraceId {
            await RecordingStore.shared.appendAuditEvent(
                traceId: resolvedTraceId,
                stage: "autoedit_ui",
                event: "received"
            )
        }
        defer {
            textInserter?.cancelStreamingInsertion()
            AppState.shared.recordingState = .idle
            hideRecordingPanel()
            clearDeferredPolishState()
        }

        let polished = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else {
            diagnostics.log("Stage[polish] empty_result keep_finalize")
            if let resolvedTraceId {
                await RecordingStore.shared.appendAuditEvent(
                    traceId: resolvedTraceId,
                    stage: "autoedit_ui",
                    event: "empty_result"
                )
            }
            return
        }
        let finalized = lastFinalizeTextForPolish.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = !finalized.isEmpty && finalized != polished
        if changed && settings.autoEditApplyMode == .confirmDiff {
            let shouldApply = confirmDeferredPolishReplacement(finalized: finalized, polished: polished)
            if !shouldApply {
                diagnostics.log("Stage[polish] confirm_diff skipped")
                if let resolvedTraceId {
                    await RecordingStore.shared.appendAuditEvent(
                        traceId: resolvedTraceId,
                        stage: "autoedit_ui",
                        event: "confirm_skipped",
                        changed: false
                    )
                }
                return
            }
        }
        diagnostics.log("Stage[polish] apply len=\(polished.count) changed=\(changed ? "yes" : "no")")
        if let resolvedTraceId {
            await RecordingStore.shared.appendAuditEvent(
                traceId: resolvedTraceId,
                stage: "autoedit_ui",
                event: "apply",
                changed: changed,
                message: "len=\(polished.count)"
            )
        }

        await reactivateInsertionTarget()

        if didUseStreamingKeyboardFallback,
           !isStreamingInsertionSessionActive,
           let textInserter {
            switch textInserter.startStreamingInsertionSession() {
            case .attached:
                isStreamingInsertionSessionActive = true
                didUseStreamingKeyboardFallback = false
                diagnostics.log("Deferred polish recovered from keyboard fallback")
            case .failed(let failure):
                logStreamingInsertionFailure("deferred-reattach", reason: failure)
            }
        }

        if didUseStreamingKeyboardFallback {
            switch textInserter?.applyStreamingKeyboardFallback(polished) {
            case .updated(let method, let characterCount):
                diagnostics.log("Deferred polish applied via keyboard fallback \(method) (\(characterCount) chars)")
                if let resolvedTraceId {
                    await RecordingStore.shared.appendAuditEvent(
                        traceId: resolvedTraceId,
                        stage: "autoedit_ui",
                        event: "applied",
                        changed: changed,
                        message: "\(method) chars=\(characterCount)"
                    )
                }
                if changed {
                    storeAutoEditUndoSnapshot(finalized: finalized, polished: polished, traceId: resolvedTraceId)
                }
            case .failed(let failure):
                logStreamingInsertionFailure("deferred-fallback", reason: failure)
                if let resolvedTraceId {
                    await RecordingStore.shared.appendAuditEvent(
                        traceId: resolvedTraceId,
                        stage: "autoedit_ui",
                        event: "failed",
                        changed: changed,
                        message: "fallback \(failure.category.rawValue) \(failure.details)"
                    )
                }
            case nil:
                diagnostics.log("Deferred polish unavailable: no text inserter for fallback path")
                if let resolvedTraceId {
                    await RecordingStore.shared.appendAuditEvent(
                        traceId: resolvedTraceId,
                        stage: "autoedit_ui",
                        event: "unavailable",
                        message: "no_text_inserter_fallback_path"
                    )
                }
            }
            return
        }

        if isStreamingInsertionSessionActive {
            switch textInserter?.finishStreamingInsertion(with: polished) {
            case .updated(let method, let characterCount):
                diagnostics.log("Deferred polish applied via \(method) (\(characterCount) chars)")
                if let resolvedTraceId {
                    await RecordingStore.shared.appendAuditEvent(
                        traceId: resolvedTraceId,
                        stage: "autoedit_ui",
                        event: "applied",
                        changed: changed,
                        message: "\(method) chars=\(characterCount)"
                    )
                }
                if changed {
                    storeAutoEditUndoSnapshot(finalized: finalized, polished: polished, traceId: resolvedTraceId)
                }
            case .failed(let failure):
                logStreamingInsertionFailure("deferred-stream", reason: failure)
                if let resolvedTraceId {
                    await RecordingStore.shared.appendAuditEvent(
                        traceId: resolvedTraceId,
                        stage: "autoedit_ui",
                        event: "failed",
                        changed: changed,
                        message: "stream \(failure.category.rawValue) \(failure.details)"
                    )
                }
            case nil:
                diagnostics.log("Deferred polish unavailable: no active streaming inserter")
                if let resolvedTraceId {
                    await RecordingStore.shared.appendAuditEvent(
                        traceId: resolvedTraceId,
                        stage: "autoedit_ui",
                        event: "unavailable",
                        message: "no_active_streaming_inserter"
                    )
                }
            }
            return
        }

        switch textInserter?.applyStreamingKeyboardFallback(polished) {
        case .updated(let method, let characterCount):
            diagnostics.log("Deferred polish fallback applied via \(method) (\(characterCount) chars)")
            if let resolvedTraceId {
                await RecordingStore.shared.appendAuditEvent(
                    traceId: resolvedTraceId,
                    stage: "autoedit_ui",
                    event: "applied",
                    changed: changed,
                    message: "fallback \(method) chars=\(characterCount)"
                )
            }
            if changed {
                storeAutoEditUndoSnapshot(finalized: finalized, polished: polished, traceId: resolvedTraceId)
            }
        case .failed(let failure):
            logStreamingInsertionFailure("deferred-no-session", reason: failure)
            if let resolvedTraceId {
                await RecordingStore.shared.appendAuditEvent(
                    traceId: resolvedTraceId,
                    stage: "autoedit_ui",
                    event: "failed",
                    changed: changed,
                    message: "no_session \(failure.category.rawValue) \(failure.details)"
                )
            }
        case nil:
            diagnostics.log("Deferred polish unavailable: no text inserter")
            if let resolvedTraceId {
                await RecordingStore.shared.appendAuditEvent(
                    traceId: resolvedTraceId,
                    stage: "autoedit_ui",
                    event: "unavailable",
                    message: "no_text_inserter"
                )
            }
        }
    }

    private func scheduleDeferredPolishAutoClose() {
        deferredPolishCloseTask?.cancel()
        deferredPolishCloseTask = Task { [weak self] in
            // Keep polishing window alive long enough for normal LLM completion.
            // A short timeout was dropping valid AutoEdit results on slower calls.
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.isAwaitingDeferredPolish else { return }
                self.diagnostics.log("Stage[polish] timeout keep_finalize")
                if let traceId = self.activeDeferredPolishTraceId {
                    Task { await RecordingStore.shared.appendAuditEvent(traceId: traceId, stage: "autoedit_ui", event: "timeout") }
                }
                self.textInserter?.cancelStreamingInsertion()
                AppState.shared.recordingState = .idle
                self.hideRecordingPanel()
                self.clearDeferredPolishState()
            }
        }
    }

    private func clearDeferredPolishState() {
        deferredPolishCloseTask?.cancel()
        deferredPolishCloseTask = nil
        isAwaitingDeferredPolish = false
        pendingDeferredPolishText = nil
        pendingDeferredPolishTraceId = nil
        activeDeferredPolishTraceId = nil
        voiceInputService?.markDeferredPolishConsumed()
        lastFinalizeTextForPolish = ""
        isStreamingInsertionSessionActive = false
        didUseStreamingKeyboardFallback = false
        lastStreamingUpdateMethod = nil
        lastStreamingSanitizedText = ""
    }

    private func storeAutoEditUndoSnapshot(finalized: String, polished: String, traceId: String?) {
        let finalizedTrimmed = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let polishedTrimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalizedTrimmed.isEmpty,
              !polishedTrimmed.isEmpty,
              finalizedTrimmed != polishedTrimmed else { return }
        lastAutoEditUndoSnapshot = AutoEditUndoSnapshot(
            finalizedText: finalizedTrimmed,
            polishedText: polishedTrimmed,
            traceId: traceId,
            createdAt: Date()
        )
        AppState.shared.canUndoLastAutoEdit = true
    }

    private func clearAutoEditUndoSnapshot() {
        lastAutoEditUndoSnapshot = nil
        AppState.shared.canUndoLastAutoEdit = false
    }

    private func confirmDeferredPolishReplacement(finalized: String, polished: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Apply Auto Edit changes?"
        let beforePreview = String(finalized.prefix(90))
        let afterPreview = String(polished.prefix(90))
        alert.informativeText = "Before: \(beforePreview)\nAfter: \(afterPreview)"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Keep Finalize")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func undoLastAutoEdit() async {
        guard let snapshot = lastAutoEditUndoSnapshot else {
            diagnostics.log("AutoEdit undo skipped: no snapshot")
            AppState.shared.canUndoLastAutoEdit = false
            return
        }

        guard Date().timeIntervalSince(snapshot.createdAt) <= 180 else {
            diagnostics.log("AutoEdit undo expired")
            clearAutoEditUndoSnapshot()
            return
        }

        guard let textInserter else {
            diagnostics.log("AutoEdit undo unavailable: no text inserter")
            return
        }

        await reactivateInsertionTarget()
        switch textInserter.undoKeyboardReplacement(from: snapshot.polishedText, to: snapshot.finalizedText) {
        case .updated(let method, let characterCount):
            diagnostics.log("AutoEdit undo applied via \(method) (\(characterCount) chars)")
            if let traceId = snapshot.traceId {
                await RecordingStore.shared.appendAuditEvent(
                    traceId: traceId,
                    stage: "autoedit_ui",
                    event: "undo",
                    changed: true,
                    message: "\(method) chars=\(characterCount)"
                )
            }
            clearAutoEditUndoSnapshot()
        case .failed(let failure):
            diagnostics.log("AutoEdit undo failed [\(failure.category.rawValue)] \(failure.details)")
            if let traceId = snapshot.traceId {
                await RecordingStore.shared.appendAuditEvent(
                    traceId: traceId,
                    stage: "autoedit_ui",
                    event: "undo_failed",
                    message: "\(failure.category.rawValue) \(failure.details)"
                )
            }
        }
    }

    @MainActor
    private func consumePendingDeferredPolishIfNeeded() async {
        guard isAwaitingDeferredPolish else { return }
        guard let pending = pendingDeferredPolishText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pending.isEmpty else { return }
        let pendingTraceId = pendingDeferredPolishTraceId
        pendingDeferredPolishText = nil
        pendingDeferredPolishTraceId = nil
        diagnostics.log("Stage[polish] consumed_buffered_result")
        await handleDeferredPolishUpdate(pending, traceId: pendingTraceId)
    }

    private func sanitizeLiveStreamingInsertionText(_ text: String, previousText: String) -> String {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return "" }

        let dedupedSelf = collapseDuplicateLeadingRuns(incoming)
        let dedupedAnchored = collapseRepeatedPrefix(around: previousText, candidate: dedupedSelf)
        return dedupedAnchored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collapseRepeatedPrefix(around baseText: String, candidate text: String) -> String {
        let base = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !candidate.isEmpty else { return candidate }
        guard candidate.hasPrefix(base), candidate != base else { return candidate }

        var remaining = candidate
        var runCount = 0
        while remaining.hasPrefix(base) {
            remaining = String(remaining.dropFirst(base.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            runCount += 1
            if remaining.isEmpty { break }
        }

        guard runCount >= 2 else { return candidate }
        if remaining.isEmpty { return base }
        if shouldInsertSpaceBetween(base, remaining) {
            return "\(base) \(remaining)"
        }
        return base + remaining
    }

    private func collapseDuplicateLeadingRuns(_ text: String) -> String {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return incoming }

        let tokens = incoming.split { $0.isWhitespace || $0.isNewline }
        if tokens.count >= 2 {
            for unitLength in stride(from: tokens.count / 2, through: 1, by: -1) {
                let unit = Array(tokens.prefix(unitLength))
                var cursor = unitLength
                var runs = 1
                while cursor + unitLength <= tokens.count,
                      Array(tokens[cursor..<(cursor + unitLength)]) == unit {
                    runs += 1
                    cursor += unitLength
                }
                if runs >= 2 {
                    let unitText = unit.joined(separator: " ")
                    let tail = tokens.dropFirst(unitLength * runs).joined(separator: " ")
                    if tail.isEmpty { return unitText }
                    return "\(unitText) \(tail)"
                }
            }
        }

        let chars = Array(incoming)
        let maxUnitLength = chars.count / 2
        guard maxUnitLength > 0 else { return incoming }
        for unitLength in stride(from: maxUnitLength, through: 1, by: -1) {
            let unit = Array(chars[0..<unitLength])
            var cursor = unitLength
            var runs = 1
            while cursor + unitLength <= chars.count,
                  Array(chars[cursor..<(cursor + unitLength)]) == unit {
                runs += 1
                cursor += unitLength
            }
            if runs >= 2 {
                let unitText = String(unit)
                let tail = String(chars.dropFirst(unitLength * runs)).trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty { return unitText }
                if shouldInsertSpaceBetween(unitText, tail) {
                    return "\(unitText) \(tail)"
                }
                return unitText + tail
            }
        }
        return incoming
    }

    private func shouldInsertSpaceBetween(_ left: String, _ right: String) -> Bool {
        guard let leftLast = left.unicodeScalars.last,
              let rightFirst = right.unicodeScalars.first else { return false }
        let leftWord = CharacterSet.alphanumerics.contains(leftLast)
        let rightWord = CharacterSet.alphanumerics.contains(rightFirst)
        return leftWord && rightWord
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

    private func logStreamingInsertionFailure(_ stage: String, reason: TextInserter.StreamingInsertFailure) {
        diagnostics.log("Streaming insertion \(stage) failed [\(reason.category.rawValue)] \(reason.details)")
    }

    private func bestInsertionText(finalText: String, streamingText: String) -> String {
        let finalTrimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamingTrimmed = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !streamingTrimmed.isEmpty else {
            return finalTrimmed
        }

        if finalTrimmed.isEmpty {
            return streamingTrimmed
        }

        if shouldPreferStreamingPartial(finalText: finalTrimmed, partialText: streamingTrimmed) {
            return streamingTrimmed
        }

        if finalTrimmed.count + 6 < streamingTrimmed.count &&
            streamingTrimmed.count >= 12 {
            return streamingTrimmed
        }

        return finalTrimmed
    }

    private func shouldPreferStreamingPartial(finalText: String, partialText: String) -> Bool {
        let finalTrimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partialTrimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalTrimmed.isEmpty, !partialTrimmed.isEmpty else { return false }
        if finalTrimmed.count >= partialTrimmed.count { return false }
        if partialTrimmed.count >= 12 && finalTrimmed.count <= partialTrimmed.count - 6 { return true }
        if partialTrimmed.count >= 10 && finalTrimmed.count <= 3 { return true }
        if Double(finalTrimmed.count) <= Double(partialTrimmed.count) * 0.55 { return true }
        return false
    }

    private func reactivateInsertionTarget() async {
        if lastExternalApp == nil {
            captureInsertionTarget()
        }
        guard let app = lastExternalApp else { return }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
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

        let window = NSPanel(contentViewController: hostingController)
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position at bottom-center so the indicator stays close to where users type.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 224
            let windowHeight: CGFloat = 48
            let x = screenFrame.midX - windowWidth / 2
            let y = screenFrame.minY + 54
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
            .environmentObject(AppState.shared)
            .environmentObject(PermissionManager.shared)
            .environmentObject(settings)
            .environmentObject(DiagnosticsState.shared)
            .environmentObject(EchoAuthSession.shared)
            .environmentObject(CloudSyncService.shared)
            .environmentObject(BillingService.shared)
            .preferredColorScheme(.light)
            .environment(\.colorScheme, .light)
        let hostingController = NSHostingController(rootView: view)
        let lightAppearance = NSAppearance(named: .aqua)
        hostingController.view.appearance = lightAppearance

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
        window.appearance = lightAppearance

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
            .environmentObject(AppState.shared)
            .environmentObject(PermissionManager.shared)
            .environmentObject(settings)
            .environmentObject(DiagnosticsState.shared)
            .environmentObject(EchoAuthSession.shared)
            .environmentObject(CloudSyncService.shared)
            .environmentObject(BillingService.shared)
            .preferredColorScheme(.light)
            .environment(\.colorScheme, .light)
        let hostingController = NSHostingController(rootView: view)
        let lightAppearance = NSAppearance(named: .aqua)
        hostingController.view.appearance = lightAppearance

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Echo History"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 560), display: true)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = lightAppearance

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
        // With Dock enabled, keep Echo as a regular app so it can show windows.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restoreMenuBarOnlyIfNeeded() {
        // Keep Echo visible in Dock even when windows are closed.
        // This lets users click the Dock icon to reopen the Home window.
        return
    }

    // MARK: - Screenshot Automation

    private func runScreenshotAutomation() {
        showHomeWindow()
        showHistoryWindow()

        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: screenshotAutomationOutDir, withIntermediateDirectories: true)
            } catch {
                print("⚠️ Failed to create screenshot output dir: \(error)")
            }

            // Give SwiftUI time to render and layout.
            try? await Task.sleep(for: .milliseconds(900))

            if let window = homeWindow {
                capture(window: window, filename: "EchoMac-Home.png")
            }

            selectHomeSection(.history)
            try? await Task.sleep(for: .milliseconds(350))
            if let window = homeWindow {
                capture(window: window, filename: "EchoMac-Home-History.png")
            }

            selectHomeSection(.dictionary)
            try? await Task.sleep(for: .milliseconds(350))
            if let window = homeWindow {
                capture(window: window, filename: "EchoMac-Home-Dictionary.png")
            }

            if let window = historyWindow {
                capture(window: window, filename: "EchoMac-History.png")
            }

            print("📸 Screenshot automation complete: \(screenshotAutomationOutDir.path)")
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.terminate(nil)
        }
    }

    private func selectHomeSection(_ section: HomeSection) {
        NotificationCenter.default.post(
            name: .echoHomeSelectSection,
            object: nil,
            userInfo: ["section": section.rawValue]
        )
    }

    private func capture(window: NSWindow, filename: String) {
        let outURL = screenshotAutomationOutDir.appendingPathComponent(filename)
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution]
        ) else {
            print("⚠️ Failed to capture window: \(filename)")
            return
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("⚠️ Failed to encode screenshot: \(filename)")
            return
        }

        do {
            try data.write(to: outURL, options: [.atomic])
        } catch {
            print("⚠️ Failed to write screenshot: \(error)")
        }
    }
}

// MARK: - Recording Panel View

struct RecordingPillView: View {
    @ObservedObject var appState: AppState
    @State private var highlightPhase = false

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
                    Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.02),
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .blur(radius: 5)
                        .offset(x: highlightPhase ? 62 : -62)
                        .opacity(appState.recordingState == .listening || isProcessing ? 0.36 : 0.16)
                }
                .mask(Capsule())
                .shadow(color: Color.black.opacity(0.24), radius: 10, y: 4)

            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(width: 204, height: 34)
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                highlightPhase.toggle()
            }
        }
    }

    private var backgroundGradient: LinearGradient {
        switch appState.recordingState {
        case .listening:
            return LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.11, blue: 0.14),
                    Color(red: 0.08, green: 0.12, blue: 0.18)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .transcribing, .correcting, .inserting:
            return LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.10, blue: 0.12),
                    Color(red: 0.07, green: 0.07, blue: 0.09)
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
                    Color(red: 0.11, green: 0.11, blue: 0.13),
                    Color(red: 0.09, green: 0.09, blue: 0.11)
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
                ListeningPillContent(
                    levels: appState.audioLevels,
                    partialText: appState.partialTranscription,
                    isStreamingMode: appState.isStreamingModeActive
                )
            case .transcribing:
                StageLoadingContent(
                    title: appState.isStreamingModeActive ? "Finalize" : "Transcribing",
                    tint: Color(red: 0.39, green: 0.76, blue: 1.0)
                )
            case .correcting:
                StageLoadingContent(
                    title: "Polish",
                    tint: Color(red: 0.22, green: 0.88, blue: 0.73)
                )
            case .inserting:
                StageLoadingContent(
                    title: "Applying",
                    tint: Color(red: 0.98, green: 0.74, blue: 0.38)
                )
            case .error:
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Error")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
                .lineLimit(1)
                .foregroundStyle(Color.white.opacity(0.9))
            case .idle:
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Ready")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }
}

private struct StageLoadingContent: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            CapsuleLoader(tint: tint)
                .frame(width: 24, height: 10)

            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(1)

            Spacer(minLength: 4)

            Circle()
                .fill(tint.opacity(0.9))
                .frame(width: 5.5, height: 5.5)
                .shadow(color: tint.opacity(0.45), radius: 2, y: 0)
        }
    }
}

private struct CapsuleLoader: View {
    let tint: Color
    @State private var active = false

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.12))

            Capsule()
                .fill(tint.opacity(0.35))
                .frame(width: 10)
                .offset(x: active ? 12 : 2)

            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .offset(x: active ? 13 : 3)
                .shadow(color: tint.opacity(0.52), radius: 3, y: 0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                active.toggle()
            }
        }
    }
}

struct ListeningPillContent: View {

    let levels: [CGFloat]
    let partialText: String
    let isStreamingMode: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.96, green: 0.33, blue: 0.28))
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.22 : 0.82)
                .opacity(pulse ? 1 : 0.5)

            SymmetricBarsView(levels: levels, reverseWeights: false)
                .frame(width: 52, height: 12)

            Text(isStreamingMode ? "Recording" : displayText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }

    private var displayText: String {
        let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Listening" : trimmed
    }
}

struct SymmetricBarsView: View {

    let levels: [CGFloat]
    let reverseWeights: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = 12
                let barWidth: CGFloat = 1.8
                let spacing: CGFloat = 1.6
                let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let midY = size.height / 2
                let maxHeight = size.height

                let samples = normalizedLevels(count: count)
                let gradient = Gradient(colors: [Color.cyan.opacity(0.9), Color.blue.opacity(0.9)])

                for index in 0..<count {
                    let base = samples[index]
                    let progress = CGFloat(index) / CGFloat(max(1, count - 1))
                    let directionalWeight = reverseWeights ? (0.50 + 0.50 * (1 - progress)) : (0.50 + 0.50 * progress)
                    let centerWeight = centerEnvelope(progress: progress)
                    let phase = time * 4.1 + Double(index) * 0.82
                    let wave = 0.56 + 0.44 * ((sin(phase) + 1) / 2)
                    let intensity = pow(base, 0.58) * directionalWeight * centerWeight
                    let height = max(2.6, (0.14 + intensity * wave) * maxHeight)
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
            return trimmed.map { max(0.14, min($0 * 2.8, 1.0)) }
        }
        let padding = Array(repeating: CGFloat(0.14), count: count - trimmed.count)
        return padding + trimmed.map { max(0.14, min($0 * 2.8, 1.0)) }
    }

    private func centerEnvelope(progress: CGFloat) -> CGFloat {
        // Emphasize the center bars to mimic fluid capsule waveforms.
        let distance = abs(progress - 0.5) * 2.0
        return 0.52 + (1.0 - distance) * 0.62
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

    func refresh() {
        Task { await reload() }
    }

    private func reload() async {
        isLoading = true
        // Local-first: always show on-device history regardless of current auth identity.
        entries = await RecordingStore.shared.fetchRecent(limit: 300, userId: nil)
        storageInfo = await RecordingStore.shared.storageInfo()
        isLoading = false
    }
}

struct EchoHomeWindowView: View {
    @ObservedObject var settings: MacAppSettings
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var authSession: EchoAuthSession
    @EnvironmentObject var cloudSync: CloudSyncService
    @EnvironmentObject var billing: BillingService
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
            model.refresh()
            retentionOption = HistoryRetention.from(days: settings.historyRetentionDays)
            Task { await billing.refresh() }
        }
        .onChange(of: retentionOption) { _, newValue in
            settings.historyRetentionDays = newValue.days
        }
        .onReceive(NotificationCenter.default.publisher(for: .echoRecordingSaved)) { _ in
            model.refresh()
        }
        .onChange(of: settings.currentUserId) { _, _ in
            model.refresh()
        }
        .onChange(of: authSession.userId) { _, _ in
            model.refresh()
            Task { await billing.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .echoHomeSelectSection)) { note in
            guard let raw = note.userInfo?["section"] as? String,
                  let next = HomeSection(rawValue: raw) else {
                return
            }
            selectedSection = next
        }
        // The Home UI uses a Typeless-style light theme with explicit light backgrounds.
        // Force light mode so `.primary` stays readable even if macOS is in Dark Mode.
        .preferredColorScheme(.light)
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
                    displayName: authSession.displayName,
                    planTier: billing.snapshot?.tier,
                    billingStatus: billing.status
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
    let planTier: String?
    let billingStatus: BillingService.Status

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

            if isSignedIn {
                Text("Plan: \((planTier ?? "free").uppercased())")
                    .font(.caption)
                    .foregroundStyle(planTier == "pro" ? .green : .secondary)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            switch billingStatus {
            case .loading:
                Text("Checking subscription...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Text("Plan status error: \(message)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            default:
                EmptyView()
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
    static let echoUndoLastAutoEdit = Notification.Name("echo.undoLastAutoEdit")
    static let echoRecordingSaved = Notification.Name("echo.recordingSaved")
    static let echoHomeSelectSection = Notification.Name("echo.homeSelectSection")
}
