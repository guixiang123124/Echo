import Speech
import SwiftUI
import EchoCore
import EchoUI

struct VoiceRecordingView: View {
    let startForKeyboard: Bool

    @StateObject private var viewModel = VoiceRecordingViewModel()
    @State private var textInput: String = ""
    @State private var lastCommittedText: String = ""
    @State private var showSettings = false
    @FocusState private var isFocused: Bool

    init(startForKeyboard: Bool = false) {
        self.startForKeyboard = startForKeyboard
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $textInput)
                    .font(.system(size: 18))
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(EchoTheme.keyboardSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(EchoTheme.pillStroke, lineWidth: 1)
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
                        tipText: viewModel.tipText,
                        onToggleRecording: {
                            Task { await viewModel.toggleRecording() }
                        },
                        onOpenSettings: {
                            showSettings = true
                        },
                        onDismissKeyboard: {
                            isFocused = false
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
        .background(EchoTheme.keyboardBackground)
        .ignoresSafeArea()
        .task {
            guard startForKeyboard else { return }
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
    @Published var tipText = ACodeTaglines.random()
    @Published var showError = false
    @Published var errorMessage = ""

    private var audioService = AudioCaptureService()
    private let settings = AppSettings()
    private let keyStore = SecureKeyStore()
    private let contextStore = ContextMemoryStore()
    private let authSession = EchoAuthSession.shared
    private var capturedChunks: [AudioChunk] = []
    private var activeASRProvider: (any ASRProvider)?
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
        errorMessage = ""
        showError = false
        capturedChunks = []

        // Request microphone permission
        let micGranted = await audioService.requestPermission()
        guard micGranted else {
            showErrorMessage("Microphone access is required. Enable it in Settings.")
            return
        }

        // Resolve ASR provider based on Settings.
        guard let provider = resolveASRProvider() else {
            showErrorMessage("Speech recognition is not configured. Add your API key in Settings > API Keys.")
            return
        }
        activeASRProvider = provider

        // Apple Speech requires explicit authorization.
        if provider.id == "apple_speech" {
            if let appleProvider = provider as? AppleLegacySpeechProvider {
                let speechStatus = await appleProvider.requestAuthorization()
                guard speechStatus == .authorized else {
                    showErrorMessage("Speech recognition permission is required.")
                    activeASRProvider = nil
                    return
                }
            }
        }

        // Start audio capture
        do {
            // Recreate per session to avoid stale AVAudioEngine state.
            audioService = AudioCaptureService()
            try audioService.startRecording()
        } catch {
            showErrorMessage("Failed to start recording: \(error.localizedDescription)")
            activeASRProvider = nil
            return
        }

        isRecording = true
        isProcessing = false
        statusText = "Listening..."
        transcribedText = ""
        tipText = ACodeTaglines.random()

        // Collect audio + update audio levels while recording.
        recordingTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.audioService.audioChunks {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.capturedChunks.append(chunk)
                    let level = AudioLevelCalculator.rmsLevel(from: chunk)
                    self.appendAudioLevel(level)
                }
            }
        }
    }

