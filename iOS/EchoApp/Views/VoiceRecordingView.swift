import Speech
import SwiftUI
import EchoCore
import EchoUI

struct VoiceRecordingView: View {
    @StateObject private var viewModel = VoiceRecordingViewModel()
    @State private var textInput: String = ""
    @State private var lastCommittedText: String = ""
    @State private var showSettings = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $textInput)
                    .font(.system(size: 20))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
                    .frame(minHeight: 180)
                    .focused($isFocused)
                    .onTapGesture { isFocused = true }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .navigationTitle("Echo")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    KeyboardAccessoryBar(
                        isRecording: viewModel.isRecording,
                        isProcessing: viewModel.isProcessing,
                        audioLevels: viewModel.audioLevels,
                        onToggleRecording: {
                            Task { await viewModel.toggleRecording() }
                        },
                        onOpenSettings: {
                            showSettings = true
                        }
                    )
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") { viewModel.showError = false }
            } message: {
                Text(viewModel.errorMessage)
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: viewModel.transcribedText) { _, newValue in
            guard !newValue.isEmpty,
                  !viewModel.isRecording,
                  !viewModel.isProcessing,
                  newValue != lastCommittedText else { return }
            lastCommittedText = newValue
            if textInput.isEmpty {
                textInput = newValue
            } else {
                textInput += " " + newValue
            }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "echo",
              url.host == "voice" else { return }

        Task {
            await viewModel.startRecordingForKeyboard()
        }
    }
}

// MARK: - View Model

@MainActor
final class VoiceRecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var transcribedText = ""
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published var statusText = "Ready"
    @Published var showError = false
    @Published var errorMessage = ""

    private let audioService = AudioCaptureService()
    private let speechProvider = AppleLegacySpeechProvider()
    private let settings = AppSettings()
    private let contextStore = ContextMemoryStore()
    private var isKeyboardMode = false
    private var recordingTask: Task<Void, Never>?
    private var smoothedLevel: CGFloat = 0

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        // Request microphone permission
        let micGranted = await audioService.requestPermission()
        guard micGranted else {
            showErrorMessage("Microphone access is required. Enable it in Settings.")
            return
        }

        // Request speech recognition permission
        let speechStatus = await speechProvider.requestAuthorization()
        guard speechStatus == .authorized else {
            showErrorMessage("Speech recognition permission is required.")
            return
        }

        // Start audio capture
        do {
            try audioService.startRecording()
        } catch {
            showErrorMessage("Failed to start recording: \(error.localizedDescription)")
            return
        }

        isRecording = true
        statusText = "Listening..."
        transcribedText = ""

        // Start ASR streaming
        let stream = speechProvider.startStreaming()

        // Launch concurrent tasks for feeding audio and processing results
        recordingTask = Task { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                // Feed audio chunks to ASR provider + update audio levels
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await chunk in self.audioService.audioChunks {
                        try? await self.speechProvider.feedAudio(chunk)
                        let level = AudioLevelCalculator.rmsLevel(from: chunk)
                        await self.appendAudioLevel(level)
                    }
                }

                // Process ASR results
                group.addTask { [weak self] in
                    for await result in stream {
                        await MainActor.run {
                            self?.transcribedText = result.text
                            if result.isFinal {
                                self?.handleFinalTranscription(result)
                            }
                        }
                    }
                }
            }
        }
    }

    func stopRecording() async {
        audioService.stopRecording()
        _ = try? await speechProvider.stopStreaming()
        recordingTask?.cancel()
        recordingTask = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: 30)

        if transcribedText.isEmpty {
            statusText = "No speech detected"
        } else if !isProcessing {
            statusText = "Thinking..."
            isProcessing = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                self.isProcessing = false
                self.statusText = "Ready"
                self.deliverResult()
            }
        }
    }

    func startRecordingForKeyboard() async {
        isKeyboardMode = true
        await startRecording()
    }

    // MARK: - Private

    private func handleFinalTranscription(_ result: TranscriptionResult) {
        guard !result.text.isEmpty else { return }

        let correctionProvider = CorrectionProviderResolver.resolve(
            for: settings.selectedCorrectionProvider
        )

        guard settings.correctionEnabled, let provider = correctionProvider else {
            deliverResult()
            return
        }

        isProcessing = true
        statusText = "Correcting..."

        Task {
            let pipeline = CorrectionPipeline(provider: provider)
            let context = await contextStore.currentContext()

            let finalText: String
            do {
                let corrected = try await pipeline.process(
                    transcription: result,
                    context: context,
                    options: settings.correctionOptions
                )
                finalText = corrected.correctedText
            } catch {
                // Fallback to raw transcription on correction failure
                finalText = result.text
            }

            await contextStore.addTranscription(finalText)

            await MainActor.run {
                self.transcribedText = finalText
                self.isProcessing = false
                self.statusText = "Ready"
                self.deliverResult()
            }
        }
    }

    private func deliverResult() {
        if isKeyboardMode {
            settings.pendingTranscription = transcribedText
            isKeyboardMode = false
            statusText = "Sent to keyboard"
        } else {
            statusText = "Ready"
        }
    }

    private func appendAudioLevel(_ level: CGFloat) {
        let alpha: CGFloat = 0.22
        smoothedLevel = (smoothedLevel * (1 - alpha)) + (level * alpha)
        var levels = audioLevels
        levels.removeFirst()
        levels.append(smoothedLevel)
        audioLevels = levels
    }

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - Keyboard Accessory UI

