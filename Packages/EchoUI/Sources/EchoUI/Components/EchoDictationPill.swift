import SwiftUI

public struct EchoDictationPill: View {
    public let isRecording: Bool
    public let isProcessing: Bool
    public let levels: [CGFloat]
    public let tipText: String?
    public let width: CGFloat
    public let height: CGFloat

    public init(
        isRecording: Bool,
        isProcessing: Bool,
        levels: [CGFloat] = [],
        tipText: String? = nil,
        width: CGFloat = 200,
        height: CGFloat = 32
    ) {
        self.isRecording = isRecording
        self.isProcessing = isProcessing
        self.levels = levels
        self.tipText = tipText
        self.width = width
        self.height = height
    }

    public var body: some View {
        ZStack {
            Capsule()
                .fill(EchoTheme.pillBackground)
                .overlay(
                    Capsule().stroke(EchoTheme.pillStroke, lineWidth: 1)
                )

            if isRecording {
                ListeningPillContent(levels: levels, tipText: tipText)
                    .padding(.horizontal, 10)
            } else if isProcessing {
                ThinkingPillContent()
                    .padding(.horizontal, 10)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(EchoTheme.accent)
                    Text("Tap to speak")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .frame(width: width, height: height)
    }
}

public struct ListeningPillContent: View {
    let levels: [CGFloat]
    let tipText: String?

    public init(levels: [CGFloat], tipText: String? = nil) {
        self.levels = levels
        self.tipText = tipText
    }

    public var body: some View {
        HStack(spacing: 10) {
            FluidWaveformView(levels: levels)
                .frame(width: 44, height: 16)

            VStack(spacing: 2) {
                Text("Listening · tap to stop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(tipText ?? "Your voice, refined by Echo.")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

            FluidWaveformView(levels: levels)
                .scaleEffect(x: -1, y: 1)
                .frame(width: 44, height: 16)
        }
    }
}

public struct ThinkingPillContent: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            ThinkingDotsView()
                .frame(width: 22, height: 10)
            Text("Thinking")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondary)
            ThinkingDotsView(reverse: true)
                .frame(width: 22, height: 10)
        }
    }
}

public struct FluidWaveformView: View {
    public let levels: [CGFloat]
    public let barCount: Int

    public init(levels: [CGFloat], barCount: Int = 14) {
        self.levels = levels
        self.barCount = barCount
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let barWidth: CGFloat = 3
                let spacing: CGFloat = 2
                let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let midY = size.height / 2
                let maxHeight = size.height
                let minHeight: CGFloat = 3

                let samples = normalizedLevels(count: barCount)
                let gradient = Gradient(colors: [EchoTheme.accentSecondary.opacity(0.9), EchoTheme.accent.opacity(0.9)])

                for index in 0..<barCount {
                    let base = samples[index]
                    let phase = time * 3.4 + Double(index) * 0.7
                    let wave = 0.65 + 0.35 * ((sin(phase) + 1) / 2)
                    let edgeWeight = edgeFalloff(for: index, count: barCount)
                    let height = max(minHeight, base * wave * edgeWeight * maxHeight)
                    let x = startX + CGFloat(index) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: rect.minX, y: rect.minY),
                            endPoint: CGPoint(x: rect.minX, y: rect.maxY)
                        )
                    )
                }
            }
            .drawingGroup()
        }
    }

    private func normalizedLevels(count: Int) -> [CGFloat] {
        let trimmed = Array(levels.suffix(count))
        if trimmed.count >= count {
            return trimmed.map { max(0.12, min($0, 1.0)) }
        }
        let padding = Array(repeating: CGFloat(0.12), count: count - trimmed.count)
        return padding + trimmed.map { max(0.12, min($0, 1.0)) }
    }

    private func edgeFalloff(for index: Int, count: Int) -> CGFloat {
        let mid = CGFloat(count - 1) / 2
        let distance = abs(CGFloat(index) - mid) / max(1, mid)
        return 0.55 + 0.45 * (1 - distance)
    }
}

public struct ThinkingDotsView: View {
    public let reverse: Bool

    public init(reverse: Bool = false) {
        self.reverse = reverse
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = 5
                let spacing: CGFloat = 3
                let radius: CGFloat = 2
                let totalWidth = CGFloat(count) * radius * 2 + CGFloat(count - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let centerY = size.height / 2

                for index in 0..<count {
                    let phaseIndex = reverse ? (count - 1 - index) : index
                    let phase = time * 2.4 - Double(phaseIndex) * 0.6
                    let intensity = 0.25 + 0.75 * ((sin(phase) + 1) / 2)
                    let scale = 0.75 + 0.35 * intensity
                    let alpha = 0.3 + 0.7 * intensity

                    let r = radius * scale
                    let x = startX + CGFloat(index) * (radius * 2 + spacing) + radius - r
                    let rect = CGRect(x: x, y: centerY - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(EchoTheme.accent.opacity(alpha)))
                }
            }
        }
    }
}
