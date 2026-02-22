import Foundation

/// ASR provider using ByteDance Volcano Engine BigModel API (batch mode)
public final class VolcanoASRProvider: ASRProvider, @unchecked Sendable {
    public let id = "volcano"
    public let displayName = "Volcano Engine (火山引擎)"
    public let supportsStreaming = true
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    /// Keychain entry IDs (we store two values for Volcano)
    public static let appIdKeyId = "volcano_app_id"
    public static let accessKeyKeyId = "volcano_access_key"
    public static let resourceIdKeyId = "volcano_resource_id"
    public static let endpointKeyId = "volcano_endpoint"

    private let keyStore: SecureKeyStore
    private let appIdOverride: String?
    private let accessKeyOverride: String?
    private let resourceIdOverride: String?
    private let endpointOverride: String?

    private func diagnosticsLog(_ message: String) {
        print("🧭 VolcanoDiag: \(message)")
    }

    public init(
        keyStore: SecureKeyStore = SecureKeyStore(),
        appId: String? = nil,
        accessKey: String? = nil,
        resourceId: String? = nil,
        apiEndpoint: String? = nil
    ) {
        self.keyStore = keyStore
        self.appIdOverride = appId
        self.accessKeyOverride = accessKey
        self.resourceIdOverride = resourceId
        self.endpointOverride = apiEndpoint
    }

    public var isAvailable: Bool {
        // Allow explicit overrides (useful for tests / dependency injection)
        if let appIdOverride, !appIdOverride.isEmpty,
           let accessKeyOverride, !accessKeyOverride.isEmpty {
            return true
        }

        // Otherwise check Keychain entries
        return keyStore.hasKey(for: Self.appIdKeyId) && keyStore.hasKey(for: Self.accessKeyKeyId)
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard !audio.isEmpty else { throw ASRError.noAudioData }

        let appId = try (appIdOverride ?? keyStore.retrieve(for: Self.appIdKeyId)) ?? ""
        let accessKey = try (accessKeyOverride ?? keyStore.retrieve(for: Self.accessKeyKeyId)) ?? ""
        guard !appId.isEmpty, !accessKey.isEmpty else {
            throw ASRError.apiKeyMissing
        }

        let wavData = AudioFormatHelper.wavData(for: audio)
        let base64Audio = wavData.base64EncodedString()

        let preferredEndpoint = try resolvedEndpointURL()
        let preferredResource = try resolvedResourceId()

        do {
            return try await transcribeViaFlash(
                endpointURL: preferredEndpoint,
                resourceId: preferredResource,
                appId: appId,
                accessKey: accessKey,
                base64Audio: base64Audio
            )
        } catch {
            let message = (error as? ASRError)?.errorDescription ?? error.localizedDescription
            let resourceNotGranted = message.contains("requested resource not granted") || message.contains("45000030")
            if resourceNotGranted {
                let fallbackResources: [String] = {
                    if preferredResource == "volc.bigasr.auc_turbo" {
                        return ["volc.seedasr.auc", "volc.bigasr.auc"]
                    }
                    return [preferredResource]
                }()

                for resource in fallbackResources {
                    if let result = try await transcribeViaSubmitQueryIfPossible(
                        resourceId: resource,
                        appId: appId,
                        accessKey: accessKey,
                        base64Audio: base64Audio
                    ) {
                        return result
                    }
                }
            }
            throw error
        }
    }

    private var streamingSession: VolcanoStreamingSession?

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        do {
            let appId = try (appIdOverride ?? keyStore.retrieve(for: Self.appIdKeyId)) ?? ""
            let accessKey = try (accessKeyOverride ?? keyStore.retrieve(for: Self.accessKeyKeyId)) ?? ""
            guard !appId.isEmpty, !accessKey.isEmpty else {
                return AsyncStream { $0.finish() }
            }

            let resourceId: String
            do {
                let resolved = try resolvedStreamingResourceId()
                resourceId = resolved
                diagnosticsLog("stream resource selected=\(resourceId)")
            } catch {
                diagnosticsLog("stream resource resolution failed: \(error.localizedDescription)")
                return AsyncStream { $0.finish() }
            }

            guard let streamEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async") else {
                diagnosticsLog("invalid stream endpoint URL")
                return AsyncStream { $0.finish() }
            }
            let config = VolcanoStreamingSession.Config(
                appId: appId,
                accessKey: accessKey,
                resourceId: resourceId,
                endpoint: streamEndpoint,
                sampleRate: 16000,
                enableITN: true,
                enablePunc: true,
                enableDDC: false
            )

