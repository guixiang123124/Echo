import SwiftUI

/// Permission setup view shown when permissions are not granted
struct PermissionSetupView: View {
    @EnvironmentObject var permissionManager: PermissionManager
    @State private var currentStep = 0

    private let steps: [PermissionManager.Permission] = [
        .accessibility,
        .inputMonitoring,
        .microphone
    ]

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("Welcome to Typeless")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Let's set up the required permissions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            // Permission list
            VStack(spacing: 16) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, permission in
                    PermissionRow(
                        permission: permission,
                        isGranted: isGranted(permission),
                        isCurrentStep: index == currentStep,
                        onRequest: {
                            requestPermission(permission)
                        },
                        onOpenSettings: {
                            permissionManager.openSystemPreferences(for: permission)
                        }
                    )
                }
            }
            .padding(.horizontal, 20)

            Spacer()

            // Continue button
            if permissionManager.allPermissionsGranted {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)

                    Text("All set! You can now use Typeless.")
                        .font(.headline)

                    Text("Hold your activation key and start speaking")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 420, height: 480)
        .onAppear {
            updateCurrentStep()
        }
        .onChange(of: permissionManager.accessibilityGranted) { _, _ in updateCurrentStep() }
        .onChange(of: permissionManager.inputMonitoringGranted) { _, _ in updateCurrentStep() }
        .onChange(of: permissionManager.microphoneGranted) { _, _ in updateCurrentStep() }
    }

    private func isGranted(_ permission: PermissionManager.Permission) -> Bool {
        switch permission {
        case .accessibility:
            return permissionManager.accessibilityGranted
        case .microphone:
            return permissionManager.microphoneGranted
        case .inputMonitoring:
            return permissionManager.inputMonitoringGranted
        }
    }

    private func requestPermission(_ permission: PermissionManager.Permission) {
        Task {
            switch permission {
            case .accessibility:
                permissionManager.requestAccessibilityPermission()
            case .inputMonitoring:
                permissionManager.requestInputMonitoringPermission()
            case .microphone:
                _ = await permissionManager.requestMicrophonePermission()
            }
        }
    }

    private func updateCurrentStep() {
        if !permissionManager.accessibilityGranted {
            currentStep = 0
        } else if !permissionManager.inputMonitoringGranted {
            currentStep = 1
        } else if !permissionManager.microphoneGranted {
            currentStep = 2
        } else {
            currentStep = steps.count
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let permission: PermissionManager.Permission
    let isGranted: Bool
    let isCurrentStep: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(isGranted ? Color.green.opacity(0.2) : (isCurrentStep ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1)))
                    .frame(width: 40, height: 40)

                Image(systemName: isGranted ? "checkmark" : iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isGranted ? .green : (isCurrentStep ? .accentColor : .secondary))
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.rawValue)
                    .font(.headline)
                    .foregroundColor(isGranted ? .secondary : .primary)

                Text(permission.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Action button
            if !isGranted {
                if isCurrentStep {
                    Button("Grant") {
                        onRequest()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Open Settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(isCurrentStep && !isGranted ? Color.accentColor.opacity(0.05) : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrentStep && !isGranted ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private var iconName: String {
        switch permission {
        case .accessibility:
            return "hand.raised"
        case .inputMonitoring:
            return "keyboard"
        case .microphone:
            return "mic"
        }
    }
}

#Preview {
    PermissionSetupView()
        .environmentObject(PermissionManager())
}
