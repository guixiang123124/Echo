import Foundation
import AppKit
import AVFoundation
import ApplicationServices

/// Manages system permissions required by Echo
@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    // MARK: - Permission Types

    public enum Permission: String, CaseIterable, Identifiable {
        case accessibility = "Accessibility"
        case inputMonitoring = "Input Monitoring"
        case microphone = "Microphone"

        public var id: String { rawValue }

        public var description: String {
            switch self {
            case .accessibility:
                return "Required to insert text into other apps"
            case .inputMonitoring:
                return "Required to detect global hotkeys"
            case .microphone:
                return "Required to record your voice for transcription"
            }
        }

        public var systemPreferencesURL: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .inputMonitoring:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            }
        }
    }

    // MARK: - Published State

    @Published public private(set) var accessibilityGranted: Bool = false
    @Published public private(set) var inputMonitoringGranted: Bool = false
    @Published public private(set) var microphoneGranted: Bool = false

    public var allPermissionsGranted: Bool {
        accessibilityGranted && inputMonitoringGranted && microphoneGranted
    }

    // MARK: - Initialization

    public init() {
        checkAllPermissions()
    }

    // MARK: - Permission Checking

    public func checkAllPermissions() {
        checkAccessibilityPermission()
        checkInputMonitoringPermission()
        checkMicrophonePermission()
    }

    public func checkAccessibilityPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    public func checkInputMonitoringPermission() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    public func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined, .denied, .restricted:
            microphoneGranted = false
        @unknown default:
            microphoneGranted = false
        }
    }

    // MARK: - Permission Requesting

    /// Request accessibility permission (shows system dialog)
    public func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSystemPreferences(for: .accessibility)

        // Poll for changes since there's no callback
        Task {
            for _ in 0..<30 { // Check for 30 seconds
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    checkAccessibilityPermission()
                }
                if accessibilityGranted { break }
            }
        }
    }

    /// Request input monitoring permission (shows system dialog)
    public func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        openSystemPreferences(for: .inputMonitoring)

        // Poll for changes since there's no callback
        Task {
            for _ in 0..<30 { // Check for 30 seconds
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    checkInputMonitoringPermission()
                }
                if inputMonitoringGranted { break }
            }
        }
    }

    /// Request microphone permission
    public func requestMicrophonePermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            microphoneGranted = granted
        }
        return granted
    }

    // MARK: - Open System Preferences

    public func openSystemPreferences(for permission: Permission) {
        NSWorkspace.shared.open(permission.systemPreferencesURL)
    }

    public func openAccessibilityPreferences() {
        openSystemPreferences(for: .accessibility)
    }

    public func openInputMonitoringPreferences() {
        openSystemPreferences(for: .inputMonitoring)
    }

    public func openMicrophonePreferences() {
        openSystemPreferences(for: .microphone)
    }
}
