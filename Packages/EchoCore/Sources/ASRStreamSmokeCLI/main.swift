import Foundation
import EchoCore

@main
struct ASRStreamSmokeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            fputs("Usage: ASRStreamSmokeCLI <deepgram|volcano> <audio.wav>\n", stderr)
            exit(1)
        }

        let providerName = args[0]
        let fileURL = URL(fileURLWithPath: args[1])

        guard let audio = try? loadAudioChunk(from: fileURL) else {
            fputs("Failed to load wav: \(fileURL.path)\n", stderr)
            exit(2)
        }

        let provider: any ASRProvider
        switch providerName {
        case "deepgram":
            let key = resolveDeepgramKey()
            provider = DeepgramASRProvider(apiKey: key, model: "nova-3", language: nil)
        case "volcano":
            let v = resolveVolcanoKeys()
            provider = VolcanoASRProvider(appId: v.appId, accessKey: v.accessKey)
        default:
            fputs("Unknown provider: \(providerName)\n", stderr)
            exit(1)
        }

        guard provider.isAvailable else {
            fputs("Provider not available: \(providerName)\n", stderr)
            exit(3)
        }

        let stream = provider.startStreaming()
        let streamTask: Task<Void, Never>? = Task {
             for await result in stream {
                 print("[stream][\(result.isFinal ? "final" : "partial")] \(result.text)")
             }
         }

        // Give provider a brief moment to establish WS session.
        try? await Task.sleep(for: .milliseconds(900))

        let bytesPerSecond = audio.format.bytesPerSecond
        let chunkDuration: Double = 0.2
        let chunkSize = Int(Double(bytesPerSecond) * chunkDuration)

        var offset = 0
        while offset < audio.data.count {
            let end = min(offset + chunkSize, audio.data.count)
            let slice = audio.data.subdata(in: offset..<end)
            let chunk = AudioChunk(data: slice, format: audio.format, duration: Double(slice.count) / Double(bytesPerSecond))
            var sent = false
            for _ in 0..<8 {
                do {
                    try await provider.feedAudio(chunk)
                    sent = true
                    break
                } catch {
                    // Stream may still be connecting.
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            if !sent {
                fputs("feedAudio failed after retries\n", stderr)
                exit(4)
            }
            offset = end
            try? await Task.sleep(for: .milliseconds(200))
        }

        do {
            let final = try await provider.stopStreaming()
            if let final {
                print("[stop][final] \(final.text)")
            } else {
                print("[stop] no final object, check stream finals above")
            }
        } catch {
            fputs("stopStreaming failed: \(error.localizedDescription)\n", stderr)
            exit(5)
        }

        try? await Task.sleep(for: .milliseconds(500))
        streamTask?.cancel()
    }

    private static func resolveDeepgramKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !key.isEmpty { return key }
        let path = NSHomeDirectory() + "/.deepgram_key"
        if let data = FileManager.default.contents(atPath: path),
           let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        return nil
    }

    private static func resolveVolcanoKeys() -> (appId: String?, accessKey: String?) {
        let envAppId = ProcessInfo.processInfo.environment["VOLCANO_APP_ID"]
        let envAccessKey = ProcessInfo.processInfo.environment["VOLCANO_ACCESS_KEY"]
        if let envAccessKey, !envAccessKey.isEmpty {
            return (envAppId ?? "6490217589", envAccessKey)
        }
        let tokenPath = NSHomeDirectory() + "/.volcano_token"
        if let tokenData = FileManager.default.contents(atPath: tokenPath),
           let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return (envAppId ?? "6490217589", token)
        }
        return (nil, nil)
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
