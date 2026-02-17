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
        guard inputFiles.count == 2 else {
            fputs("Expected 2 audio files. Pass file paths or ensure 2 recordings exist in ~/Library/Containers/com.xianggui.echo.mac/Data/Library/Application Support/Echo/Recordings\n", stderr)
            exit(1)
        }

        let correctionProvider = OpenAICorrectionProvider(keyStore: keyStore)
        let canAutoEdit = correctionProvider.isAvailable

        var cases: [BenchCase] = []
        for model in ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"] {
            cases.append(BenchCase(providerLabel: "openai:\(model)", providerFactory: {
                OpenAIWhisperProvider(keyStore: keyStore, model: model)
            }, autoEdit: false))
            cases.append(BenchCase(providerLabel: "openai:\(model)", providerFactory: {
                OpenAIWhisperProvider(keyStore: keyStore, model: model)
            }, autoEdit: true))
        }

        let volcanoProvider = VolcanoASRProvider(keyStore: keyStore)
        if volcanoProvider.isAvailable {
            cases.append(BenchCase(providerLabel: "volcano", providerFactory: { VolcanoASRProvider(keyStore: keyStore) }, autoEdit: false))
            cases.append(BenchCase(providerLabel: "volcano", providerFactory: { VolcanoASRProvider(keyStore: keyStore) }, autoEdit: true))
        }

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
        if args.count >= 2 { return Array(args.prefix(2)) }

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
            .prefix(2)
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
