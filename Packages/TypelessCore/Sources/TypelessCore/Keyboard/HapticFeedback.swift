#if canImport(UIKit)
import UIKit

/// Provides haptic feedback for keyboard interactions
public struct HapticFeedbackGenerator: Sendable {
    public init() {}

    /// Light tap feedback for regular key presses
    public func keyTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    /// Medium tap feedback for special keys (shift, delete, etc.)
    public func specialKeyTap() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    /// Success feedback for voice transcription completion
    public func transcriptionComplete() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    /// Error feedback for failed operations
    public func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    /// Selection changed feedback
    public func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}
#else
/// macOS stub - haptic feedback not available
public struct HapticFeedbackGenerator: Sendable {
    public init() {}
    public func keyTap() {}
    public func specialKeyTap() {}
    public func transcriptionComplete() {}
    public func error() {}
    public func selectionChanged() {}
}
#endif