            let session = VolcanoStreamingSession(config: config)
            self.streamingSession = session
            return session.start()
        } catch {
            return AsyncStream { $0.finish() }
        }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        guard let session = streamingSession else {
            throw ASRError.streamingNotSupported
        }
        session.feedAudio(chunk)
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        guard let session = streamingSession else { return nil }
        let result = await session.stop()
        streamingSession = nil
        return result
    }

    private func resolvedStreamingResourceId() throws -> String {
        let configured = try (resourceIdOverride ?? keyStore.retrieve(for: Self.resourceIdKeyId))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let mapped = Self.mapStreamingResourceId(configured)
        if !Self.isStreamingResourceId(mapped) {
            diagnosticsLog("stream resource remapped to default sauc resource from non-stream pattern: \(mapped)")
            return "volc.bigasr.sauc.duration"
        }
        if let configured, !configured.isEmpty, configured != mapped {
            diagnosticsLog("stream resource remapped from=\(configured) to=\(mapped)")
        }
        return mapped
    }

    static func isStreamingResourceId(_ resourceId: String) -> Bool {
        let lower = resourceId.lowercased()
        return lower.contains(".sauc") || lower.hasSuffix(".sauc")
    }

    static func mapStreamingResourceId(_ configured: String?) -> String {
        guard let configured, !configured.isEmpty else {
            return "volc.bigasr.sauc.duration"
        }

        let configuredLower = configured.lowercased()
        if configuredLower.hasSuffix(".sauc") || configuredLower.contains(".sauc.") {
            return configured
        }

        let aucBasedSuffixes = [
            ".auc_turbo",
            ".auc.duration",
            ".auc_duration",
            ".auc"
        ]

        for suffix in aucBasedSuffixes where configuredLower.hasSuffix(suffix) {
            let trimCount = suffix.count
            let base = String(configured[..<configured.index(configured.endIndex, offsetBy: -trimCount)])
            return "\(base).sauc.duration"
        }

        if configuredLower.contains(".auc") {
            let mapped = configured.replacingOccurrences(of: ".auc", with: ".sauc", options: .literal, range: nil)
            return mapped
        }

        return configured
    }

    // MARK: - Private

    private func resolvedResourceId() throws -> String {
        let resourceId = try (resourceIdOverride ?? keyStore.retrieve(for: Self.resourceIdKeyId))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (resourceId?.isEmpty == false) ? resourceId! : "volc.bigasr.auc_turbo"
    }

    private func resolvedEndpointURL() throws -> URL {
        let endpoint = try (endpointOverride ?? keyStore.retrieve(for: Self.endpointKeyId))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointString = (endpoint?.isEmpty == false) ? endpoint! : "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
        guard let url = URL(string: endpointString) else {
            throw ASRError.apiError("Volcano endpoint is invalid: \(endpointString)")
        }
        return url
    }

    private func transcribeViaFlash(
        endpointURL: URL,
        resourceId: String,
        appId: String,
        accessKey: String,
        base64Audio: String
    ) async throws -> TranscriptionResult {
        let requestId = UUID().uuidString

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "user": ["uid": requestId],
            "audio": [
                "data": base64Audio,
                "format": "wav"
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            let apiCode = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
            let apiMsg = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Api-Message") ?? ""
            throw ASRError.apiError("Volcano HTTP \(statusCode) endpoint=\(endpointURL.absoluteString) resource=\(resourceId) code=\(apiCode) msg=\(apiMsg) body=\(body)")
        }

        return try parseResponse(data: data)
    }

    private func transcribeViaSubmitQueryIfPossible(
        resourceId: String,
        appId: String,
        accessKey: String,
        base64Audio: String
    ) async throws -> TranscriptionResult? {
        guard let submitURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"),
              let queryURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query") else {
            return nil
        }

        let requestId = UUID().uuidString

        var submit = URLRequest(url: submitURL)
        submit.httpMethod = "POST"
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        submit.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        submit.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        submit.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
        submit.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        submit.timeoutInterval = 30
        let submitPayload: [String: Any] = [
            "user": ["uid": requestId],
            "audio": ["data": base64Audio, "format": "wav"],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true]
        ]
        submit.httpBody = try JSONSerialization.data(withJSONObject: submitPayload)

        let (_, submitResp) = try await URLSession.shared.data(for: submit)
        guard let submitHTTP = submitResp as? HTTPURLResponse else { return nil }
        let submitCode = submitHTTP.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
        if submitCode != "20000000" { return nil }

        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var query = URLRequest(url: queryURL)
            query.httpMethod = "POST"
            query.setValue("application/json", forHTTPHeaderField: "Content-Type")
            query.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
            query.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
            query.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
            query.setValue(requestId, forHTTPHeaderField: "X-Api-Request-Id")
            query.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
            query.timeoutInterval = 20
            query.httpBody = Data("{}".utf8)

            let (queryData, queryResp) = try await URLSession.shared.data(for: query)
            guard let queryHTTP = queryResp as? HTTPURLResponse else { continue }
            let queryCode = queryHTTP.value(forHTTPHeaderField: "X-Api-Status-Code") ?? ""
            if queryCode == "20000001" || queryCode == "20000002" { continue }
            if queryCode != "20000000" { return nil }

            let parsed = try parseResponse(data: queryData)
            if !parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return parsed
            }
            return nil
        }

        return nil
    }

    private func parseResponse(data: Data) throws -> TranscriptionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ASRError.transcriptionFailed("Failed to parse Volcano API response")
        }

        if let header = json["header"] as? [String: Any],
           let code = header["code"] as? Int,
           code != 20000000, code != 1000 {
            let message = header["message"] as? String ?? "Unknown error"
            throw ASRError.apiError("Volcano: \(message)")
        }

        if let code = json["code"] as? Int, code != 20000000, code != 1000 {
            let message = json["message"] as? String ?? "Unknown error"
            throw ASRError.apiError("Volcano: \(message)")
        }

        let text: String = {
            if let result = json["result"] as? [String: Any] {
                if let t = result["text"] as? String, !t.isEmpty {
                    return t
                }
                if let utterances = result["utterances"] as? [[String: Any]] {
                    let joined = utterances.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !joined.isEmpty { return joined }
                }
            }

            if let utterances = json["utterances"] as? [[String: Any]] {
                let joined = utterances.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !joined.isEmpty { return joined }
            }

            return (json["text"] as? String) ?? ""
        }()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ASRError.transcriptionFailed("Volcano returned empty transcription")
        }

        return TranscriptionResult(text: trimmed, language: .unknown, isFinal: true)
    }
}
