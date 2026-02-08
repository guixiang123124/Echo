import UIKit
import SwiftUI
import EchoCore

/// Main keyboard extension view controller
class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private let keyboardState = KeyboardState()
    private var lastInsertedTranscription: String?

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

        // Set the view controller reference for opening URLs
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
            guard trimmed != lastInsertedTranscription else { return }
            lastInsertedTranscription = trimmed
            textDocumentProxy.insertText(trimmed)
        }
    }
}

/// Observable state for the keyboard
@MainActor
class KeyboardState: ObservableObject {
    @Published var inputMode: KeyboardInputMode = .english
    @Published var shiftState: ShiftState = .lowercased
    @Published var pinyinCandidates: [PinyinCandidate] = []
    @Published var pinyinInput: String = ""

    let pinyinEngine = PinyinEngine()
    let actionHandler = KeyboardActionHandler()
    let haptic = HapticFeedbackGenerator()
    let settings = AppSettings()

    /// Reference to the view controller for opening URLs
    weak var viewController: UIViewController?

    init() {
        let savedMode = settings.defaultInputMode
        inputMode = savedMode == "pinyin" ? .pinyin : .english
    }
}
