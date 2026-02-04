import Foundation

/// Represents a key on the keyboard
public struct KeyboardKey: Sendable, Equatable, Identifiable {
    public let id: String
    public let action: KeyboardAction
    public let label: String
    public let width: KeyWidth

    public init(
        id: String? = nil,
        action: KeyboardAction,
        label: String,
        width: KeyWidth = .regular
    ) {
        self.id = id ?? "\(action)-\(label)"
        self.action = action
        self.label = label
        self.width = width
    }
}

/// Actions that a keyboard key can trigger
public enum KeyboardAction: Sendable, Equatable {
    case character(String)
    case backspace
    case enter
    case space
    case shift
    case switchLanguage
    case switchToNumbers
    case switchToSymbols
    case switchToLetters
    case voice
    case emoji
    case globe
    case dismiss
    case tab
}

/// Relative width of a keyboard key
public enum KeyWidth: Sendable, Equatable {
    case regular       // 1x standard width
    case wide          // 1.5x
    case extraWide     // 2x
    case spacebar      // Flexible, fills remaining space
    case custom(Double)

    public var multiplier: Double {
        switch self {
        case .regular: return 1.0
        case .wide: return 1.5
        case .extraWide: return 2.0
        case .spacebar: return 5.0
        case .custom(let value): return value
        }
    }
}

/// The current input mode of the keyboard
public enum KeyboardInputMode: Sendable, Equatable {
    case english
    case pinyin
    case numbers
    case symbols
}

/// Shift state of the keyboard
public enum ShiftState: Sendable, Equatable {
    case lowercased
    case uppercased
    case capsLocked
}
