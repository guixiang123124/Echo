import SwiftUI

/// Overlay showing real-time transcription text while recording
public struct TranscriptionOverlay: View {
    public let text: String
    public let isProcessing: Bool

    public init(text: String, isProcessing: Bool = false) {
        self.text = text
        self.isProcessing = isProcessing
    }

    public var body: some View {
        VStack(spacing: 8) {
            if isProcessing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: text)
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
    }
}