    func stopRecording() async {
        let provider = activeASRProvider
        activeASRProvider = nil

        audioService.stopRecording()
        recordingTask?.cancel()
        recordingTask = nil
        isRecording = false
        audioLevels = Array(repeating: 0, count: 30)

        // Give the tap a moment to flush in-flight buffers.
        for _ in 0..<4 where capturedChunks.isEmpty {
            try? await Task.sleep(for: .milliseconds(80))
        }

        guard let provider else {
            statusText = "Ready"
            return
        }

        guard !capturedChunks.isEmpty else {
            statusText = "No audio data recorded"
            showErrorMessage("No audio data recorded")
            return
        }

        statusText = "Thinking..."
        isProcessing = true

        let combinedData = capturedChunks.reduce(Data()) { $0 + $1.data }
        let totalDuration = capturedChunks.reduce(0) { $0 + $1.duration }
        let format = capturedChunks.first?.format ?? .default

        let combinedChunk = AudioChunk(
            data: combinedData,
            format: format,
            duration: totalDuration
        )

        do {
            // Transcribe
            let transcription = try await provider.transcribe(audio: combinedChunk)
            let rawText = transcription.text
            var finalText = rawText

            // Auto Edit (optional)
            let correctionProviderId = settings.correctionEnabled ? settings.selectedCorrectionProvider : nil
            if settings.correctionEnabled,
               let correctionProvider = CorrectionProviderResolver.resolve(for: settings.selectedCorrectionProvider) {
                statusText = "Correcting..."
                do {
                    let pipeline = CorrectionPipeline(provider: correctionProvider)
                    let context = await contextStore.currentContext()
                    let corrected = try await pipeline.process(
                        transcription: transcription,
                        context: context,
                        options: settings.correctionOptions
                    )
                    finalText = corrected.correctedText
                } catch {
                    finalText = rawText
                }
            }

            await contextStore.addTranscription(finalText)

            await RecordingStore.shared.saveRecording(
                audio: combinedChunk,
                asrProviderId: provider.id,
                asrProviderName: provider.displayName,
                correctionProviderId: correctionProviderId,
                transcriptRaw: rawText,
                transcriptFinal: finalText,
                error: nil,
                userId: authSession.userId
            )

            transcribedText = finalText
            isProcessing = false
            statusText = "Ready"
            deliverResult()
        } catch {
            await RecordingStore.shared.saveRecording(
                audio: combinedChunk,
                asrProviderId: provider.id,
                asrProviderName: provider.displayName,
                correctionProviderId: nil,
                transcriptRaw: nil,
                transcriptFinal: nil,
                error: error.localizedDescription,
                userId: authSession.userId
            )
            isProcessing = false
            statusText = "Ready"
            showErrorMessage("Could not process audio: \(error.localizedDescription)")
        }
    }

    func startRecordingForKeyboard() async {
        isKeyboardMode = true
        await startRecording()
    }

    private func deliverResult() {
        guard !transcribedText.isEmpty else { return }
        if isKeyboardMode {
            settings.pendingTranscription = transcribedText
            isKeyboardMode = false
            statusText = "Sent to keyboard"
        } else {
            statusText = "Ready"
        }
    }

    private func resolveASRProvider() -> (any ASRProvider)? {
        switch settings.selectedASRProvider {
        case "apple_speech":
            let provider = AppleLegacySpeechProvider(localeIdentifier: nil)
            return provider.isAvailable ? provider : nil
        case "aliyun":
            guard let appKey = try? keyStore.retrieve(for: "aliyun_app_key"),
                  let token = try? keyStore.retrieve(for: "aliyun_token"),
                  !appKey.isEmpty,
                  !token.isEmpty else {
                return nil
            }
            return AliyunASRProvider(appKey: appKey, token: token)
        case "volcano":
            guard let appId = try? keyStore.retrieve(for: "volcano_app_id"),
                  let accessKey = try? keyStore.retrieve(for: "volcano_access_key"),
                  !appId.isEmpty,
                  !accessKey.isEmpty else {
                return nil
            }
            return VolcanoASRProvider(appId: appId, accessKey: accessKey)
        default:
            // Default to OpenAI Whisper (batch transcription)
            let provider = OpenAIWhisperProvider(keyStore: keyStore)
            return provider.isAvailable ? provider : nil
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
    let tipText: String
    let onToggleRecording: () -> Void
    let onOpenSettings: () -> Void
    let onDismissKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(EchoTheme.keySecondaryBackground))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onToggleRecording) {
                EchoDictationPill(
                    isRecording: isRecording,
                    isProcessing: isProcessing,
                    levels: audioLevels,
                    tipText: tipText,
                    width: 210,
                    height: 32
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onDismissKeyboard) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(EchoTheme.keySecondaryBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(EchoTheme.keyboardSurface)
    }
}

enum ACodeTaglines {
    private static let options: [String] = [
        "Speak once. ACode shapes it into clarity.",
        "ACode turns ideas into clean, shippable notes.",
        "Think aloud, ACode makes it real.",
        "From voice to precision — powered by ACode.",
        "ACode keeps your thoughts crisp and actionable.",
        "ACode turns rough drafts into sharp direction."
    ]

    static func random() -> String {
        options.randomElement() ?? "Speak once. ACode shapes it into clarity."
    }
}
