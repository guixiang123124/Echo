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

        public var audioURL: URL? {
            audioPath.isEmpty ? nil : URL(fileURLWithPath: audioPath)
        }
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
        error: String?
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
            status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("❌ RecordingStore: Failed to insert recording")
        } else {
            Task { @MainActor in
                NotificationCenter.default.post(name: .echoRecordingSaved, object: nil)
            }
        }

        cleanupIfNeeded()
    }

    public func fetchRecent(limit: Int = 100) -> [RecordingEntry] {
        guard let db else { return [] }

        let sql = """
        SELECT id, created_at, duration, sample_rate, channel_count, bits_per_sample,
               encoding, audio_path, asr_provider_id, asr_provider_name,
               correction_provider_id, transcript_raw, transcript_final,
               word_count, error, status
        FROM recordings
        ORDER BY created_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

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
                    status: status
                )
            )
        }

        return entries
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
            status TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_recordings_created_at
        ON recordings (created_at DESC);
        """

        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            print("❌ RecordingStore: Failed to create tables")
        }
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
