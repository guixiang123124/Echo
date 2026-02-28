import UIKit
import SwiftUI
import EchoCore

/// Main keyboard extension view controller
class KeyboardViewController: UIInputViewController {
   private var hostingController: UIHostingController<KeyboardView>?
   private let keyboardState = KeyboardState()
   private var transcriptionPollTimer: Timer?
   private var dictationNotificationTokens: [DarwinNotificationCenter.ObservationToken] = []
   private var lastStreamingSequence: Int = 0
   private var activeStreamingSessionId: String = ""
   private var lastStreamingText: String = ""
   private var lastFinalStreamingText: String = ""
   private var lastFinalStreamingAt: Date = .distantPast

   override func viewDidLoad() {
       super.viewDidLoad()
       print("[EchoKeyboard] viewDidLoad")

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

       // Set the view controller reference for opening URLs
       keyboardState.viewController = self
       print("[EchoKeyboard] viewController set, hasFullAccess: \(keyboardState.hasFullAccess), hasSharedContainer: \(AppGroupBridge.hasSharedContainerAccess)")

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
       print("[EchoKeyboard] viewWillAppear, hasFullAccess: \(keyboardState.hasFullAccess), hasSharedContainer: \(AppGroupBridge.hasSharedContainerAccess)")
       checkForPendingTranscription()
       startTranscriptionPolling()
       startDictationObservers()
   }

   override func viewWillDisappear(_ animated: Bool) {
       super.viewWillDisappear(animated)
       stopTranscriptionPolling()
       stopDictationObservers()
   }

   override func textDidChange(_ textInput: UITextInput?) {
       super.textDidChange(textInput)
       checkForPendingTranscription()
   }

   /// Check if the main app has returned a voice transcription
   private func checkForPendingTranscription() {
       let bridge = AppGroupBridge()

       if consumeStreamingPartial(from: bridge) {
           return
       }

       if let transcription = bridge.receivePendingTranscription() {
           let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
           guard !trimmed.isEmpty else { return }

           // Avoid duplicate insertion when stream final also writes legacy pending text.
           if Date().timeIntervalSince(lastFinalStreamingAt) <= 3,
              !lastFinalStreamingText.isEmpty,
              trimmed == lastFinalStreamingText {
               return
           }
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

   private func startDictationObservers() {
       stopDictationObservers()
       let darwin = DarwinNotificationCenter.shared

       dictationNotificationTokens.append(
           darwin.observe(.transcriptionReady) { [weak self] in
               DispatchQueue.main.async { [weak self] in
                   self?.checkForPendingTranscription()
               }
           }
       )

       dictationNotificationTokens.append(
           darwin.observe(.stateChanged) { [weak self] in
               DispatchQueue.main.async { [weak self] in
                   self?.keyboardState.syncVoiceState()
               }
           }
       )

       dictationNotificationTokens.append(
           darwin.observe(.heartbeat) { [weak self] in
               DispatchQueue.main.async { [weak self] in
                   self?.keyboardState.syncVoiceState()
               }
           }
       )
   }

   private func stopDictationObservers() {
       dictationNotificationTokens.forEach { token in
           DarwinNotificationCenter.shared.removeObservation(token)
       }
       dictationNotificationTokens.removeAll()
   }

   private func consumeStreamingPartial(from bridge: AppGroupBridge) -> Bool {
       guard let partial = bridge.readStreamingPartial() else {
           return false
       }

       guard !partial.sessionId.isEmpty else {
           return false
       }

       if partial.sessionId != activeStreamingSessionId {
           activeStreamingSessionId = partial.sessionId
           lastStreamingSequence = 0
           lastStreamingText = ""
       }

       if partial.sequence <= lastStreamingSequence {
           return false
       }
       lastStreamingSequence = partial.sequence

       let trimmed = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
       guard !trimmed.isEmpty else {
           if partial.isFinal {
               lastFinalStreamingText = ""
               lastFinalStreamingAt = Date()
               bridge.clearStreamingData()
           }
           return false
       }

       replaceTextInInput(trimmed)

       if partial.isFinal {
           lastFinalStreamingText = trimmed
           lastFinalStreamingAt = Date()
           bridge.clearStreamingData()
       }

       return true
   }

   private func replaceTextInInput(_ text: String) {
       if !lastStreamingText.isEmpty {
           for _ in 0..<lastStreamingText.count {
               textDocumentProxy.deleteBackward()
           }
       }
       textDocumentProxy.insertText(text)
       lastStreamingText = text
   }

   deinit {
       stopTranscriptionPolling()
       stopDictationObservers()
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
   /// Whether background dictation is alive (heartbeat within 6s)
   @Published var isBackgroundDictationAlive: Bool = false

   let pinyinEngine = PinyinEngine()
   let actionHandler = KeyboardActionHandler()
   let haptic = HapticFeedbackGenerator()
   let settings = AppSettings()

   /// Reference to the view controller for opening URLs
   weak var viewController: UIViewController?
   private var toastTask: Task<Void, Never>?
   private var voiceStateTimer: Timer?

   init() {
       let savedMode = settings.defaultInputMode
       inputMode = savedMode == "pinyin" ? .pinyin : .english
       startVoiceStatePolling()
   }

   /// Start polling for voice state from main app
   private func startVoiceStatePolling() {
       voiceStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
           Task { @MainActor [weak self] in
               self?.syncVoiceState()
           }
       }
   }

   /// Sync voice recording state from AppGroupBridge
   func syncVoiceState() {
       let bridge = AppGroupBridge()
       if let dictationState = bridge.readDictationState() {
           isVoiceRecording = switch dictationState.state {
           case .recording, .transcribing, .finalizing:
               true
           case .idle, .error:
               false
           }
       } else {
           isVoiceRecording = bridge.isRecording
       }
       isBackgroundDictationAlive = bridge.hasRecentHeartbeat(maxAge: 6)
   }

   deinit {
       voiceStateTimer?.invalidate()
   }

   var hasFullAccess: Bool {
       let access = (viewController as? UIInputViewController)?.hasFullAccess ?? false
       print("[KeyboardState] hasFullAccess check: viewController exists = \(viewController != nil), access = \(access)")
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
