import SwiftUI
import TypelessCore

/// Animated voice input button with recording state
public struct VoiceButton: View {
    public let isRecording: Bool
    public let onTap: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    public init(isRecording: Bool, onTap: @escaping () -> Void) {
        self.isRecording = isRecording
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            ZStack {
                // Pulse animation when recording
                if isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .scaleEffect(pulseScale)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: pulseScale
                        )
                }

                Circle()
                    .fill(isRecording ? Color.red : Color.blue)
                    .frame(width: 56, height: 56)

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, newValue in
            pulseScale = newValue ? 1.3 : 1.0
        }
    }
}
