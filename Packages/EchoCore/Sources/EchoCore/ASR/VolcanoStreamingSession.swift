import Foundation
import Compression

/// Manages a single WebSocket streaming ASR session with Volcano Engine BigModel.
///
/// Protocol: Custom binary frames over WebSocket.
///   Header (4 bytes):
///     byte 0: [version (4b)][header_size (4b)]   → 0x11
///     byte 1: [msg_type (4b)][flags (4b)]
///     byte 2: [serialization (4b)][compression (4b)]
///     byte 3: reserved → 0x00
///   Then: payload_size (4 bytes, big-endian UInt32), payload (bytes)
///
///   msg_type: 0x1 = full client request, 0x2 = audio only, 0x9 = server response, 0xF = error
///   flags:    0x0 = no seq, 0x1 = has positive seq, 0x2 = last packet (no seq), 0x3 = last packet (with seq)
///   serialization: 0x0 = none, 0x1 = JSON
///   compression:   0x0 = none, 0x1 = gzip
final class VolcanoStreamingSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {

    // MARK: - Configuration

    struct Config {
        let appId: String
        let accessKey: String
        let resourceId: String
        let endpoint: URL
        let sampleRate: Int
        let enableITN: Bool
        let enablePunc: Bool
        let enableDDC: Bool
    }

    // MARK: - State

    private let config: Config
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<TranscriptionResult>.Continuation?
    private var isConnected = false
    private var sequenceNumber: Int32 = 0
    private let lock = NSLock()

    // MARK: - Init

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - Public API

    /// Start the streaming session.  Returns an AsyncStream that yields partial results.
    func start() -> AsyncStream<TranscriptionResult> {
        let stream = AsyncStream<TranscriptionResult> { continuation in
            self.continuation = continuation

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.disconnect()
            }
        }

