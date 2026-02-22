import Foundation
import SQLite3
import EchoCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local persistence for audio + transcription metadata.
/// Stores WAV files on disk and metadata in SQLite.
public actor RecordingStore {
    public static let shared = RecordingStore()

    public struct SchemaHealth: Sendable {
        public let databasePath: String
        public let schemaVersion: Int
        public let requiredColumns: [String]
        public let missingColumns: [String]

        public var isHealthy: Bool {
            missingColumns.isEmpty
        }
    }

    public struct ProviderHealthScore: Identifiable, Sendable, Hashable {
        public var id: String { providerId }

        public let providerId: String
        public let providerName: String
        public let sampleCount: Int
        public let successRate: Double
        public let averageAsrLatencyMs: Double
        public let truncationRate: Double
        public let fallbackRate: Double

        public var healthScore: Double {
            let successComponent = successRate * 65.0
            let latencyFactor = max(0.0, min(1.0, 1.0 - (averageAsrLatencyMs / 3500.0)))
            let latencyComponent = latencyFactor * 20.0
            let truncationPenalty = truncationRate * 10.0
            let fallbackPenalty = fallbackRate * 5.0
            return max(0.0, min(100.0, successComponent + latencyComponent - truncationPenalty - fallbackPenalty))
        }
    }

    public struct RecordingEntry: Identifiable, Sendable, Hashable {
        public let id: Int64
        public let createdAt: Date
        public let duration: TimeInterval
        public let sampleRate: Double
        public let channelCount: Int
        public let bitsPerSample: Int
        public let encoding: String
        public let audioPath: String
        public let asrProviderId: String
        public let asrProviderName: String
        public let correctionProviderId: String?
        public let transcriptRaw: String?
        public let transcriptFinal: String?
        public let wordCount: Int
        public let error: String?
        public let status: String
        public let userId: String?
        public let asrLatencyMs: Int?
        public let correctionLatencyMs: Int?
        public let totalLatencyMs: Int?
        public let streamMode: String?
        public let firstPartialMs: Int?
        public let firstFinalMs: Int?
        public let fallbackUsed: Bool
        public let errorCode: String?
        public let traceId: String

        public var audioURL: URL? {
            audioPath.isEmpty ? nil : URL(fileURLWithPath: audioPath)
        }
    }

    public struct StorageInfo: Sendable {
        public let baseDirectory: URL
        public let recordingsDirectory: URL
        public let databaseURL: URL
        public let entryCount: Int
    }

    public struct AuditEvent: Identifiable, Sendable, Hashable {
        public let id: Int64
        public let createdAt: Date
        public let traceId: String
        public let stage: String
        public let event: String
        public let providerId: String?
        public let latencyMs: Int?
        public let changed: Bool?
        public let message: String?
    }

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let recordingsDirectory: URL
    private let databaseURL: URL
    private var db: OpaquePointer?
    private var lastCleanup: Date?
    private static let targetSchemaVersion = 3
    private static let requiredColumns: [String] = [
        "created_at",
        "duration",
        "sample_rate",
        "channel_count",
        "bits_per_sample",
        "encoding",
        "audio_path",
        "asr_provider_id",
        "asr_provider_name",
        "correction_provider_id",
        "transcript_raw",
        "transcript_final",
        "word_count",
        "error",
        "status",
        "user_id",
        "asr_latency_ms",
        "correction_latency_ms",
        "total_latency_ms",
        "stream_mode",
        "first_partial_ms",
        "first_final_ms",
        "fallback_used",
        "error_code",
        "trace_id"
    ]
    private var retentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: "echo.history.retentionDays")
        return stored == 0 ? 7 : stored
    }

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDirectory = appSupport.appendingPathComponent("Echo", isDirectory: true)
        recordingsDirectory = baseDirectory.appendingPathComponent("Recordings", isDirectory: true)
        databaseURL = baseDirectory.appendingPathComponent("echo.sqlite")

        Self.createDirectories(
            fileManager: fileManager,
            baseDirectory: baseDirectory,
            recordingsDirectory: recordingsDirectory
        )
        db = Self.openDatabase(at: databaseURL)
        Self.createTables(in: db)
        Self.migrateSchemaIfNeeded(in: db)
        Self.ensureTargetSchemaVersion(in: db)
        Self.backfillStreamingDefaults(in: db)
        let health = Self.reportSchemaHealth(databaseURL: databaseURL, db: db, requiredColumns: Self.requiredColumns, targetVersion: Self.targetSchemaVersion)
        if !health.isHealthy {
            print("❌ RecordingStore: startup schema health failed. missing=\(health.missingColumns.joined(separator: ","))")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Public API

    public func saveRecording(
        audio: AudioChunk,
        asrProviderId: String,
        asrProviderName: String,
        correctionProviderId: String?,
        transcriptRaw: String?,
        transcriptFinal: String?,
        error: String?,
        userId: String?,
        asrLatencyMs: Int? = nil,
        correctionLatencyMs: Int? = nil,
        totalLatencyMs: Int? = nil,
        streamMode: String? = nil,
        firstPartialMs: Int? = nil,
        firstFinalMs: Int? = nil,
        fallbackUsed: Bool = false,
        errorCode: String? = nil,
        traceId: String? = nil
    ) {
        guard let db else {
            print("❌ RecordingStore: database not available")
            return
        }
        let health = Self.reportSchemaHealth(
            databaseURL: databaseURL,
            db: db,
            requiredColumns: Self.requiredColumns,
            targetVersion: Self.targetSchemaVersion
        )
        guard health.isHealthy else {
            print("❌ RecordingStore: aborting save. required columns missing=\(health.missingColumns.joined(separator: ","))")
            return
        }

        let normalizedStreamMode: String = {
            if let mode = streamMode?.trimmingCharacters(in: .whitespacesAndNewlines), !mode.isEmpty {
                return mode
            }
            return "batch"
        }()

        let normalizedFirstPartialMs = firstPartialMs ?? -1
        let normalizedFirstFinalMs = firstFinalMs ?? -1
        let normalizedErrorCode: String = {
            if let code = errorCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
                return code
            }
            return "none"
        }()
        let normalizedTraceId: String = {
            if let traceId = traceId?.trimmingCharacters(in: .whitespacesAndNewlines), !traceId.isEmpty {
                return traceId
            }
            return UUID().uuidString.lowercased()
        }()

        let createdAt = Date().timeIntervalSince1970
        let fileName = "\(Int(createdAt * 1000))-\(UUID().uuidString).wav"
        let fileURL = recordingsDirectory.appendingPathComponent(fileName)

        var storedError = error
        var audioPath = fileURL.path
        do {
            let wavData = AudioFormatHelper.wavData(for: audio)
            try wavData.write(to: fileURL, options: .atomic)
        } catch {
            audioPath = ""
            let writeError = "Failed to write audio file: \(error.localizedDescription)"
            storedError = storedError == nil ? writeError : "\(storedError ?? "") | \(writeError)"
            print("❌ RecordingStore: \(writeError)")
        }

        let status = storedError == nil ? "success" : "error"
        let wordCount = transcriptFinal?.split { $0.isWhitespace }.count ?? 0

        let sql = """
        INSERT INTO recordings (
            created_at,
            duration,
            sample_rate,
            channel_count,
            bits_per_sample,
            encoding,
            audio_path,
            asr_provider_id,
            asr_provider_name,
            correction_provider_id,
            transcript_raw,
            transcript_final,
            word_count,
            error,
            status,
            user_id,
            asr_latency_ms,
            correction_latency_ms,
            total_latency_ms,
            stream_mode,
            first_partial_ms,
            first_final_ms,
            fallback_used,
            error_code,
            trace_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            print("❌ RecordingStore: Failed to prepare insert statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, createdAt)
        sqlite3_bind_double(stmt, 2, audio.duration)
        sqlite3_bind_double(stmt, 3, audio.format.sampleRate)
        sqlite3_bind_int(stmt, 4, Int32(audio.format.channelCount))
        sqlite3_bind_int(stmt, 5, Int32(audio.format.bitsPerSample))
        bindText(stmt, index: 6, value: audio.format.encoding.rawValue)
        bindText(stmt, index: 7, value: audioPath)
        bindText(stmt, index: 8, value: asrProviderId)
        bindText(stmt, index: 9, value: asrProviderName)
        bindText(stmt, index: 10, value: correctionProviderId)
        bindText(stmt, index: 11, value: transcriptRaw)
        bindText(stmt, index: 12, value: transcriptFinal)
        sqlite3_bind_int(stmt, 13, Int32(wordCount))
        bindText(stmt, index: 14, value: storedError)
        bindText(stmt, index: 15, value: status)
        bindText(stmt, index: 16, value: userId)
        if let asrLatencyMs {
            sqlite3_bind_int(stmt, 17, Int32(asrLatencyMs))
        } else {
            sqlite3_bind_null(stmt, 17)
        }
        if let correctionLatencyMs {
            sqlite3_bind_int(stmt, 18, Int32(correctionLatencyMs))
        } else {
            sqlite3_bind_null(stmt, 18)
        }
        if let totalLatencyMs {
            sqlite3_bind_int(stmt, 19, Int32(totalLatencyMs))
        } else {
            sqlite3_bind_null(stmt, 19)
        }
        bindText(stmt, index: 20, value: normalizedStreamMode)
        sqlite3_bind_int(stmt, 21, Int32(normalizedFirstPartialMs))
        sqlite3_bind_int(stmt, 22, Int32(normalizedFirstFinalMs))
        sqlite3_bind_int(stmt, 23, fallbackUsed ? 1 : 0)
        bindText(stmt, index: 24, value: normalizedErrorCode)
        bindText(stmt, index: 25, value: normalizedTraceId)

        var insertedId: Int64?
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("❌ RecordingStore: Failed to insert recording")
        } else {
            insertedId = sqlite3_last_insert_rowid(db)
            Task { @MainActor in
                NotificationCenter.default.post(name: .echoRecordingSaved, object: nil)
            }
        }

        cleanupIfNeeded()

        if let insertedId, storedError == nil || transcriptRaw != nil || transcriptFinal != nil {
            let payload = CloudRecording(
                id: String(insertedId),
                createdAt: Date(timeIntervalSince1970: createdAt),
                duration: audio.duration,
                sampleRate: audio.format.sampleRate,
                channelCount: audio.format.channelCount,
                bitsPerSample: audio.format.bitsPerSample,
                encoding: audio.format.encoding.rawValue,
                asrProviderId: asrProviderId,
                asrProviderName: asrProviderName,
                correctionProviderId: correctionProviderId,
                transcriptRaw: transcriptRaw,
                transcriptFinal: transcriptFinal,
                wordCount: wordCount,
                status: status,
                error: storedError,
                audioStoragePath: nil,
                audioDownloadURL: nil,
                deviceId: Host.current().localizedName ?? "macOS"
            )
            let audioURL = audioPath.isEmpty ? nil : URL(fileURLWithPath: audioPath)
            Task { @MainActor in
                await CloudSyncService.shared.syncRecording(payload, audioURL: audioURL)
            }
        }
    }

    public func appendAuditEvent(
        traceId: String,
        stage: String,
        event: String,
        providerId: String? = nil,
        latencyMs: Int? = nil,
        changed: Bool? = nil,
        message: String? = nil
    ) {
        guard let db else { return }
        let normalizedTraceId = traceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTraceId.isEmpty else { return }

        let sql = """
        INSERT INTO recording_audit_events (
            created_at,
            trace_id,
            stage,
            event,
            provider_id,
            latency_ms,
            changed,
            message
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            print("❌ RecordingStore: Failed to prepare audit insert statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        bindText(stmt, index: 2, value: normalizedTraceId)
        bindText(stmt, index: 3, value: stage)
        bindText(stmt, index: 4, value: event)
        bindText(stmt, index: 5, value: providerId)
        if let latencyMs {
            sqlite3_bind_int(stmt, 6, Int32(latencyMs))
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let changed {
            sqlite3_bind_int(stmt, 7, changed ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        bindText(stmt, index: 8, value: message)

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("❌ RecordingStore: Failed to insert audit event stage=\(stage) event=\(event)")
        }
    }

    public func applyDeferredPolishResult(
        traceId: String,
        transcriptFinal: String,
        correctionLatencyMs: Int?,
        correctionProviderId: String?
    ) {
        guard let db else { return }
        let normalizedTraceId = traceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTraceId.isEmpty else { return }

        let final = transcriptFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = final.split { $0.isWhitespace }.count

        let sql = """
        UPDATE recordings
        SET transcript_final = ?,
            word_count = ?,
            correction_latency_ms = ?,
            correction_provider_id = COALESCE(?, correction_provider_id)
        WHERE id = (
            SELECT id
            FROM recordings
            WHERE trace_id = ?
            ORDER BY id DESC
            LIMIT 1
        );
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            print("❌ RecordingStore: Failed to prepare deferred polish update statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: final)
        sqlite3_bind_int(stmt, 2, Int32(wordCount))
        if let correctionLatencyMs {
            sqlite3_bind_int(stmt, 3, Int32(correctionLatencyMs))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        bindText(stmt, index: 4, value: correctionProviderId)
        bindText(stmt, index: 5, value: normalizedTraceId)

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("❌ RecordingStore: Failed to apply deferred polish result for trace=\(normalizedTraceId)")
            return
        }

        Task { @MainActor in
            NotificationCenter.default.post(name: .echoRecordingSaved, object: nil)
        }
    }

    public func schemaHealth() -> SchemaHealth {
        Self.reportSchemaHealth(
            databaseURL: databaseURL,
            db: db,
            requiredColumns: Self.requiredColumns,
            targetVersion: Self.targetSchemaVersion
        )
    }

    public func fetchRecent(limit: Int = 100, userId: String? = nil) -> [RecordingEntry] {
        guard let db else { return [] }

        if let userId, !userId.isEmpty {
            ensureUserScope(userId: userId)
        }

        let sql: String
        if let userId, !userId.isEmpty {
            sql = """
            SELECT id, created_at, duration, sample_rate, channel_count, bits_per_sample,
                   encoding, audio_path, asr_provider_id, asr_provider_name,
                   correction_provider_id, transcript_raw, transcript_final,
                   word_count, error, status, user_id,
                   asr_latency_ms, correction_latency_ms, total_latency_ms,
                   stream_mode, first_partial_ms, first_final_ms, fallback_used, error_code, trace_id
            FROM recordings
            WHERE user_id = ? OR user_id IS NULL OR user_id = ''
            ORDER BY created_at DESC
            LIMIT ?;
            """
        } else {
            sql = """
        SELECT id, created_at, duration, sample_rate, channel_count, bits_per_sample,
               encoding, audio_path, asr_provider_id, asr_provider_name,
               correction_provider_id, transcript_raw, transcript_final,
               word_count, error, status, user_id,
               asr_latency_ms, correction_latency_ms, total_latency_ms,
               stream_mode, first_partial_ms, first_final_ms, fallback_used, error_code, trace_id
        FROM recordings
        ORDER BY created_at DESC
        LIMIT ?;
        """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        if let userId, !userId.isEmpty {
            bindText(stmt, index: 1, value: userId)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }

        var entries: [RecordingEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let duration = sqlite3_column_double(stmt, 2)
            let sampleRate = sqlite3_column_double(stmt, 3)
            let channelCount = Int(sqlite3_column_int(stmt, 4))
            let bitsPerSample = Int(sqlite3_column_int(stmt, 5))
            let encoding = columnText(stmt, index: 6) ?? "linear16"
            let audioPath = columnText(stmt, index: 7) ?? ""
            let asrProviderId = columnText(stmt, index: 8) ?? "openai_whisper"
            let asrProviderName = columnText(stmt, index: 9) ?? "OpenAI Whisper"
            let correctionProviderId = columnText(stmt, index: 10)
            let transcriptRaw = columnText(stmt, index: 11)
            let transcriptFinal = columnText(stmt, index: 12)
            let wordCount = Int(sqlite3_column_int(stmt, 13))
            let error = columnText(stmt, index: 14)
            let status = columnText(stmt, index: 15) ?? "success"
            let userId = columnText(stmt, index: 16)
            let asrLatencyMs = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 17))
            let correctionLatencyMs = sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 18))
            let totalLatencyMs = sqlite3_column_type(stmt, 19) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 19))
            let streamMode = columnText(stmt, index: 20)
            let firstPartialMs = sqlite3_column_type(stmt, 21) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 21))
            let firstFinalMs = sqlite3_column_type(stmt, 22) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 22))
            let fallbackUsed = sqlite3_column_int(stmt, 23) != 0
            let errorCode = columnText(stmt, index: 24)
            let traceId = columnText(stmt, index: 25) ?? "missing-trace"

            entries.append(
                RecordingEntry(
                    id: id,
                    createdAt: createdAt,
                    duration: duration,
                    sampleRate: sampleRate,
                    channelCount: channelCount,
                    bitsPerSample: bitsPerSample,
                    encoding: encoding,
                    audioPath: audioPath,
                    asrProviderId: asrProviderId,
                    asrProviderName: asrProviderName,
                    correctionProviderId: correctionProviderId,
                    transcriptRaw: transcriptRaw,
                    transcriptFinal: transcriptFinal,
                    wordCount: wordCount,
                    error: error,
                    status: status,
                    userId: userId,
                    asrLatencyMs: asrLatencyMs,
                    correctionLatencyMs: correctionLatencyMs,
                    totalLatencyMs: totalLatencyMs,
                    streamMode: streamMode,
                    firstPartialMs: firstPartialMs,
                    firstFinalMs: firstFinalMs,
                    fallbackUsed: fallbackUsed,
                    errorCode: errorCode,
                    traceId: traceId
                )
            )
        }

        return entries
    }


    public func providerHealthScores(limit: Int = 120) -> [ProviderHealthScore] {
        let records = fetchRecent(limit: max(10, limit))
        guard !records.isEmpty else { return [] }

        struct ProviderKey: Hashable {
            let id: String
            let name: String
        }

        let grouped = Dictionary(grouping: records) { record in
            ProviderKey(id: record.asrProviderId, name: record.asrProviderName)
        }

        let scores: [ProviderHealthScore] = grouped.map { key, items in
            let sampleCount = items.count
            let successCount = items.filter { item in
                let hasErrorText = !(item.error?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ?? true)
                let code = item.errorCode?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased() ?? "none"
                return item.status == "success" && !hasErrorText && (code.isEmpty || code == "none")
            }.count

            let latencyValues = items.compactMap { item in
                item.asrLatencyMs ?? item.totalLatencyMs
            }
            let averageLatency = latencyValues.isEmpty
                ? 0
                : Double(latencyValues.reduce(0, +)) / Double(latencyValues.count)

            let truncationCount = items.filter { Self.isLikelyTruncatedRecording($0) }.count
            let fallbackCount = items.filter(\.fallbackUsed).count

            return ProviderHealthScore(
                providerId: key.id,
                providerName: key.name,
                sampleCount: sampleCount,
                successRate: sampleCount == 0 ? 0 : Double(successCount) / Double(sampleCount),
                averageAsrLatencyMs: averageLatency,
                truncationRate: sampleCount == 0 ? 0 : Double(truncationCount) / Double(sampleCount),
                fallbackRate: sampleCount == 0 ? 0 : Double(fallbackCount) / Double(sampleCount)
            )
        }

        return scores.sorted {
            if $0.healthScore == $1.healthScore {
                return $0.sampleCount > $1.sampleCount
            }
            return $0.healthScore > $1.healthScore
        }
    }


    public func storageInfo() -> StorageInfo {
        let count = countEntries()
        return StorageInfo(
            baseDirectory: baseDirectory,
            recordingsDirectory: recordingsDirectory,
            databaseURL: databaseURL,
            entryCount: count
        )
    }

    public func ensureUserScope(userId: String) {
        guard let db else { return }
        let sql = "UPDATE recordings SET user_id = ? WHERE user_id IS NULL OR user_id = '';"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: userId)
        sqlite3_step(stmt)
    }

    public func migrateUser(from oldUserId: String, to newUserId: String) {
        guard let db else { return }
        guard !oldUserId.isEmpty, !newUserId.isEmpty, oldUserId != newUserId else { return }
        let sql = "UPDATE recordings SET user_id = ? WHERE user_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: newUserId)
        bindText(stmt, index: 2, value: oldUserId)
        sqlite3_step(stmt)
    }

    // MARK: - Setup


    private static func isLikelyTruncatedRecording(_ entry: RecordingEntry) -> Bool {
        let raw = entry.transcriptRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let final = entry.transcriptFinal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, !final.isEmpty else { return false }
        guard raw.count >= 18, final.count < raw.count else { return false }

        let ratio = Double(final.count) / Double(raw.count)
        if raw.hasPrefix(final) && ratio < 0.75 {
            return true
        }
        return ratio < 0.55
    }


    private static func createDirectories(
        fileManager: FileManager,
        baseDirectory: URL,
        recordingsDirectory: URL
    ) {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        } catch {
            print("❌ RecordingStore: Failed to create directories: \(error.localizedDescription)")
        }
    }

    private static func openDatabase(at url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            print("❌ RecordingStore: Failed to open database")
            return nil
        }
        return handle
    }

    private static func currentSchemaVersion(in db: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private static func setSchemaVersion(in db: OpaquePointer, version: Int) {
        let sql = "PRAGMA user_version = \(version);"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("❌ RecordingStore: failed to set schema version \(version)")
        }
    }

    private static func ensureTargetSchemaVersion(in db: OpaquePointer?) {
        guard let db else { return }
        let version = currentSchemaVersion(in: db)
        if version != targetSchemaVersion {
            setSchemaVersion(in: db, version: targetSchemaVersion)
        }
    }

    private static func createTables(in db: OpaquePointer?) {
        guard let db else { return }

        let createSQL = """
            CREATE TABLE IF NOT EXISTS recordings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            duration REAL NOT NULL,
            sample_rate REAL NOT NULL,
            channel_count INTEGER NOT NULL,
            bits_per_sample INTEGER NOT NULL,
            encoding TEXT NOT NULL,
            audio_path TEXT NOT NULL,
            asr_provider_id TEXT NOT NULL,
            asr_provider_name TEXT NOT NULL,
            correction_provider_id TEXT,
            transcript_raw TEXT,
            transcript_final TEXT,
            word_count INTEGER,
            error TEXT,
            status TEXT NOT NULL,
            user_id TEXT,
            asr_latency_ms INTEGER,
            correction_latency_ms INTEGER,
            total_latency_ms INTEGER,
            stream_mode TEXT,
            first_partial_ms INTEGER,
            first_final_ms INTEGER,
            fallback_used INTEGER DEFAULT 0,
            error_code TEXT,
            trace_id TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_recordings_created_at
        ON recordings (created_at DESC);

        CREATE TABLE IF NOT EXISTS recording_audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            trace_id TEXT NOT NULL,
            stage TEXT NOT NULL,
            event TEXT NOT NULL,
            provider_id TEXT,
            latency_ms INTEGER,
            changed INTEGER,
            message TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_recording_audit_trace_created
        ON recording_audit_events (trace_id, created_at DESC);
        """

        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            print("❌ RecordingStore: Failed to create tables")
        }
    }

    private static func reportSchemaHealth(
        databaseURL: URL,
        db: OpaquePointer?,
        requiredColumns: [String],
        targetVersion: Int
    ) -> SchemaHealth {
        guard let db else {
            return SchemaHealth(
                databasePath: databaseURL.path,
                schemaVersion: 0,
                requiredColumns: requiredColumns,
                missingColumns: requiredColumns
            )
        }

        let version = currentSchemaVersion(in: db)
        let existing = Set(columns(in: db, table: "recordings"))
        let missing = requiredColumns
            .map { $0.lowercased() }
            .filter { !existing.contains($0) }

        if !missing.isEmpty {
            print("⚠️ RecordingStore: schema health missing columns: \(missing.joined(separator: ","))")
        }
        if version != targetVersion {
            print("⚠️ RecordingStore: schema version mismatch expected=\(targetVersion) actual=\(version)")
        }

        return SchemaHealth(
            databasePath: databaseURL.path,
            schemaVersion: version,
            requiredColumns: requiredColumns,
            missingColumns: missing
        )
    }

    private static func migrateSchemaIfNeeded(in db: OpaquePointer?) {
        guard let db else { return }
        if !columnExists(db, table: "recordings", column: "user_id") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN user_id TEXT;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add user_id column")
            }
        }
        if !columnExists(db, table: "recordings", column: "asr_latency_ms") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN asr_latency_ms INTEGER;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add asr_latency_ms column")
            }
        }
        if !columnExists(db, table: "recordings", column: "correction_latency_ms") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN correction_latency_ms INTEGER;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add correction_latency_ms column")
            }
        }
        if !columnExists(db, table: "recordings", column: "total_latency_ms") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN total_latency_ms INTEGER;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add total_latency_ms column")
            }
        }
        if !columnExists(db, table: "recordings", column: "stream_mode") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN stream_mode TEXT;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add stream_mode column")
            }
        }
        if !columnExists(db, table: "recordings", column: "first_partial_ms") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN first_partial_ms INTEGER;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add first_partial_ms column")
            }
        }
        if !columnExists(db, table: "recordings", column: "first_final_ms") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN first_final_ms INTEGER;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add first_final_ms column")
            }
        }
        if !columnExists(db, table: "recordings", column: "fallback_used") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN fallback_used INTEGER DEFAULT 0;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add fallback_used column")
            }
        }
        if !columnExists(db, table: "recordings", column: "error_code") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN error_code TEXT;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add error_code column")
            }
        }
        if !columnExists(db, table: "recordings", column: "trace_id") {
            let alterSQL = "ALTER TABLE recordings ADD COLUMN trace_id TEXT;"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) != SQLITE_OK {
                print("❌ RecordingStore: Failed to add trace_id column")
            }
        }

        let backfillSQL = "UPDATE recordings SET trace_id = lower(hex(randomblob(16))) WHERE trace_id IS NULL OR trim(trace_id) = '';"
        if sqlite3_exec(db, backfillSQL, nil, nil, nil) != SQLITE_OK {
            print("❌ RecordingStore: Failed to backfill trace_id")
        }
    }

    private static func backfillStreamingDefaults(in db: OpaquePointer?) {
        guard let db else { return }

        let statements: [String] = [
            "UPDATE recordings SET stream_mode = 'batch' WHERE stream_mode IS NULL OR trim(stream_mode) = '';",
            "UPDATE recordings SET first_partial_ms = -1 WHERE first_partial_ms IS NULL;",
            "UPDATE recordings SET first_final_ms = -1 WHERE first_final_ms IS NULL;",
            "UPDATE recordings SET fallback_used = 0 WHERE fallback_used IS NULL;",
            "UPDATE recordings SET error_code = 'none' WHERE error_code IS NULL OR trim(error_code) = '';",
            "UPDATE recordings SET trace_id = lower(hex(randomblob(16))) WHERE trace_id IS NULL OR trim(trace_id) = '';"
        ]

        for statement in statements {
            if sqlite3_exec(db, statement, nil, nil, nil) != SQLITE_OK {
                print("⚠️ RecordingStore: backfill failed -> \(statement)")
            }
        }
    }

    private static func columns(in db: OpaquePointer?, table: String) -> [String] {
        guard let db else { return [] }
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var output: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {
                output.append(String(cString: cString).lowercased())
            }
        }
        return output
    }

    private static func columnExists(_ db: OpaquePointer, table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 1) {
                if String(cString: cString) == column {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Helpers

    private func bindText(_ statement: OpaquePointer, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func countEntries() -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM recordings;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private func cleanupIfNeeded() {
        let now = Date()
        if let lastCleanup, now.timeIntervalSince(lastCleanup) < 6 * 60 * 60 {
            return
        }
        lastCleanup = now
        cleanup(retainDays: retentionDays)
    }

    private func cleanup(retainDays: Int) {
        guard let db else { return }

        let cutoff = Date().addingTimeInterval(-Double(retainDays) * 24 * 60 * 60).timeIntervalSince1970

        // Collect old file paths
        var oldPaths: [String] = []
        let selectSQL = "SELECT audio_path FROM recordings WHERE created_at < ?;"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK, let stmt = selectStmt {
            sqlite3_bind_double(stmt, 1, cutoff)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    oldPaths.append(String(cString: cString))
                }
            }
            sqlite3_finalize(stmt)
        }

        // Delete old files
        for path in oldPaths {
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path)
            try? fileManager.removeItem(at: url)
        }

        // Delete old rows
        let deleteSQL = "DELETE FROM recordings WHERE created_at < ?;"
        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK, let stmt = deleteStmt {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        let deleteAuditSQL = "DELETE FROM recording_audit_events WHERE created_at < ?;"
        var deleteAuditStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteAuditSQL, -1, &deleteAuditStmt, nil) == SQLITE_OK, let stmt = deleteAuditStmt {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}
