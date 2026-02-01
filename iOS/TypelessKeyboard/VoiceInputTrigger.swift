import UIKit
import TypelessCore

/// Handles triggering voice input from the keyboard extension
/// Since keyboard extensions cannot access the microphone,
/// we redirect to the main app via URL scheme
enum VoiceInputTrigger {
    /// Open the main Typeless app for voice recording
    static func openMainAppForVoice() {
        guard let url = URL(string: "typeless://voice") else { return }

        // Use the shared application to open the URL
        // This works from keyboard extensions with "RequestsOpenAccess" = YES
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first?.rootViewController

        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }

        // Fallback: use shared application
        UIApplication.shared.open(url)
    }
}
