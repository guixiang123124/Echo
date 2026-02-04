import SwiftUI

/// Audio waveform visualization for voice recording
public struct WaveformView: View {
    public let levels: [CGFloat]
    public let isActive: Bool

    @State private var animationOffset: CGFloat = 0

    public init(levels: [CGFloat] = [], isActive: Bool = false) {
        self.levels = levels
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(
                        .easeInOut(duration: 0.15),
                        value: barHeight(for: index)
                    )
            }
        }
        .frame(height: maxHeight)
    }

    private var barCount: Int { 30 }
    private var maxHeight: CGFloat { 40 }
    private var minHeight: CGFloat { 4 }

    private var barColor: Color {
        isActive ? .blue : .gray.opacity(0.3)
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isActive, index < levels.count else {
            return minHeight
        }
        let level = max(0, min(1, levels[index]))
        return minHeight + (maxHeight - minHeight) * level
    }
}
