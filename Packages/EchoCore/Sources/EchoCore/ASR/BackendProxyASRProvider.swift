import Foundation

/// ASR provider that proxies transcription through Echo backend.
/// This keeps third-party provider API keys on the server side.
public final class BackendProxyASRProvider: ASRProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let supportsStreaming = false
    public let requiresNetwork = true
    public let supportedLanguages: Set<String> = ["zh-Hans", "en"]

    private let providerId: String
    private let backendBaseURL: String
    private let accessToken: String
    private let model: String?
    private let language: String?

    public init(
        providerId: String,
        backendBaseURL: String,
        accessToken: String,
        model: String? = nil,
        language: String? = nil
    ) {
        self.providerId = providerId
        self.backendBaseURL = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = providerId
        self.displayName = "\(providerId) (Backend Proxy)"
    }

    public var isAvailable: Bool {
        !backendBaseURL.isEmpty && !accessToken.isEmpty
    }

    public func transcribe(audio: AudioChunk) async throws -> TranscriptionResult {
        guard isAvailable else {
            throw ASRError.providerNotAvailable(displayName)
        }
        guard !audio.isEmpty else {
            throw ASRError.noAudioData
        }

        guard let endpoints = buildEndpoints(), !endpoints.isEmpty else {
            throw ASRError.apiError("Backend ASR proxy URL is invalid")
        }

        let wavData = AudioFormatHelper.wavData(for: audio)
        let body = ProxyRequest(
            provider: providerId,
            audioBase64: wavData.base64EncodedString(),
            audioMimeType: "audio/wav",
            model: normalizedOptional(model),
            language: normalizedOptional(language)
        )

        let encodedBody = try JSONEncoder().encode(body)
        var lastRouteMissMessage: String?

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = encodedBody

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ASRError.apiError("Invalid backend response")
            }

            if (200..<300).contains(httpResponse.statusCode) {
                if let decoded = try? JSONDecoder().decode(ProxyResponse.self, from: data) {
                    let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        throw ASRError.transcriptionFailed("Backend returned empty transcription")
                    }

                    return TranscriptionResult(
                        text: text,
                        language: mapLanguage(decoded.language),
                        isFinal: true
                    )
                }

                let raw = String(data: data, encoding: .utf8) ?? ""
                if looksLikeRouteMismatch(raw) {
                    lastRouteMissMessage = compactErrorMessage(raw)
                    continue
                }
                throw ASRError.apiError("Backend returned unexpected response format")
            }

            let message = extractErrorMessage(data: data) ?? "Backend HTTP \(httpResponse.statusCode)"
            if shouldTryNextEndpoint(statusCode: httpResponse.statusCode, message: message) {
                lastRouteMissMessage = compactErrorMessage(message)
                continue
            }
            throw ASRError.apiError(message)
        }

        let suffix = lastRouteMissMessage ?? "Cannot find supported ASR proxy endpoint."
        throw ASRError.apiError("Backend ASR proxy endpoint mismatch. Verify Cloud API URL and backend deployment. \(suffix)")
    }

    public func startStreaming() -> AsyncStream<TranscriptionResult> {
        AsyncStream { $0.finish() }
    }

    public func feedAudio(_ chunk: AudioChunk) async throws {
        _ = chunk
        throw ASRError.streamingNotSupported
    }

    public func stopStreaming() async throws -> TranscriptionResult? {
        nil
    }

    private func buildEndpoints() -> [URL]? {
        let normalized: String
        if backendBaseURL.hasPrefix("http://") || backendBaseURL.hasPrefix("https://") {
            normalized = backendBaseURL
        } else {
            normalized = "https://\(backendBaseURL)"
        }

        guard let baseURL = URL(string: normalized) else {
            return nil
        }

        var endpoints: [URL] = []
        func append(_ candidate: URL?) {
            guard let candidate else { return }
            if !endpoints.contains(candidate) {
                endpoints.append(candidate)
            }
        }

        // Root-relative routes (most common)
        append(URL(string: "/v1/asr/transcribe", relativeTo: baseURL))
        append(URL(string: "/api/v1/asr/transcribe", relativeTo: baseURL))
        append(URL(string: "/api/asr/transcribe", relativeTo: baseURL))

        // Prefix-preserving routes (for deployments mounted under subpaths)
        let scopedBaseRaw = normalized.hasSuffix("/") ? normalized : normalized + "/"
        if let scopedBaseURL = URL(string: scopedBaseRaw) {
            append(URL(string: "v1/asr/transcribe", relativeTo: scopedBaseURL))
            append(URL(string: "api/v1/asr/transcribe", relativeTo: scopedBaseURL))
            append(URL(string: "asr/transcribe", relativeTo: scopedBaseURL))
        }

        return endpoints
    }

    private func shouldTryNextEndpoint(statusCode: Int, message: String) -> Bool {
        if statusCode == 404 || statusCode == 405 {
            return true
        }
        return looksLikeRouteMismatch(message)
    }

    private func looksLikeRouteMismatch(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("cannot post")
            || lower.contains("not found")
            || lower.contains("route")
            || lower.contains("<!doctype html")
    }

    private func compactErrorMessage(_ value: String, limit: Int = 180) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "..."
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func extractErrorMessage(data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
        }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            return raw
        }
        return nil
    }

    private func mapLanguage(_ value: String?) -> RecognizedLanguage {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized.hasPrefix("zh") {
            return .chinese
        }
        if normalized.hasPrefix("en") {
            return .english
        }
        if normalized.contains("mixed") || normalized.contains("mix") {
            return .mixed
        }
        return .unknown
    }
}

private struct ProxyRequest: Encodable {
    let provider: String
    let audioBase64: String
    let audioMimeType: String
    let model: String?
    let language: String?
}

private struct ProxyResponse: Decodable {
    let provider: String?
    let mode: String?
    let model: String?
    let language: String?
    let text: String
}
