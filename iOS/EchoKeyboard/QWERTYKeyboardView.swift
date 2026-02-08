import SwiftUI
import EchoCore
import EchoUI

/// English QWERTY keyboard layout
struct QWERTYKeyboardView: View {
    let shiftState: ShiftState
    let onKeyPress: (KeyboardAction) -> Void

    var body: some View {
        let rows = KeyboardLayout.qwertyRows(shift: shiftState)

        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
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
        case .regular: return nil // Fill equally
        case .wide: return 50
        case .extraWide: return 70
        case .spacebar: return .infinity
        case .custom(let mult): return CGFloat(mult * 36)
        }
    }
}
