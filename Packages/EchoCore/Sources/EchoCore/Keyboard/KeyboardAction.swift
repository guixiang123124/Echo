import Foundation

/// Handles keyboard action processing and text manipulation
public struct KeyboardActionHandler: Sendable {
    public init() {}

    /// Process a keyboard action and return the text operation to perform
    public func handle(
        action: KeyboardAction,
        currentMode: KeyboardInputMode,
        shiftState: ShiftState
    ) -> KeyboardOperation {
        switch action {
        case .character(let char):
            return .insertText(char)

        case .backspace:
            return .deleteBackward

        case .enter:
            return .insertText("\n")

        case .space:
            return .insertText(" ")

        case .shift:
            let newState: ShiftState
            switch shiftState {
            case .lowercased: newState = .uppercased
            case .uppercased: newState = .lowercased
            case .capsLocked: newState = .lowercased
            }
            return .changeShift(newState)

        case .switchLanguage:
            let newMode: KeyboardInputMode
            switch currentMode {
            case .english: newMode = .pinyin
            case .pinyin: newMode = .english
            case .numbers: newMode = .english
            case .symbols: newMode = .english
            }
            return .changeMode(newMode)

        case .switchToNumbers:
            return .changeMode(.numbers)

        case .switchToSymbols:
            return .changeMode(.symbols)

        case .switchToLetters:
            return .changeMode(currentMode == .pinyin ? .pinyin : .english)

        case .voice:
            return .triggerVoiceInput

        case .emoji:
            return .triggerEmoji

        case .globe:
            return .nextKeyboard

        case .dismiss:
            return .dismissKeyboard

        case .tab:
            return .insertText("\t")
        }
    }
}

/// Operations the keyboard can perform
public enum KeyboardOperation: Sendable, Equatable {
    case insertText(String)
    case deleteBackward
    case changeMode(KeyboardInputMode)
    case changeShift(ShiftState)
    case triggerVoiceInput
    case triggerEmoji
    case nextKeyboard
    case dismissKeyboard
}
