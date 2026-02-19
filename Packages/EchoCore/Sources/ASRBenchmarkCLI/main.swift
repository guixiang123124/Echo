import Foundation
import EchoCore

struct BenchCase {
    let providerLabel: String
    let providerFactory: () -> (any ASRProvider)?
    let autoEdit: Bool
}

struct BenchResult {
    let audioFile: URL
    let provider: String
    let autoEdit: Bool
    let success: Bool
    let asrLatencyMs: Int
    let autoEditLatencyMs: Int?
    let totalLatencyMs: Int
    let error: String?
    let text: String
}

@main
struct ASRBenchmarkCLI {
    static func main() async {
        let keyStore = SecureKeyStore()

        let inputFiles = resolveInputFiles()
        guard !inputFiles.isEmpty else {
            fputs("No audio files found. Pass file paths as arguments or ensure recordings exist in ~/Library/Containers/com.xianggui.echo.mac/Data/Library/Application Support/Echo/Recordings\n", stderr)
            exit(1)
        }
        fputs("[bench] Testing \(inputFiles.count) audio files\n", stderr)

        // Resolve API keys from env vars first to avoid Keychain popups in CLI
        let openaiKey = Self.resolveOpenAIKey()
        if openaiKey != nil {
            fputs("[bench] Using OpenAI key from environment\n", stderr)
        }

        let correctionProvider = OpenAICorrectionProvider(keyStore: keyStore, apiKey: openaiKey)
        let canAutoEdit = correctionProvider.isAvailable

        var cases: [BenchCase] = []
        for model in ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"] {
            cases.append(BenchCase(providerLabel: "openai:\(model)", providerFactory: {
                OpenAIWhisperProvider(keyStore: keyStore, apiKey: openaiKey, model: model)
            }, autoEdit: false))
            cases.append(BenchCase(providerLabel: "openai:\(model)", providerFactory: {
                OpenAIWhisperProvider(keyStore: keyStore, apiKey: openaiKey, model: model)
            }, autoEdit: true))
        }

        // Optional: include Deepgram when key is provided (env/file).
        let deepgramKey = Self.resolveDeepgramKey()
        if deepgramKey != nil {
            fputs("[bench] Using Deepgram key from environment/file\n", stderr)
        }
        cases.append(BenchCase(providerLabel: "deepgram:nova-3", providerFactory: {
            DeepgramASRProvider(keyStore: keyStore, apiKey: deepgramKey, model: "nova-3", language: nil)
        }, autoEdit: false))
        cases.append(BenchCase(providerLabel: "deepgram:nova-3", providerFactory: {
            DeepgramASRProvider(keyStore: keyStore, apiKey: deepgramKey, model: "nova-3", language: nil)
        }, autoEdit: true))

        // Always include Volcano in benchmark table so availability issues are visible in report.
        // CLI can't reliably access Keychain, so prefer env vars / token file.
        let volcanoKeys = Self.resolveVolcanoKeys()
        cases.append(BenchCase(providerLabel: "volcano", providerFactory: {
            VolcanoASRProvider(keyStore: keyStore, appId: volcanoKeys.appId, accessKey: volcanoKeys.accessKey)
        }, autoEdit: false))
        cases.append(BenchCase(providerLabel: "volcano", providerFactory: {
            VolcanoASRProvider(keyStore: keyStore, appId: volcanoKeys.appId, accessKey: volcanoKeys.accessKey)
        }, autoEdit: true))

