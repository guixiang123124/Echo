import SwiftUI
import Foundation
import EchoCore

/// View for a single keyboard key
public struct KeyboardKeyView: View {
    public let key: KeyboardKey
    public let onPress: (KeyboardAction) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPressed = false
    @State private var didLongPress = false

    public init(key: KeyboardKey, onPress: @escaping (KeyboardAction) -> Void) {
        self.key = key
        self.onPress = onPress
    }

    public var body: some View {
        if key.action == .space {
            Button {
                if !didLongPress {
                    onPress(key.action)
                }
            } label: {
                keyContent
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(backgroundColor)
                    .cornerRadius(10)
                    .shadow(color: EchoTheme.keyShadow, radius: 0, y: 1)
            }
            .buttonStyle(KeyPressButtonStyle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in
                        didLongPress = true
                        onPress(.voice)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            didLongPress = false
                        }
                    }
            )
        } else {
            Button {
                onPress(key.action)
            } label: {
                keyContent
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(backgroundColor)
                    .cornerRadius(10)
                    .shadow(color: EchoTheme.keyShadow, radius: 0, y: 1)
            }
            .buttonStyle(KeyPressButtonStyle())
        }
    }

    @ViewBuilder
    private var keyContent: some View {
        switch key.action {
        case .backspace:
            Image(systemName: "delete.left")
                .font(.system(size: 18))
                .foregroundColor(foregroundColor)

        case .shift:
            Image(systemName: "shift")
                .font(.system(size: 18))
                .foregroundColor(foregroundColor)

        case .enter:
            Image(systemName: "return")
                .font(.system(size: 18))
                .foregroundColor(foregroundColor)

        case .voice:
            Image(systemName: "mic.fill")
                .font(.system(size: 18))
                .foregroundColor(EchoTheme.accent)

        case .globe:
            Image(systemName: "globe")
                .font(.system(size: 18))
                .foregroundColor(foregroundColor)

        default:
            Text(key.label)
                .font(.system(size: isLetterKey ? 22 : 16))
                .foregroundColor(foregroundColor)
        }
    }

    private var isLetterKey: Bool {
        if case .character = key.action { return true }
        return false
    }

    private var backgroundColor: Color {
        switch key.action {
        case .character, .space:
            return EchoTheme.keyBackground
        default:
            return EchoTheme.keySecondaryBackground
        }
    }

    private var foregroundColor: Color {
        .primary
    }
}

/// Custom button style for key press animation
struct KeyPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
