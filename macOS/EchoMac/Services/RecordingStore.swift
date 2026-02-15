import Foundation
import SQLite3
import EchoCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local persistence for audio + transcription metadata.
/// Stores WAV files on disk and metadata in SQLite.
public actor RecordingStore {
    public static let shared = RecordingStore()

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

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let recordingsDirectory: URL
    private let databaseURL: URL
    private var db: OpaquePointer?
    private var lastCleanup: Date?
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
        totalLatencyMs: Int? = nil
    ) {
        guard let db else {
            print("❌ RecordingStore: database not available")
            return
        }

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
            total_latency_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                   asr_latency_ms, correction_latency_ms, total_latency_ms
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
               asr_latency_ms, correction_latency_ms, total_latency_ms
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
                    totalLatencyMs: totalLatencyMs
                )
            )
        }

        return entries
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
            total_latency_ms INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_recordings_created_at
        ON recordings (created_at DESC);
        """

        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            print("❌ RecordingStore: Failed to create tables")
        }
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
    }
}
