import UIKit
import SwiftUI
import EchoCore

/// Main keyboard extension view controller
class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private let keyboardState = KeyboardState()
    private var transcriptionPollTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()

        let keyboardView = KeyboardView(
            state: keyboardState,
            textDocumentProxy: textDocumentProxy,
            onNextKeyboard: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )

        let hostingController = UIHostingController(rootView: keyboardView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        keyboardState.viewController = self

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        self.hostingController = hostingController
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkForPendingTranscription()
        startTranscriptionPolling()
        keyboardState.startDarwinObservation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopTranscriptionPolling()
        keyboardState.stopDarwinObservation()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        checkForPendingTranscription()
    }

    /// Check if the main app has returned a voice transcription
    private func checkForPendingTranscription() {
        let bridge = AppGroupBridge()
        if let transcription = bridge.receivePendingTranscription() {
            let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            textDocumentProxy.insertText(trimmed)
        }
    }

    private func startTranscriptionPolling() {
        guard transcriptionPollTimer == nil else { return }
        transcriptionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForPendingTranscription()
        }
    }

    private func stopTranscriptionPolling() {
        transcriptionPollTimer?.invalidate()
        transcriptionPollTimer = nil
    }

    deinit {
        stopTranscriptionPolling()
    }
}

/// Observable state for the keyboard
@MainActor
class KeyboardState: ObservableObject {
    @Published var inputMode: KeyboardInputMode = .english
    @Published var shiftState: ShiftState = .lowercased
    @Published var pinyinCandidates: [PinyinCandidate] = []
    @Published var pinyinInput: String = ""
    @Published var toastMessage: String?
    @Published var toastVisible: Bool = false
    /// Voice recording state - synced from main app via AppGroupBridge
    @Published var isVoiceRecording: Bool = false

    // Background dictation remote state
    @Published var isBackgroundDictationAlive: Bool = false
    @Published var isRemoteRecording: Bool = false
    @Published var isRemoteTranscribing: Bool = false
    @Published var remotePartialText: String = ""

    let pinyinEngine = PinyinEngine()
    let actionHandler = KeyboardActionHandler()
    let haptic = HapticFeedbackGenerator()
    let settings = AppSettings()

    /// Reference to the view controller for opening URLs
    weak var viewController: UIViewController?
    private var toastTask: Task<Void, Never>?
    private var voiceStateTimer: Timer?
    private var heartbeatCheckTimer: Timer?

    // Darwin observation tokens
    private var transcriptionReadyToken: DarwinNotificationCenter.ObservationToken?
    private var heartbeatToken: DarwinNotificationCenter.ObservationToken?
    private var stateChangedToken: DarwinNotificationCenter.ObservationToken?

    // Streaming partial tracking
    private var lastInsertedSequence: Int = 0
    private var lastInsertedText: String = ""
    private var lastSessionId: String = ""

    init() {
        let savedMode = settings.defaultInputMode
        inputMode = savedMode == "pinyin" ? .pinyin : .english
        startVoiceStatePolling()
    }

    // MARK: - Darwin Observation

    func startDarwinObservation() {
        // Idempotent: skip if already observing
        guard transcriptionReadyToken == nil else { return }

        let darwin = DarwinNotificationCenter.shared

        transcriptionReadyToken = darwin.observe(.transcriptionReady) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleStreamingPartialReady()
            }
        }

        heartbeatToken = darwin.observe(.heartbeat) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshBackgroundDictationAlive()
            }
        }

        stateChangedToken = darwin.observe(.stateChanged) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshBackgroundDictationState()
            }
        }

        // Periodic heartbeat check (3s interval, 6s tolerance)
        heartbeatCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshBackgroundDictationAlive()
            }
        }

        // Initial state check
        refreshBackgroundDictationAlive()
        refreshBackgroundDictationState()
    }

    func stopDarwinObservation() {
        let darwin = DarwinNotificationCenter.shared
        if let token = transcriptionReadyToken { darwin.removeObservation(token) }
        if let token = heartbeatToken { darwin.removeObservation(token) }
        if let token = stateChangedToken { darwin.removeObservation(token) }
        transcriptionReadyToken = nil
        heartbeatToken = nil
        stateChangedToken = nil

        heartbeatCheckTimer?.invalidate()
        heartbeatCheckTimer = nil
    }

    // MARK: - Streaming Partial Handling

    /// Read streaming partial from bridge, delete old text, insert new text.
    private func handleStreamingPartialReady() {
        let bridge = AppGroupBridge()
        guard let partial = bridge.readStreamingPartial() else { return }

        // Ignore stale sessions
        if !lastSessionId.isEmpty && partial.sessionId != lastSessionId {
            // New session — reset tracking
            lastInsertedSequence = 0
            lastInsertedText = ""
        }
        lastSessionId = partial.sessionId

        // Only process newer sequences
        guard partial.sequence > lastInsertedSequence else { return }

        // Delete-and-replace strategy (like Gboard):
        // Delete the previously inserted text, then insert the new text.
        guard let proxy = (viewController as? UIInputViewController)?.textDocumentProxy else { return }

        if !lastInsertedText.isEmpty {
            // Use utf16.count: deleteBackward() removes one UTF-16 unit at a time
            for _ in 0..<lastInsertedText.utf16.count {
                proxy.deleteBackward()
            }
        }

        let text = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            proxy.insertText(text)
        }

        lastInsertedSequence = partial.sequence
        lastInsertedText = text
        remotePartialText = text

        if partial.isFinal {
            // Final text inserted — reset tracking for next session
            lastInsertedSequence = 0
            lastInsertedText = ""
            lastSessionId = ""
            remotePartialText = ""
        }
    }

    // MARK: - Background Dictation State

    private func refreshBackgroundDictationAlive() {
        let bridge = AppGroupBridge()
        isBackgroundDictationAlive = bridge.hasRecentHeartbeat(maxAge: 6)
    }

    private func refreshBackgroundDictationState() {
        let bridge = AppGroupBridge()
        guard let (state, _) = bridge.readDictationState() else {
            isRemoteRecording = false
            isRemoteTranscribing = false
            return
        }

        switch state {
        case .recording:
            isRemoteRecording = true
            isRemoteTranscribing = false
        case .transcribing, .finalizing:
            isRemoteRecording = false
            isRemoteTranscribing = true
        case .idle, .error:
            isRemoteRecording = false
            isRemoteTranscribing = false
        }
    }

    // MARK: - Voice State Polling

    private func startVoiceStatePolling() {
        voiceStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncVoiceState()
            }
        }
    }

    private func syncVoiceState() {
        let bridge = AppGroupBridge()
        isVoiceRecording = bridge.isRecording
    }

    deinit {
        voiceStateTimer?.invalidate()
        heartbeatCheckTimer?.invalidate()
    }

    var hasFullAccess: Bool {
        let access = (viewController as? UIInputViewController)?.hasFullAccess ?? false
        return access
    }

    var hasOperationalFullAccess: Bool {
        hasFullAccess
    }

    var fullAccessGuidance: String {
        if !hasFullAccess {
            return "Enable Allow Full Access in iOS Keyboard settings"
        }
        if !AppGroupBridge.hasSharedContainerAccess {
            return "Shared keyboard access unavailable. Reopen Echo Keyboard once."
        }
        return "Ready to open Echo"
    }

    func showToast(_ message: String, duration: TimeInterval = 1.8) {
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.15)) {
                toastMessage = message
                toastVisible = true
            }

            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            withAnimation(.easeIn(duration: 0.15)) {
                toastVisible = false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            toastMessage = nil
        }
    }
}
