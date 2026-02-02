import UIKit
import TypelessCore

/// Handles triggering voice input from the keyboard extension
/// Since keyboard extensions cannot access the microphone,
/// we redirect to the main app via URL scheme
enum VoiceInputTrigger {
    /// Open the main Typeless app for voice recording
    /// This method uses the responder chain to find an object that can open URLs
    /// since UIApplication.shared is not available in keyboard extensions
    static func openMainAppForVoice(from viewController: UIViewController?) {
        guard let url = URL(string: "typeless://voice") else { return }

        // In keyboard extensions, we need to use the responder chain
        // to find an object that can open URLs
        var responder: UIResponder? = viewController

        // Walk up the responder chain looking for something that can open URLs
        while let current = responder {
            // Check if the responder can handle openURL:
            let selector = sel_registerName("openURL:")
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }

        // Alternative method using NSExtensionContext if available
        // This works in some extension contexts
        if let extensionContext = viewController?.extensionContext {
            extensionContext.open(url) { success in
                if !success {
                    print("VoiceInputTrigger: Failed to open URL via extensionContext")
                }
            }
        }
    }
}