        var results: [BenchResult] = []
        for file in inputFiles {
            guard let audio = try? loadAudioChunk(from: file) else {
                results.append(BenchResult(audioFile: file, provider: "ALL", autoEdit: false, success: false, asrLatencyMs: 0, autoEditLatencyMs: nil, totalLatencyMs: 0, error: "Failed to load audio", text: ""))
                continue
            }

            for bench in cases {
                let start = Date()
                guard let provider = bench.providerFactory(), provider.isAvailable else {
                    results.append(BenchResult(audioFile: file, provider: bench.providerLabel, autoEdit: bench.autoEdit, success: false, asrLatencyMs: 0, autoEditLatencyMs: nil, totalLatencyMs: 0, error: "Provider unavailable", text: ""))
                    continue
                }

                do {
                    let asrStart = Date()
                    let transcription = try await provider.transcribe(audio: audio)
                    let asrLatency = Int(Date().timeIntervalSince(asrStart) * 1000)

                    var finalText = transcription.text
                    var autoEditLatency: Int? = nil

                    if bench.autoEdit {
                        guard canAutoEdit else {
                            throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "AutoEdit unavailable (missing OpenAI key)"])
                        }
                        let editStart = Date()
                        let pipeline = CorrectionPipeline(provider: correctionProvider)
                        let corrected = try await pipeline.process(
                            transcription: transcription,
                            context: ConversationContext(),
                            options: CorrectionOptions(enableHomophones: true, enablePunctuation: true, enableFormatting: true)
                        )
                        finalText = corrected.correctedText
                        autoEditLatency = Int(Date().timeIntervalSince(editStart) * 1000)
                    }

                    let total = Int(Date().timeIntervalSince(start) * 1000)
                    results.append(BenchResult(audioFile: file, provider: bench.providerLabel, autoEdit: bench.autoEdit, success: true, asrLatencyMs: asrLatency, autoEditLatencyMs: autoEditLatency, totalLatencyMs: total, error: nil, text: finalText))
                } catch {
                    let total = Int(Date().timeIntervalSince(start) * 1000)
                    results.append(BenchResult(audioFile: file, provider: bench.providerLabel, autoEdit: bench.autoEdit, success: false, asrLatencyMs: 0, autoEditLatencyMs: nil, totalLatencyMs: total, error: error.localizedDescription, text: ""))
                }
            }
        }

        let report = buildReport(results: results, files: inputFiles)
        let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("reports/asr", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outFile = outDir.appendingPathComponent("asr-benchmark-\(ts).md")
        do {
            try report.write(to: outFile, atomically: true, encoding: .utf8)
            print("Wrote report: \(outFile.path)")
        } catch {
            fputs("Failed writing report: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }

    private static func resolveInputFiles() -> [URL] {
        let args = Array(CommandLine.arguments.dropFirst()).map { URL(fileURLWithPath: $0) }
        if !args.isEmpty { return args }

        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.xianggui.echo.mac/Data/Library/Application Support/Echo/Recordings", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: fallback, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
            .prefix(10)
            .map { $0 }
    }

    private static func loadAudioChunk(from fileURL: URL) throws -> AudioChunk {
        let data = try Data(contentsOf: fileURL)
        let wav = try WAVParser.parse(data: data)
        return AudioChunk(
            data: wav.pcmData,
            format: AudioStreamFormat(sampleRate: wav.sampleRate, channelCount: wav.channels, bitsPerSample: wav.bitsPerSample, encoding: .linearPCM),
            duration: wav.duration
        )
    }

    // MARK: - API key resolution (env > file > Keychain fallback)

    private static func resolveOpenAIKey() -> String? {
        // 1. Environment variable
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }
        // 2. Token file
        let tokenPath = NSHomeDirectory() + "/.openai_key"
        if let data = FileManager.default.contents(atPath: tokenPath),
           let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        // 3. Fall through to Keychain (may prompt)
        return nil
    }

    private static func resolveDeepgramKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !key.isEmpty {
            return key
        }
        let tokenPath = NSHomeDirectory() + "/.deepgram_key"
        if let data = FileManager.default.contents(atPath: tokenPath),
           let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        return nil
    }

    private static func resolveVolcanoKeys() -> (appId: String?, accessKey: String?) {
        // 1. Environment variables take top priority
        let envAppId = ProcessInfo.processInfo.environment["VOLCANO_APP_ID"]
        let envAccessKey = ProcessInfo.processInfo.environment["VOLCANO_ACCESS_KEY"]
        if let envAccessKey, !envAccessKey.isEmpty {
            return (appId: envAppId ?? "6490217589", accessKey: envAccessKey)
        }

        // 2. Token file (~/.volcano_token contains the access key)
        let tokenPath = NSHomeDirectory() + "/.volcano_token"
        if let tokenData = FileManager.default.contents(atPath: tokenPath),
           let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            let appId = envAppId ?? "6490217589"
            fputs("[bench] Loaded Volcano access key from ~/.volcano_token (appId=\(appId))\n", stderr)
            return (appId: appId, accessKey: token)
        }

        // 3. Fall through — provider will try Keychain (may fail in CLI)
        return (appId: nil, accessKey: nil)
    }

    private static func buildReport(results: [BenchResult], files: [URL]) -> String {
        var lines: [String] = []
        lines.append("# ASR Benchmark Report")
        lines.append("")
        lines.append("Files: \(files.map { $0.lastPathComponent }.joined(separator: ", "))")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("## Latency / Failure Table")
        lines.append("")
        lines.append("| File | Provider | AutoEdit | Success | ASR ms | AutoEdit ms | Total ms | Error |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---|")
        for r in results {
            lines.append("| \(r.audioFile.lastPathComponent) | \(r.provider) | \(r.autoEdit ? "on" : "off") | \(r.success ? "✅" : "❌") | \(r.asrLatencyMs) | \(r.autoEditLatencyMs.map(String.init) ?? "-") | \(r.totalLatencyMs) | \((r.error ?? "").replacingOccurrences(of: "|", with: "/")) |")
        }
        lines.append("")
        lines.append("## Full Transcription Text")
        lines.append("")
        for r in results where r.success {
            lines.append("### \(r.audioFile.lastPathComponent) · \(r.provider) · AutoEdit \(r.autoEdit ? "ON" : "OFF")")
            lines.append(r.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

private struct WAVParser {
    struct Parsed {
        let pcmData: Data
        let sampleRate: Double
        let channels: Int
        let bitsPerSample: Int
        let duration: TimeInterval
    }

    static func parse(data: Data) throws -> Parsed {
        guard data.count > 44 else { throw NSError(domain: "wav", code: 1, userInfo: [NSLocalizedDescriptionKey: "File too small"]) }
        guard String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE" else {
            throw NSError(domain: "wav", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not a WAV file"])
        }

        var offset = 12
        var sampleRate: Double = 16000
        var channels = 1
        var bits = 16
        var pcm = Data()

        while offset + 8 <= data.count {
            let idData = data.subdata(in: offset..<(offset + 4))
            let id = String(data: idData, encoding: .ascii) ?? ""
            let size = Int(UInt32(littleEndian: data.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes { $0.load(as: UInt32.self) }))
            let bodyStart = offset + 8
            let bodyEnd = bodyStart + size
            guard bodyEnd <= data.count else { break }

            if id == "fmt " {
                let fmt = data.subdata(in: bodyStart..<bodyEnd)
                if fmt.count >= 16 {
                    channels = Int(UInt16(littleEndian: fmt.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) }))
                    sampleRate = Double(UInt32(littleEndian: fmt.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }))
                    bits = Int(UInt16(littleEndian: fmt.subdata(in: 14..<16).withUnsafeBytes { $0.load(as: UInt16.self) }))
                }
            } else if id == "data" {
                pcm = data.subdata(in: bodyStart..<bodyEnd)
            }

            offset = bodyEnd + (size % 2)
        }

        guard !pcm.isEmpty else { throw NSError(domain: "wav", code: 3, userInfo: [NSLocalizedDescriptionKey: "No PCM data chunk"]) }
        let bytesPerSecond = max(1, Int(sampleRate) * channels * max(1, bits / 8))
        return Parsed(pcmData: pcm, sampleRate: sampleRate, channels: channels, bitsPerSample: bits, duration: TimeInterval(pcm.count) / TimeInterval(bytesPerSecond))
    }
}
