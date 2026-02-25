import SwiftUI
import UIKit
import EchoCore
import EchoUI

/// Main keyboard view that switches between different layouts
struct KeyboardView: View {
    @ObservedObject var state: KeyboardState
    let textDocumentProxy: UITextDocumentProxy
    let onNextKeyboard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            KeyboardTopBar(
                onOpenSettings: {
                    openMainAppSettings()
                },
                onTriggerVoice: {
                    openMainAppVoice()
                },
                onCollapse: {
                    (state.viewController as? UIInputViewController)?.dismissKeyboard()
                }
            )

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
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(EchoTheme.keyboardBackground)
        }
        .frame(height: keyboardHeight)
        .background(EchoTheme.keyboardBackground)
        .overlay(alignment: .top) {
            if state.toastVisible, let message = state.toastMessage {
                KeyboardToast(message: message)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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
        let base: CGFloat = hasCandidates ? 300 : 260
        return base + 44
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
            openMainAppVoice()

        case .triggerEmoji:
            if hapticEnabled { state.haptic.specialKeyTap() }

        case .nextKeyboard:
            onNextKeyboard()

        case .dismissKeyboard:
            (state.viewController as? UIInputViewController)?.dismissKeyboard()
        }
    }

    private func openMainAppVoice() {
        guard state.hasFullAccess else {
            state.showToast("Enable Allow Full Access for Voice + AI")
            return
        }

        VoiceInputTrigger.openMainAppForVoice(from: state.viewController) { success in
            if !success {
                state.showToast("Couldn't open Echo. Open the app and try again.")
            }
        }
    }

    private func openMainAppSettings() {
        guard state.hasFullAccess else {
            state.showToast("Enable Allow Full Access to open Echo settings")
            return
        }

        VoiceInputTrigger.openMainAppForSettings(from: state.viewController) { success in
            if !success {
                state.showToast("Couldn't open Echo. Open the app and try again.")
            }
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

// MARK: - Top Bar

private struct KeyboardTopBar: View {
    let onOpenSettings: () -> Void
    let onTriggerVoice: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Settings - onTapGesture required for keyboard extension compatibility
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(EchoTheme.keySecondaryBackground)
                )
                .contentShape(Circle())
                .onTapGesture { onOpenSettings() }

            Spacer()

            // Voice pill - onTapGesture required for keyboard extension compatibility
            EchoDictationPill(
                isRecording: false,
                isProcessing: false,
                levels: [],
                tipText: nil,
                width: 150,
                height: 30
            )
            .contentShape(Rectangle())
            .onTapGesture { onTriggerVoice() }

            Spacer()

            // Collapse - onTapGesture required for keyboard extension compatibility
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(EchoTheme.keySecondaryBackground)
                )
                .contentShape(Circle())
                .onTapGesture { onCollapse() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(EchoTheme.keyboardSurface)
    }
}

private struct KeyboardToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, y: 6)
            .padding(.horizontal, 10)
    }
}
