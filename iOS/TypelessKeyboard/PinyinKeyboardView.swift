import SwiftUI
import TypelessCore
import TypelessUI

/// Chinese Pinyin keyboard layout
struct PinyinKeyboardView: View {
    let shiftState: ShiftState
    let onKeyPress: (KeyboardAction) -> Void

    var body: some View {
        let rows = KeyboardLayout.pinyinRows(shift: shiftState)

        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { key in
                        KeyboardKeyView(key: key, onPress: onKeyPress)
                            .frame(maxWidth: maxWidth(for: key))
                    }
                }
            }
        }
    }

    private func maxWidth(for key: KeyboardKey) -> CGFloat? {
        switch key.width {
        case .regular: return nil
        case .wide: return 50
        case .extraWide: return 70
        case .spacebar: return .infinity
        case .custom(let mult): return CGFloat(mult * 36)
        }
    }
}

/// Number keyboard layout
struct NumberKeyboardView: View {
    let onKeyPress: (KeyboardAction) -> Void

    var body: some View {
        let rows = KeyboardLayout.numberRows()

        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { key in
                        KeyboardKeyView(key: key, onPress: onKeyPress)
                    }
                }
            }
        }
    }
}

/// Symbol keyboard layout
struct SymbolKeyboardView: View {
    let onKeyPress: (KeyboardAction) -> Void

    var body: some View {
        let rows = KeyboardLayout.symbolRows()

        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { key in
                        KeyboardKeyView(key: key, onPress: onKeyPress)
                    }
                }
            }
        }
    }
}
