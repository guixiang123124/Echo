import SwiftUI
import UIKit
import TypelessCore
import TypelessUI

/// Main keyboard view that switches between different layouts
struct KeyboardView: View {
    @ObservedObject var state: KeyboardState
    let textDocumentProxy: UITextDocumentProxy
    let onNextKeyboard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Candidate bar (for Pinyin mode)
            if state.inputMode == .pinyin && !state.pinyinCandidates.isEmpty {
                CandidateBarView(
                    candidates: state.pinyinCandidates,
                    pinyinInput: state.pinyinInput,
                    onSelect: { index in
                        selectCandidate(at: index)
                    }
                )
            }

            // Keyboard layout
            keyboardContent
                .padding(.horizontal, 3)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
        }
        .frame(height: keyboardHeight)
    }

    @ViewBuilder
    private var keyboardContent: some View {
        switch state.inputMode {
        case .english:
            QWERTYKeyboardView(
                shiftState: state.shiftState,
                onKeyPress: handleKeyAction
            )
        case .pinyin:
            PinyinKeyboardView(
                shiftState: state.shiftState,
                onKeyPress: handleKeyAction
            )
        case .numbers:
            NumberKeyboardView(onKeyPress: handleKeyAction)
        case .symbols:
            SymbolKeyboardView(onKeyPress: handleKeyAction)
        }
    }

    private var keyboardHeight: CGFloat {
        let hasCandidates = state.inputMode == .pinyin && !state.pinyinCandidates.isEmpty
        return hasCandidates ? 300 : 260
    }

    private func handleKeyAction(_ action: KeyboardAction) {
        let operation = state.actionHandler.handle(
            action: action,
            currentMode: state.inputMode,
            shiftState: state.shiftState
        )

        let hapticEnabled = state.settings.hapticFeedbackEnabled

        switch operation {
        case .insertText(let text):
            if state.inputMode == .pinyin && text.allSatisfy(\.isLetter) {
                handlePinyinInput(text)
            } else {
                // If there's pending pinyin, commit it first
                commitPendingPinyin()
                textDocumentProxy.insertText(text)
            }
            if hapticEnabled { state.haptic.keyTap() }

            // Auto-lowercase after typing a character
            if state.shiftState == .uppercased {
                state.shiftState = .lowercased
            }

        case .deleteBackward:
            if state.inputMode == .pinyin && !state.pinyinInput.isEmpty {
                handlePinyinDelete()
            } else {
                textDocumentProxy.deleteBackward()
            }
            if hapticEnabled { state.haptic.keyTap() }

        case .changeMode(let mode):
            commitPendingPinyin()
            state.inputMode = mode
            if hapticEnabled { state.haptic.specialKeyTap() }

        case .changeShift(let newState):
            state.shiftState = newState
            if hapticEnabled { state.haptic.specialKeyTap() }

        case .triggerVoiceInput:
            if hapticEnabled { state.haptic.specialKeyTap() }
            VoiceInputTrigger.openMainAppForVoice(from: state.viewController)

        case .triggerEmoji:
            if hapticEnabled { state.haptic.specialKeyTap() }

        case .nextKeyboard:
            onNextKeyboard()

        case .dismissKeyboard:
            break
        }
    }

    // MARK: - Pinyin Input

    private func handlePinyinInput(_ char: String) {
        Task {
            let candidates = await state.pinyinEngine.appendCharacter(char)
            await MainActor.run {
                state.pinyinInput = char // Will be accumulated by engine
                state.pinyinCandidates = candidates
            }
            let currentInput = await state.pinyinEngine.currentInput
            await MainActor.run {
                state.pinyinInput = currentInput
            }
        }
    }

    private func handlePinyinDelete() {
        Task {
            let candidates = await state.pinyinEngine.deleteLastCharacter()
            let currentInput = await state.pinyinEngine.currentInput
            await MainActor.run {
                state.pinyinInput = currentInput
                state.pinyinCandidates = candidates
            }
        }
    }

    private func selectCandidate(at index: Int) {
        Task {
            if let text = await state.pinyinEngine.selectCandidate(at: index) {
                await MainActor.run {
                    textDocumentProxy.insertText(text)
                    state.pinyinInput = ""
                    state.pinyinCandidates = []
                }
            }
        }
    }

    private func commitPendingPinyin() {
        guard !state.pinyinInput.isEmpty else { return }
        textDocumentProxy.insertText(state.pinyinInput)
        Task {
            await state.pinyinEngine.clear()
        }
        state.pinyinInput = ""
        state.pinyinCandidates = []
    }
}
