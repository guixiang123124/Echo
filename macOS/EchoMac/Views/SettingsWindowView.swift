import SwiftUI
import EchoCore
import AuthenticationServices
import GoogleSignIn
import AppKit
/// Main settings window view with tab navigation
struct SettingsWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var authSession: EchoAuthSession
    @EnvironmentObject var cloudSync: CloudSyncService
    @EnvironmentObject var billing: BillingService

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .environmentObject(settings)
                .environmentObject(permissionManager)
                .environmentObject(authSession)
                .environmentObject(cloudSync)
                .environmentObject(billing)

            ASRSettingsTab()
                .tabItem {
                    Label("Speech", systemImage: "waveform")
                }
                .environmentObject(settings)

            CorrectionSettingsTab()
                .tabItem {
                    Label("Auto Edit", systemImage: "sparkles")
                }
                .environmentObject(settings)

            PermissionsSettingsTab()
                .tabItem {
                    Label("Permissions", systemImage: "hand.raised")
                }
                .environmentObject(permissionManager)

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var authSession: EchoAuthSession
    @EnvironmentObject var cloudSync: CloudSyncService
    @EnvironmentObject var billing: BillingService
    @State private var showAuthSheet = false

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Activation Key", selection: $settings.hotkeyType) {
                    ForEach(MacAppSettings.HotkeyType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                Text(settings.hotkeyHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Recording Mode") {
                Picker("Mode", selection: $settings.recordingMode) {
                    ForEach(MacAppSettings.RecordingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(settings.recordingMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Hands-Free Auto Stop") {
                Toggle("Stop on Silence", isOn: $settings.handsFreeAutoStopEnabled)

                HStack {
                    Text("Silence duration")
                    Spacer()
                    Text("\(settings.handsFreeSilenceDuration, specifier: "%.1f")s")
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.handsFreeSilenceDuration, in: 0.6...3.0, step: 0.1)

                HStack {
                    Text("Silence threshold")
                    Spacer()
                    Text("\(settings.handsFreeSilenceThreshold, specifier: "%.02f")")
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.handsFreeSilenceThreshold, in: 0.02...0.2, step: 0.01)

                HStack {
                    Text("Minimum recording")
                    Spacer()
                    Text("\(settings.handsFreeMinimumDuration, specifier: "%.1f")s")
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.handsFreeMinimumDuration, in: 0.5...2.5, step: 0.1)

                Text("Lower threshold is more sensitive to quiet speech.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                Toggle("Show Menu Bar Icon", isOn: .constant(true))
                    .disabled(true)
            }

            Section("Behavior") {
                Toggle("Play Sound on Start/Stop", isOn: $settings.playSoundEffects)
                Toggle("Show Recording Indicator", isOn: $settings.showRecordingPanel)
            }

            Section("Account") {
                if settings.cloudSyncBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Cloud backend not configured. Local history still works.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if authSession.isSignedIn {
                    HStack {
                        Text("Signed in")
                        Spacer()
                        Text(authSession.displayName)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Sign in to sync history across devices.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Sync History to Cloud", isOn: Binding(
                    get: { settings.cloudSyncEnabled },
                    set: { newValue in
                        settings.cloudSyncEnabled = newValue
                        cloudSync.setEnabled(newValue)
                        billing.setEnabled(newValue)
                    }
                ))

                TextField(
                    "Cloud API URL (Railway)",
                    text: Binding(
                        get: { settings.cloudSyncBaseURL },
                        set: { newValue in
                            settings.cloudSyncBaseURL = newValue
                            authSession.configureBackend(baseURL: newValue)
                            cloudSync.configure(
                                baseURLString: newValue,
                                uploadAudio: settings.cloudUploadAudioEnabled
                            )
                            billing.configure(baseURLString: newValue)
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)

                Toggle("Upload audio to cloud (optional)", isOn: Binding(
                    get: { settings.cloudUploadAudioEnabled },
                    set: { newValue in
                        settings.cloudUploadAudioEnabled = newValue
                        cloudSync.configure(
                            baseURLString: settings.cloudSyncBaseURL,
                            uploadAudio: newValue
                        )
                    }
                ))

                HStack {
                    Text("Plan")
                    Spacer()
                    Text((billing.snapshot?.tier ?? "free").uppercased())
                        .foregroundColor(billing.snapshot?.hasActiveSubscription == true ? .green : .secondary)
                }

                Button("Refresh Plan Status") {
                    Task { await billing.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(!authSession.isSignedIn)

                Button(authSession.isSignedIn ? "Switch User" : "Sign In") {
                    showAuthSheet = true
                }
                .buttonStyle(.bordered)

                if authSession.isSignedIn {
                    Button("Sign Out") {
                        authSession.signOut()
                    }
                    .buttonStyle(.bordered)
                }

                TextField("Display name", text: $settings.userDisplayName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("User ID")
                    Spacer()
                    Text(settings.currentUserId)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Text("Records are stored locally and tagged to this user.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showAuthSheet) {
            AuthSheetView()
                .environmentObject(authSession)
        }
        .task {
            billing.configure(baseURLString: settings.cloudSyncBaseURL)
            billing.setEnabled(settings.cloudSyncEnabled)
            billing.updateAuthState(user: authSession.user)
            await billing.refresh()
        }
    }
}

// MARK: - ASR Settings Tab

struct ASRSettingsTab: View {
    @EnvironmentObject var settings: MacAppSettings
    @EnvironmentObject var authSession: EchoAuthSession
    @State private var benchmarkRunning = false
    @State private var benchmarkStatus = ""
    @State private var providerHealthScores: [RecordingStore.ProviderHealthScore] = []

    private static let streamCapableProviders: Set<String> = ["deepgram", "volcano"]

    private var isAdminUser: Bool {
        let email = authSession.user?.email?.lowercased() ?? ""
        let uid = authSession.user?.uid.lowercased() ?? ""
        let name = authSession.displayName.lowercased()
        if UserDefaults.standard.bool(forKey: "echo.admin.debug.enabled") {
            return true
        }
        if email == "guixiang123123@gmail.com" {
            return true
        }
        if name.contains("brian gui") || uid.contains("admin") {
            return true
        }
        return false
    }

    private var providerOptionsForCurrentMode: [(id: String, label: String)] {
        switch settings.asrMode {
        case .batch:
            return [
                ("openai_whisper", "OpenAI Transcribe"),
                ("volcano", "Volcano Engine (ByteDance / 豆包ASR)"),
                ("deepgram", "Deepgram Nova-3")
            ]
        case .stream:
            return [
                ("volcano", "Volcano Engine (ByteDance / 豆包ASR)"),
                ("deepgram", "Deepgram Nova-3")
            ]
        }
    }

    private var modeDescription: String {
        switch settings.asrMode {
        case .batch:
            return "Batch mode defaults to OpenAI GPT-4o Transcribe. You can still switch to Volcano or Deepgram."
        case .stream:
            return "Stream mode defaults to Volcano realtime ASR. You can switch to Deepgram."
        }
    }

    private var currentEngineLabel: String {
        switch settings.selectedASRProvider {
        case "volcano":
            return "Volcano Engine (ByteDance / 豆包ASR)"
        case "deepgram":
            return "Deepgram Nova-3"
        default:
            return "OpenAI Transcribe"
        }
    }

    var body: some View {
        Form {
            Section("Speech Mode") {
                Picker("Request Mode", selection: $settings.asrMode) {
                    Text("Batch").tag(MacAppSettings.ASRMode.batch)
                    Text("Stream (Realtime)").tag(MacAppSettings.ASRMode.stream)
                }
                .pickerStyle(.segmented)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Current ASR Engine")
                    Spacer()
                    Text(currentEngineLabel)
                        .foregroundColor(.secondary)
                }
            }


            Section("Provider Health (Recent)") {
                if providerHealthScores.isEmpty {
                    Text("No recent samples yet. Start dictating to collect quality telemetry.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(providerHealthScores.prefix(isAdminUser ? 4 : 2)) { score in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(score.providerName)
                                Spacer()
                                Text(String(format: "%.0f", score.healthScore) + " / 100")
                                    .foregroundColor(.secondary)
                            }
                            Text(
                                "Success \(percent(score.successRate)) · Avg \(Int(score.averageAsrLatencyMs))ms · Trunc \(percent(score.truncationRate)) · Fallback \(percent(score.fallbackRate))"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }


            if isAdminUser {
                Section("Pipeline Presets (Admin)") {
                    Picker(
                        "Preset",
                        selection: Binding(
                            get: { settings.pipelinePreset },
                            set: { settings.pipelinePreset = $0 }
                        )
                    ) {
                        ForEach(MacAppSettings.PipelinePreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(settings.pipelinePreset.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Speech Recognition (ASR) - Admin") {
                    Picker("Speech Recognition Provider", selection: $settings.selectedASRProvider) {
                        ForEach(providerOptionsForCurrentMode, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Enable StreamFast (fast finalize + async polish)", isOn: $settings.streamFastEnabled)

                    if settings.asrMode == .stream && settings.streamFastEnabled {
                        Text("StreamFast prioritizes immediate Finalize in the input field, then runs Auto Edit polish asynchronously.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if settings.selectedASRProvider == "volcano" {
                        ProviderKeyRow(
                            label: "Volcano App ID",
                            providerId: "volcano_app_id"
                        )

                        ProviderKeyRow(
                            label: "Volcano Access Key",
                            providerId: "volcano_access_key"
                        )

                        ProviderValueRow(
                            label: "Volcano Resource ID (optional)",
                            providerId: "volcano_resource_id",
                            placeholder: "volc.bigasr.auc_turbo"
                        )

                        ProviderValueRow(
                            label: "Volcano Endpoint (optional)",
                            providerId: "volcano_endpoint",
                            placeholder: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
                        )

                        Text("Volcano requires both App ID and Access Key. Resource ID may vary by account entitlement.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if settings.selectedASRProvider == "deepgram" {
                        ProviderKeyRow(
                            label: "Deepgram API Key",
                            providerId: "deepgram"
                        )

                        Picker("Deepgram Model", selection: $settings.deepgramModel) {
                            Text("nova-3 (recommended)").tag("nova-3")
                            Text("nova-2").tag("nova-2")
                        }
                        .pickerStyle(.menu)

                        Text("Deepgram supports Batch and Stream. Best accuracy is typically in English; Chinese depends on model/language hint.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ProviderKeyRow(
                            label: "OpenAI API Key",
                            providerId: "openai_whisper"
                        )

                        Picker("Transcription Model", selection: $settings.openAITranscriptionModel) {
                            Text("GPT-4o Transcribe (default)").tag("gpt-4o-transcribe")
                            Text("GPT-4o Mini Transcribe").tag("gpt-4o-mini-transcribe")
                            Text("Whisper-1").tag("whisper-1")
                        }
                        .pickerStyle(.menu)

                        Text("All OpenAI transcription models use the same API key.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Auto Edit uses a separate model configured below.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Auto Edit (Optional)") {
                    Toggle("Enable Auto Edit", isOn: $settings.correctionEnabled)

                    Picker("Provider", selection: $settings.selectedCorrectionProvider) {
                        Text("OpenAI GPT-4o").tag("openai_gpt")
                        Text("Claude").tag("claude")
                        Text("Doubao").tag("doubao")
                        Text("Alibaba Qwen").tag("qwen")
                    }
                    .pickerStyle(.menu)

                    Text("Fine-grained options are available in the Auto Edit tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("ASR Benchmark") {
                    Button(benchmarkRunning ? "Running…" : "Run 1-Click Benchmark (last 2 recordings)") {
                        Task { await runBenchmark() }
                    }
                    .disabled(benchmarkRunning)

                    if !benchmarkStatus.isEmpty {
                        Text(benchmarkStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    Text("Runs whisper-1 / gpt-4o-transcribe / gpt-4o-mini-transcribe plus Volcano (if configured), each with Auto Edit ON/OFF, then writes a markdown report.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Language") {
                    Picker("Recognition Language", selection: $settings.asrLanguage) {
                        Text("Auto Detect").tag("auto")
                        Divider()
                        Text("English").tag("en-US")
                        Text("中文 (简体)").tag("zh-CN")
                        Text("中文 (繁體)").tag("zh-TW")
                        Text("日本語").tag("ja-JP")
                        Text("한국어").tag("ko-KR")
                    }
                    .pickerStyle(.menu)
                }
            } else {
                Section("Auto Edit") {
                    Text("Auto Edit presets and detailed rewrite options are in the Auto Edit tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            normalizeProviderForMode(settings.asrMode)
            reloadProviderHealth()
        }
        .onChange(of: settings.asrMode) { _, newValue in
            normalizeProviderForMode(newValue)
        }
        .onChange(of: settings.selectedASRProvider) { _, newValue in
            if settings.asrMode == .stream, !Self.streamCapableProviders.contains(newValue) {
                settings.selectedASRProvider = "volcano"
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .echoRecordingSaved)) { _ in
            reloadProviderHealth()
        }
    }


    private func reloadProviderHealth() {
        Task {
            let scores = await RecordingStore.shared.providerHealthScores(limit: 120)
            await MainActor.run {
                providerHealthScores = scores
            }
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", max(0.0, min(1.0, value)) * 100)
    }


    private func normalizeProviderForMode(_ mode: MacAppSettings.ASRMode) {
        switch mode {
        case .batch:
            // Product rule: switching to Batch defaults to OpenAI.
            if settings.selectedASRProvider != "openai_whisper" {
                settings.selectedASRProvider = "openai_whisper"
            }
        case .stream:
            // Product rule: switching to Stream defaults to Volcano.
            if !Self.streamCapableProviders.contains(settings.selectedASRProvider) {
                settings.selectedASRProvider = "volcano"
            }
        }
    }

    private func runBenchmark() async {
        benchmarkRunning = true
        benchmarkStatus = "Preparing benchmark…"
        defer { benchmarkRunning = false }

        do {
            let reportURL = try await ASRBenchmarkRunner.runUsingLatestRecordings(limit: 2)
            benchmarkStatus = "Done. Report: \(reportURL.path)"
        } catch {
            benchmarkStatus = "Benchmark failed: \(error.localizedDescription)"
        }
    }
}

private enum ASRBenchmarkRunner {
    struct Result {
        let fileName: String
        let provider: String
        let autoEdit: Bool
        let success: Bool
        let asrLatencyMs: Int
        let autoEditLatencyMs: Int?
        let totalLatencyMs: Int
        let error: String?
        let text: String
    }

    static func runUsingLatestRecordings(limit: Int) async throws -> URL {
        let recordingsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.xianggui.echo.mac/Data/Library/Application Support/Echo/Recordings", isDirectory: true)

        let files = try FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }

        guard files.count >= limit else {
            throw NSError(domain: "ASRBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Need at least \(limit) recordings in \(recordingsDir.path)"])
        }

        let targetFiles = Array(files.prefix(limit))
        let keyStore = SecureKeyStore()
        let correctionProvider = OpenAICorrectionProvider(keyStore: keyStore)

        let models = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
        var providers: [(String, () -> (any ASRProvider)?)] = models.map { model in
            ("openai:\(model)", { OpenAIWhisperProvider(keyStore: keyStore, model: model) })
        }

        let volcano = VolcanoASRProvider(keyStore: keyStore)
        if volcano.isAvailable {
            providers.append(("volcano", { VolcanoASRProvider(keyStore: keyStore) }))
        }

        var results: [Result] = []

        for file in targetFiles {
            let chunk = try loadWAV(file)

            for (providerName, providerFactory) in providers {
                for autoEdit in [false, true] {
                    let start = Date()
                    guard let provider = providerFactory(), provider.isAvailable else {
                        results.append(Result(fileName: file.lastPathComponent, provider: providerName, autoEdit: autoEdit, success: false, asrLatencyMs: 0, autoEditLatencyMs: nil, totalLatencyMs: 0, error: "Provider unavailable", text: ""))
                        continue
                    }

                    do {
                        let asrStart = Date()
                        let transcription = try await provider.transcribe(audio: chunk)
                        let asrLatency = Int(Date().timeIntervalSince(asrStart) * 1000)

                        var finalText = transcription.text
                        var autoEditLatency: Int? = nil
                        if autoEdit {
                            guard correctionProvider.isAvailable else {
                                throw NSError(domain: "ASRBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Auto Edit unavailable (missing OpenAI key)"])
                            }
                            let editStart = Date()
                            let correction = try await CorrectionPipeline(provider: correctionProvider).process(
                                transcription: transcription,
                                context: ConversationContext(),
                                options: CorrectionOptions(enableHomophones: true, enablePunctuation: true, enableFormatting: true)
                            )
                            finalText = correction.correctedText
                            autoEditLatency = Int(Date().timeIntervalSince(editStart) * 1000)
                        }

                        results.append(Result(fileName: file.lastPathComponent, provider: providerName, autoEdit: autoEdit, success: true, asrLatencyMs: asrLatency, autoEditLatencyMs: autoEditLatency, totalLatencyMs: Int(Date().timeIntervalSince(start) * 1000), error: nil, text: finalText))
                    } catch {
                        results.append(Result(fileName: file.lastPathComponent, provider: providerName, autoEdit: autoEdit, success: false, asrLatencyMs: 0, autoEditLatencyMs: nil, totalLatencyMs: Int(Date().timeIntervalSince(start) * 1000), error: error.localizedDescription, text: ""))
                    }
                }
            }
        }

        let report = renderReport(files: targetFiles, results: results)
        let outDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.xianggui.echo.mac/Data/Library/Application Support/Echo/BenchmarkReports", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outURL = outDir.appendingPathComponent("asr-benchmark-\(ts).md")
        try report.write(to: outURL, atomically: true, encoding: .utf8)
        return outURL
    }

    private static func renderReport(files: [URL], results: [Result]) -> String {
        var lines: [String] = []
        lines.append("# ASR Benchmark Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Files: \(files.map { $0.lastPathComponent }.joined(separator: ", "))")
        lines.append("")
        lines.append("## Latency / Failure Table")
        lines.append("")
        lines.append("| File | Provider | AutoEdit | Success | ASR ms | AutoEdit ms | Total ms | Error |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---|")
        for r in results {
            lines.append("| \(r.fileName) | \(r.provider) | \(r.autoEdit ? "on" : "off") | \(r.success ? "✅" : "❌") | \(r.asrLatencyMs) | \(r.autoEditLatencyMs.map(String.init) ?? "-") | \(r.totalLatencyMs) | \((r.error ?? "").replacingOccurrences(of: "|", with: "/")) |")
        }
        lines.append("")
        lines.append("## Full Transcription Text")
        lines.append("")
        for r in results where r.success {
            lines.append("### \(r.fileName) · \(r.provider) · AutoEdit \(r.autoEdit ? "ON" : "OFF")")
            lines.append(r.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func loadWAV(_ fileURL: URL) throws -> AudioChunk {
        let data = try Data(contentsOf: fileURL)
        let parsed = try WAVReader.parse(data: data)
        return AudioChunk(
            data: parsed.pcmData,
            format: AudioStreamFormat(sampleRate: parsed.sampleRate, channelCount: parsed.channels, bitsPerSample: parsed.bitsPerSample, encoding: .linearPCM),
            duration: parsed.duration
        )
    }
}

private enum WAVReader {
    struct Parsed {
        let pcmData: Data
        let sampleRate: Double
        let channels: Int
        let bitsPerSample: Int
        let duration: TimeInterval
    }

    static func parse(data: Data) throws -> Parsed {
        guard data.count > 44 else {
            throw NSError(domain: "WAVReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio file too small"])
        }
        guard String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else {
            throw NSError(domain: "WAVReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid WAV file"])
        }

        var offset = 12
        var sampleRate: Double = 16000
        var channels = 1
        var bitsPerSample = 16
        var pcmData = Data()

        while offset + 8 <= data.count {
            let chunkId = String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) ?? ""
            let chunkSize = Int(UInt32(littleEndian: data.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let start = offset + 8
            let end = start + chunkSize
            guard end <= data.count else { break }

            if chunkId == "fmt " {
                let fmt = data.subdata(in: start..<end)
                if fmt.count >= 16 {
                    channels = Int(UInt16(littleEndian: fmt.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) }))
                    sampleRate = Double(UInt32(littleEndian: fmt.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }))
                    bitsPerSample = Int(UInt16(littleEndian: fmt.subdata(in: 14..<16).withUnsafeBytes { $0.load(as: UInt16.self) }))
                }
            } else if chunkId == "data" {
                pcmData = data.subdata(in: start..<end)
            }

            offset = end + (chunkSize % 2)
        }

        guard !pcmData.isEmpty else {
            throw NSError(domain: "WAVReader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing PCM data chunk"])
        }

        let bytesPerSecond = max(1, Int(sampleRate) * channels * max(1, bitsPerSample / 8))
        return Parsed(
            pcmData: pcmData,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            duration: TimeInterval(pcmData.count) / TimeInterval(bytesPerSecond)
        )
    }
}

// MARK: - Correction Settings Tab

struct CorrectionSettingsTab: View {
    @EnvironmentObject var settings: MacAppSettings

    var body: some View {
        Form {
            Section("Auto Edit V2") {
                Picker("Preset", selection: $settings.autoEditPreset) {
                    ForEach(AutoEditPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.autoEditPreset.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Enable Auto Edit", isOn: $settings.correctionEnabled)
                Text("Three stages: Stream realtime revision + ASR Finalize + LLM Auto Edit.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if settings.correctionEnabled {
                    Picker("Apply Behavior", selection: $settings.autoEditApplyMode) {
                        ForEach(AutoEditApplyMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Fix Homophones", isOn: $settings.correctionHomophonesEnabled)
                    Toggle("Fix Punctuation", isOn: $settings.correctionPunctuationEnabled)
                    Toggle("Fix Formatting", isOn: $settings.correctionFormattingEnabled)
                    Toggle("Remove Filler Words", isOn: $settings.correctionRemoveFillerEnabled)
                    Toggle("Remove Repetitions", isOn: $settings.correctionRemoveRepetitionEnabled)

                    Picker("Rewrite Intensity", selection: $settings.correctionRewriteIntensity) {
                        ForEach(RewriteIntensity.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Structured Output", selection: $settings.correctionStructuredOutputStyle) {
                        ForEach(StructuredOutputStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Translate in Auto Edit", isOn: $settings.correctionTranslationEnabled)
                    if settings.correctionTranslationEnabled {
                        Picker("Target Language", selection: $settings.correctionTranslationTarget) {
                            ForEach(TranslationTargetLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Divider()
                    Toggle("Dictionary Auto Learn", isOn: $settings.dictionaryAutoLearnEnabled)
                    Toggle("Auto Learn Requires Review", isOn: $settings.dictionaryAutoLearnRequireReview)
                    Text("Recommended: keep review enabled so auto-learned terms are stored as candidates first.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("AI Provider", selection: $settings.selectedCorrectionProvider) {
                        Text("OpenAI GPT-4o").tag("openai_gpt")
                        Text("Claude").tag("claude")
                        Text("豆包").tag("doubao")
                        Text("Alibaba Qwen").tag("qwen")
                    }
                    .pickerStyle(.menu)

                    ProviderKeyRow(
                        label: providerKeyLabel(for: settings.selectedCorrectionProvider),
                        providerId: settings.selectedCorrectionProvider
                    )
                }
            }

            Section("Editing Features") {
                Text("Stream layer keeps both model partial revision and client-side merge/dedupe replacement.")
                .font(.caption)
                .foregroundColor(.secondary)
                Text("Finalize is ASR-native; Auto Edit handles configurable rewrite/translation after finalize.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func providerKeyLabel(for providerId: String) -> String {
        switch providerId {
        case "claude":
            return "Claude API Key"
        case "doubao":
            return "Doubao API Key"
        case "qwen":
            return "Qwen API Key"
        default:
            return "OpenAI API Key"
        }
    }

}

// MARK: - Permissions Settings Tab

struct PermissionsSettingsTab: View {
    @EnvironmentObject var permissionManager: PermissionManager

    var body: some View {
        Form {
            Section("Required Permissions") {
                PermissionStatusRow(
                    title: "Accessibility",
                    description: "Required for text insertion into other apps",
                    isGranted: permissionManager.accessibilityGranted,
                    onRequest: { permissionManager.requestAccessibilityPermission() }
                )

                PermissionStatusRow(
                    title: "Input Monitoring",
                    description: "Required to detect global hotkeys",
                    isGranted: permissionManager.inputMonitoringGranted,
                    onRequest: { permissionManager.requestInputMonitoringPermission() }
                )

                PermissionStatusRow(
                    title: "Microphone",
                    description: "Required for voice recording",
                    isGranted: permissionManager.microphoneGranted,
                    onRequest: {
                        Task { _ = await permissionManager.requestMicrophonePermission() }
                    }
                )
            }

            Section {
                Button("Refresh Permission Status") {
                    permissionManager.checkAllPermissions()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PermissionStatusRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}

struct ProviderKeyRow: View {
    let label: String
    let providerId: String

    @State private var storedKey: String?
    @State private var apiKey: String = ""

    private let keyStore = SecureKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                if let storedKey, !storedKey.isEmpty {
                    Text(maskedKey(storedKey))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Replace") {
                        apiKey = ""
                        self.storedKey = nil
                    }
                    .font(.caption)

                    Button("Remove") {
                        removeKey()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                } else {
                    SecureField("Enter API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        saveKey()
                    }
                    .font(.caption)
                    .disabled(apiKey.isEmpty)
                }
            }
        }
        .onAppear(perform: loadKey)
        .onChange(of: providerId) { _, _ in loadKey() }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    private func loadKey() {
        apiKey = ""
        let key = try? keyStore.retrieve(for: providerId)
        if let key, !key.isEmpty {
            storedKey = key
        } else {
            storedKey = nil
        }
    }

    private func saveKey() {
        guard !apiKey.isEmpty else { return }
        try? keyStore.store(key: apiKey, for: providerId)
        storedKey = apiKey
        apiKey = ""
    }

    private func removeKey() {
        try? keyStore.delete(for: providerId)
        storedKey = nil
        apiKey = ""
    }
}

struct ProviderValueRow: View {
    let label: String
    let providerId: String
    let placeholder: String

    @State private var value: String = ""
    @State private var isSaved = false

    private let keyStore = SecureKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    saveValue()
                }
                .font(.caption)

                Button("Clear") {
                    clearValue()
                }
                .font(.caption)
                .foregroundColor(.red)
            }

            if isSaved {
                Text("Saved")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
        .onAppear(perform: loadValue)
        .onChange(of: providerId) { _, _ in loadValue() }
    }

    private func loadValue() {
        value = (try? keyStore.retrieve(for: providerId)) ?? ""
        isSaved = false
    }

    private func saveValue() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keyStore.delete(for: providerId)
            value = ""
        } else {
            try? keyStore.store(key: trimmed, for: providerId)
            value = trimmed
        }
        isSaved = true
    }

    private func clearValue() {
        try? keyStore.delete(for: providerId)
        value = ""
        isSaved = false
    }
}

// MARK: - About Settings Tab

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Echo")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Hold a key, speak, and your words appear as text.\nPowered by AI for natural, polished output.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Divider()
                .padding(.vertical)

            VStack(spacing: 8) {
                Link("Visit Website", destination: URL(string: "https://github.com/guixiang123124/Echo")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/guixiang123124/Echo/issues")!)
            }

            Spacer()

            Text("© 2024 Echo. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsWindowView()
        .environmentObject(AppState())
        .environmentObject(PermissionManager())
        .environmentObject(MacAppSettings())
}

// MARK: - Auth Sheet

struct AuthSheetView: View {
    @EnvironmentObject var authSession: EchoAuthSession
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var cloudAPIURL = ""
    @StateObject private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sign in to Echo")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Cloud Backend")
                    .font(.headline)
                HStack(spacing: 8) {
                    TextField("Cloud API URL", text: $cloudAPIURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        applyCloudAPIURL()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !authSession.isConfigured {
                    Text("Apple/Google sign-in requires Cloud API URL.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    Button("Sign In") {
                        Task { await authSession.signIn(email: email, password: password) }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Create Account") {
                        Task { await authSession.signUp(email: email, password: password) }
                    }
                    .buttonStyle(.bordered)
                }

                Text("Use your email address here, or continue with Apple below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                signInWithGoogle()
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "globe")
                    Text("Sign in with Google")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.35), lineWidth: 1))
                .foregroundColor(.black)
            }
            .buttonStyle(.plain)

            Button {
                appleCoordinator.start { credential, nonce in
                    Task { await authSession.signInWithApple(credential: credential, nonce: nonce) }
                } onError: { error in
                    authSession.errorMessage = error.localizedDescription
                }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "applelogo")
                    Text("Sign in with Apple")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            if authSession.isLoading {
                ProgressView()
            }

            if let error = authSession.errorMessage, !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if authSession.isSignedIn {
                Divider()
                HStack {
                    Text("Signed in as \(authSession.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign Out") {
                        authSession.signOut()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            bootstrapCloudAPIURLIfNeeded()
        }
    }

    @MainActor
    private func signInWithGoogle() {
        bootstrapCloudAPIURLIfNeeded()

        guard authSession.isConfigured else {
            authSession.errorMessage = "Google sign-in requires Cloud API URL. Add URL and tap Apply first."
            return
        }

        let clientID = (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID_MAC") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String)

        if let clientID, !clientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        guard let candidateWindow = NSApplication.shared.keyWindow
                ?? NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first else {
            authSession.errorMessage = "Unable to find active window for Google sign-in."
            return
        }

        // Avoid presenting OAuth from a sheet window; use its parent when available.
        let presentingWindow = candidateWindow.sheetParent ?? candidateWindow

        if let configuredClientID = (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID_MAC") as? String),
           !configuredClientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: configuredClientID)
        } else if let legacyClientID = (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String),
                  !legacyClientID.isEmpty {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: legacyClientID)
        } else {
            authSession.errorMessage = "Google Client ID is not configured in Info.plist."
            return
        }

        GIDSignIn.sharedInstance.signIn(withPresenting: presentingWindow) { result, error in
            if let error {
                Task { @MainActor in
                    let message = error.localizedDescription
                    if message.lowercased().contains("canceled"), !self.authSession.isConfigured {
                        self.authSession.errorMessage = "Google sign-in requires Cloud API URL. Add URL and tap Apply first."
                    } else {
                        self.authSession.errorMessage = message
                    }
                }
                return
            }

            guard let tokenString = result?.user.idToken?.tokenString,
                  !tokenString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Task { @MainActor in
                    self.authSession.errorMessage = "Google sign-in did not return an ID token."
                }
                return
            }

            Task { @MainActor in
                await self.authSession.signInWithGoogle(idToken: tokenString)
            }
        }
    }

    @MainActor
    private func bootstrapCloudAPIURLIfNeeded() {
        let resolved = resolvedCloudAPIURLCandidate()
        if cloudAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !resolved.isEmpty {
            cloudAPIURL = resolved
        }
        if !resolved.isEmpty, !authSession.isConfigured {
            let settings = MacAppSettings.shared
            settings.cloudSyncBaseURL = resolved
            authSession.configureBackend(baseURL: resolved)
            CloudSyncService.shared.configure(
                baseURLString: resolved,
                uploadAudio: settings.cloudUploadAudioEnabled
            )
            BillingService.shared.configure(baseURLString: resolved)
        }
    }

    @MainActor
    private func resolvedCloudAPIURLCandidate() -> String {
        let fromAuth = authSession.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromAuth.isEmpty {
            return fromAuth
        }
        let fromSettings = MacAppSettings.shared.cloudSyncBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromSettings.isEmpty {
            return fromSettings
        }
        let fromBundle = (Bundle.main.object(forInfoDictionaryKey: "CLOUD_API_BASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromBundle
    }

    @MainActor
    private func applyCloudAPIURL() {
        let normalized = cloudAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = MacAppSettings.shared
        settings.cloudSyncBaseURL = normalized
        authSession.configureBackend(baseURL: normalized)
        CloudSyncService.shared.configure(
            baseURLString: normalized,
            uploadAudio: settings.cloudUploadAudioEnabled
        )
        BillingService.shared.configure(baseURLString: normalized)
    }
}

@MainActor
final class AppleSignInCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var nonce: String?
    private var onSuccess: ((ASAuthorizationAppleIDCredential, String) -> Void)?
    private var onError: ((Error) -> Void)?
    private var controller: ASAuthorizationController?

    func start(
        onSuccess: @escaping (ASAuthorizationAppleIDCredential, String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onSuccess = onSuccess
        self.onError = onError

        let nonce = NonceHelper.randomNonce()
        self.nonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = NonceHelper.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller // keep strong reference until callback
        controller.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { cleanup() }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let nonce else {
            onError?(AppleSignInError.missingNonce)
            return
        }
        onSuccess?(credential, nonce)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        defer { cleanup() }
        onError?(error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private func cleanup() {
        controller = nil
        nonce = nil
    }

    private enum AppleSignInError: LocalizedError {
        case missingNonce

        var errorDescription: String? {
            switch self {
            case .missingNonce:
                return "Apple sign-in missing nonce."
            }
        }
    }
}