        connect()
        return stream
    }

    /// Feed a chunk of PCM audio (16-bit LE, 16 kHz, mono).
    func feedAudio(_ chunk: AudioChunk) {
        guard isConnected else { return }
        sendAudioFrame(data: chunk.data, isLast: false)
    }

    /// Signal end of audio and wait for final result.
    func stop() async -> TranscriptionResult? {
        guard isConnected else { return nil }

        // Send empty last packet
        sendAudioFrame(data: Data(), isLast: true)

        // Wait briefly for final response before tearing down
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        disconnect()
        return nil
    }

    // MARK: - WebSocket Connection

    private func connect() {
        var request = URLRequest(url: config.endpoint)
        request.setValue(config.appId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(config.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        // Wait for connection then send full client request
        // (delegate will call urlSession(_:webSocketTask:didOpenWithProtocol:))
    }

    private func disconnect() {
        lock.lock()
        let wasConnected = isConnected
        isConnected = false
        lock.unlock()

        if wasConnected {
            task?.cancel(with: .goingAway, reason: nil)
        }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.lock()
        isConnected = true
        lock.unlock()

        // Send full client request
        sendFullClientRequest()

        // Start receive loop
        receiveLoop()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        isConnected = false
        lock.unlock()
        continuation?.finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            print("⚠️ Volcano WS error: \(error.localizedDescription)")
        }
        lock.lock()
        isConnected = false
        lock.unlock()
        continuation?.finish()
    }

    // MARK: - Binary Protocol

    private func sendFullClientRequest() {
        let payload: [String: Any] = [
            "user": ["uid": UUID().uuidString],
            "audio": [
                "format": "pcm",
                "rate": config.sampleRate,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": config.enableITN,
                "enable_punc": config.enablePunc,
                "enable_ddc": config.enableDDC,
                "show_utterances": true,
                "result_type": "full"
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        // Use uncompressed JSON payload for protocol stability.
        // (Volcano expects true gzip when compression=0x1; avoid mismatches.)
        let frame = buildFrame(
            messageType: 0x1,  // full client request
            flags: 0x0,        // no sequence
            serialization: 0x1, // JSON
            compression: 0x0,
            payload: jsonData
        )

        task?.send(.data(frame)) { error in
            if let error {
                print("⚠️ Volcano WS send full request error: \(error.localizedDescription)")
            }
        }
    }

    private func sendAudioFrame(data: Data, isLast: Bool) {
        let flags: UInt8 = isLast ? 0x2 : 0x0
        let frame = buildFrame(
            messageType: 0x2,   // audio only request
            flags: flags,
            serialization: 0x0, // no serialization
            compression: 0x0,   // no compression for audio
            payload: data
        )

        task?.send(.data(frame)) { error in
            if let error {
                print("⚠️ Volcano WS send audio error: \(error.localizedDescription)")
            }
        }
    }

    private func buildFrame(messageType: UInt8, flags: UInt8, serialization: UInt8,
                            compression: UInt8, payload: Data) -> Data {
        var frame = Data(capacity: 8 + payload.count)

        // Byte 0: version (0001) | header_size (0001)
        frame.append(0x11)
        // Byte 1: msg_type | flags
        frame.append((messageType << 4) | (flags & 0x0F))
        // Byte 2: serialization | compression
        frame.append((serialization << 4) | (compression & 0x0F))
        // Byte 3: reserved
        frame.append(0x00)

        // Payload size (big-endian UInt32)
        var size = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))

        // Payload
        frame.append(payload)

        return frame
    }

    // MARK: - Receive Loop

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleServerFrame(data)
                case .string(let text):
                    // Unexpected text frame
                    print("⚠️ Volcano WS unexpected text: \(text.prefix(200))")
                @unknown default:
                    break
                }

                // Continue receiving
                if self.isConnected {
                    self.receiveLoop()
                }

            case .failure(let error):
                print("⚠️ Volcano WS receive error: \(error.localizedDescription)")
                self.continuation?.finish()
            }
        }
    }

    private func handleServerFrame(_ data: Data) {
        guard data.count >= 4 else { return }

        let msgType = (data[1] >> 4) & 0x0F
        let compression = data[2] & 0x0F

        if msgType == 0xF {
            // Error message
            handleErrorFrame(data)
            return
        }

        guard msgType == 0x9 else { return } // full server response

        // Skip header (4 bytes) + sequence number (4 bytes)
        let headerSize = Int(data[0] & 0x0F) * 4
        var offset = headerSize

        // Check if there's a sequence number (flags bit 0)
        let flags = data[1] & 0x0F
        if flags & 0x01 != 0 {
            offset += 4 // skip sequence number
        }

        guard offset + 4 <= data.count else { return }

        // Read payload size
        let payloadSize = Int(UInt32(bigEndian: data.subdata(in: offset..<(offset + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self) }))
        offset += 4

        guard offset + payloadSize <= data.count else { return }

        var payloadData = data.subdata(in: offset..<(offset + payloadSize))

        // Decompress if gzip
        if compression == 0x1 {
            payloadData = gunzip(payloadData) ?? payloadData
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let text = result["text"] as? String else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check if any utterance is definite (final for that segment)
        var isFinal = false
        if let utterances = result["utterances"] as? [[String: Any]] {
            isFinal = utterances.contains { ($0["definite"] as? Bool) == true }
        }

        let transcription = TranscriptionResult(text: trimmed, language: .unknown, isFinal: isFinal)
        continuation?.yield(transcription)
    }

    private func handleErrorFrame(_ data: Data) {
        guard data.count >= 12 else { return }

        let headerSize = Int(data[0] & 0x0F) * 4

        let errorCode = UInt32(bigEndian: data.subdata(in: headerSize..<(headerSize + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self) })

        let msgSize = Int(UInt32(bigEndian: data.subdata(in: (headerSize + 4)..<(headerSize + 8))
            .withUnsafeBytes { $0.load(as: UInt32.self) }))

        let msgEnd = min(headerSize + 8 + msgSize, data.count)
        let errorMsg = String(data: data.subdata(in: (headerSize + 8)..<msgEnd), encoding: .utf8) ?? "Unknown"

        print("⚠️ Volcano WS server error \(errorCode): \(errorMsg)")
        continuation?.finish()
    }

    // MARK: - Gzip helpers (using shell-level NSData + Compression)

    private func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // Use a simple gzip via NSData + compression_encode_buffer
        let sourceSize = data.count
        // Worst case output: source + overhead
        let destinationSize = sourceSize + 512
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, destinationSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), sourceSize,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    private func gunzip(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }

        // Allocate generous output buffer
        let destinationSize = data.count * 10
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }

        // Try to skip gzip header (10 bytes) if present
        let sourceData: Data
        if data.count > 10, data[0] == 0x1f, data[1] == 0x8b {
            sourceData = data.dropFirst(10)
        } else {
            sourceData = data
        }

        let decompressedSize = sourceData.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, destinationSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), sourceData.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}
