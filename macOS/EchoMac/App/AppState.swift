import Foundation
import SwiftUI
import Combine

/// Observable state for the Echo macOS app
@MainActor
public final class AppState: ObservableObject {
    // Singleton for easy access
    public static let shared = AppState()
    // MARK: - Recording State

    public enum RecordingState: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case correcting
        case inserting
        case error(String)

        var isActive: Bool {
            switch self {
            case .idle, .error:
                return false
            default:
                return true
            }
        }

        var statusMessage: String {
            switch self {
            case .idle:
                return "Ready"
            case .listening:
                return "Listening..."
            case .transcribing:
                return "Transcribe & Edit..."
            case .correcting:
                return "Transcribe & Edit..."
            case .inserting:
                return "Inserting..."
            case .error(let message):
                return "Error: \(message)"
            }
        }
    }

    // MARK: - Published Properties

    @Published public var recordingState: RecordingState = .idle
    @Published public var partialTranscription: String = ""
    @Published public var finalTranscription: String = ""
    @Published public var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    @Published public var isRecordingPanelVisible: Bool = false
    @Published public var isStreamingModeActive: Bool = false
    @Published public var canUndoLastAutoEdit: Bool = false

    // MARK: - Permission State

    @Published public var accessibilityGranted: Bool = false
    @Published public var inputMonitoringGranted: Bool = false
    @Published public var microphoneGranted: Bool = false

    public var allPermissionsGranted: Bool {
        accessibilityGranted && inputMonitoringGranted && microphoneGranted
    }

    // MARK: - Statistics

    @Published public var totalWordsTranscribed: Int = 0
    @Published public var totalTimeSaved: TimeInterval = 0 // Estimated time saved vs typing

    // MARK: - Methods

    public func updateAudioLevel(_ level: CGFloat) {
        audioLevels.removeFirst()
        audioLevels.append(level)
    }

    public func resetAudioLevels() {
        audioLevels = Array(repeating: 0, count: 30)
    }

    public func reset() {
        recordingState = .idle
        partialTranscription = ""
        finalTranscription = ""
        resetAudioLevels()
        isRecordingPanelVisible = false
        isStreamingModeActive = false
        canUndoLastAutoEdit = false
    }
}

@MainActor
public final class DiagnosticsState: ObservableObject {
    public static let shared = DiagnosticsState()

    public struct Entry: Identifiable, Equatable {
        public let id = UUID()
        public let timestamp: Date
        public let message: String
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var isHotkeyMonitoring: Bool = false
    @Published public private(set) var lastHotkeyEvent: String = "—"
    @Published public private(set) var lastError: String?

    private let maxEntries = 100

    public func log(_ message: String) {
        let entry = Entry(timestamp: Date(), message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func clear() {
        entries.removeAll()
        lastError = nil
        lastHotkeyEvent = "—"
    }

    public func updateMonitoring(_ isMonitoring: Bool, reason: String? = nil) {
        guard isHotkeyMonitoring != isMonitoring else { return }
        isHotkeyMonitoring = isMonitoring
        if isMonitoring {
            log("Hotkey monitor started")
        } else if let reason {
            log("Hotkey monitor stopped (\(reason))")
        } else {
            log("Hotkey monitor stopped")
        }
    }

    public func recordHotkeyEvent(_ event: String) {
        lastHotkeyEvent = event
        log("Hotkey: \(event)")
    }

    public func recordError(_ error: String) {
        lastError = error
        log("Error: \(error)")
    }
}
