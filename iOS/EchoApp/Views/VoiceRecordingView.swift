import Speech
import SwiftUI
import EchoCore
import EchoUI

struct VoiceRecordingView: View {
    @StateObject private var viewModel = VoiceRecordingViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Transcription result
                TranscriptionOverlay(
                    text: viewModel.transcribedText,
                    isProcessing: viewModel.isProcessing
                )
                .padding(.horizontal)

                // Waveform
                WaveformView(
                    levels: viewModel.audioLevels,
                    isActive: viewModel.isRecording
                )
                .frame(height: 60)
                .padding(.horizontal, 40)

                // Status text
                Text(viewModel.statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Voice button
                VoiceButton(isRecording: viewModel.isRecording) {
                    Task {
                        await viewModel.toggleRecording()
                    }
                }

                Spacer()

                // Info text
                if viewModel.transcribedText.isEmpty && !viewModel.isRecording {
                    VStack(spacing: 8) {
                        Text("Tap the microphone to start speaking")
                            .font(.headline)
                        Text("Your speech will be transcribed and corrected using AI")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Echo")
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") { viewModel.showError = false }
            } message: {
                Text(viewModel.errorMessage)
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
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
            deliverResult()
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
                    context: context
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
        var levels = audioLevels
        levels.removeFirst()
        levels.append(level)
        audioLevels = levels
    }

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
