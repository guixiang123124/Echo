import SwiftUI
import EchoCore

/// Candidate bar for Chinese character selection during Pinyin input
public struct CandidateBarView: View {
    public let candidates: [PinyinCandidate]
    public let pinyinInput: String
    public let onSelect: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        candidates: [PinyinCandidate],
        pinyinInput: String,
        onSelect: @escaping (Int) -> Void
    ) {
        self.candidates = candidates
        self.pinyinInput = pinyinInput
        self.onSelect = onSelect
    }

    private var barBackground: Color {
        colorScheme == .dark
            ? EchoTheme.keyboardSurface
            : EchoTheme.keyboardSurface
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Show current pinyin input
            if !pinyinInput.isEmpty {
                HStack {
                    Text(pinyinInput)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(EchoTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    Spacer()
                }
                .background(barBackground)
            }

            // Candidate list
            if !candidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            Button {
                                onSelect(index)
                            } label: {
                                Text(candidate.text)
                                    .font(.system(size: 18))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)

                            if index < candidates.count - 1 {
                                Divider()
                                    .frame(height: 20)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 40)
                .background(barBackground)
            }
        }
    }
}