struct KeyboardAccessoryBar: View {
    let isRecording: Bool
    let isProcessing: Bool
    let audioLevels: [CGFloat]
    let onToggleRecording: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(.systemGray))
            }

            Spacer()

            Button(action: onToggleRecording) {
                DictationPill(isRecording: isRecording, isProcessing: isProcessing, audioLevels: audioLevels)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray5))
    }
}

struct DictationPill: View {
    let isRecording: Bool
    let isProcessing: Bool
    let audioLevels: [CGFloat]

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color(.systemGray6))
                .overlay(
                    Capsule()
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )

            if isRecording {
                ListeningPillContent(levels: audioLevels)
                    .padding(.horizontal, 10)
            } else if isProcessing {
                ThinkingPillContent()
                    .padding(.horizontal, 10)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(.systemGray))
                    Text("点击说话")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(.systemGray))
                }
            }
        }
        .frame(width: 200, height: 32)
    }
}

struct ListeningPillContent: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 8) {
            SymmetricBarsView(levels: levels, reverseWeights: false)
                .frame(width: 42, height: 16)
            VStack(spacing: 1) {
                Text("正在倾听 点击结束")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(.label))
                Text("你的方言 也能听懂")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color(.secondaryLabel))
            }
            SymmetricBarsView(levels: levels, reverseWeights: true)
                .frame(width: 42, height: 16)
        }
    }
}

struct SymmetricBarsView: View {
    let levels: [CGFloat]
    let reverseWeights: Bool

    var body: some View {
        Canvas { context, size in
            let count = 8
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 2
            let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
            let startX = (size.width - totalWidth) / 2
            let midY = size.height / 2
            let maxHeight = size.height

            let samples = normalizedLevels(count: count)
            let gradient = Gradient(colors: [Color.cyan.opacity(0.9), Color.blue.opacity(0.85)])

            for index in 0..<count {
                let level = samples[index]
                let progress = CGFloat(index) / CGFloat(max(1, count - 1))
                let weight = reverseWeights ? (0.35 + 0.65 * (1 - progress)) : (0.35 + 0.65 * progress)
                let height = max(3, level * weight * maxHeight)
                let x = startX + CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
            }
        }
        .drawingGroup()
    }

    private func normalizedLevels(count: Int) -> [CGFloat] {
        let trimmed = Array(levels.suffix(count))
        if trimmed.count >= count {
            return trimmed.map { max(0.08, min($0, 1.0)) }
        }
        let padding = Array(repeating: CGFloat(0.08), count: count - trimmed.count)
        return padding + trimmed.map { max(0.08, min($0, 1.0)) }
    }
}

struct ThinkingPillContent: View {
    var body: some View {
        HStack(spacing: 6) {
            ThinkingDotsView()
                .frame(width: 22, height: 10)
            Text("识别中")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))
            ThinkingDotsView()
                .frame(width: 22, height: 10)
        }
    }
}

struct ThinkingDotsView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = 4
                let spacing: CGFloat = 3
                let radius: CGFloat = 2.0
                let totalWidth = CGFloat(count) * radius * 2 + CGFloat(count - 1) * spacing
                let startX = (size.width - totalWidth) / 2
                let centerY = size.height / 2

                for index in 0..<count {
                    let phase = time * 3 + Double(index) * 0.6
                    let pulse = 0.6 + 0.4 * ((sin(phase) + 1) / 2)
                    let alpha = 0.35 + 0.55 * ((sin(phase) + 1) / 2)
                    let r = radius * pulse
                    let x = startX + CGFloat(index) * (radius * 2 + spacing) + radius - r
                    let rect = CGRect(x: x, y: centerY - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(Color.cyan.opacity(alpha)))
                }
            }
        }
    }
}
