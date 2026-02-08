import UIKit
import EchoCore

/// Handles triggering voice input from the keyboard extension
/// Since keyboard extensions cannot access the microphone,
/// we redirect to the main app via URL scheme
enum VoiceInputTrigger {
    /// Open the main Echo app for voice recording
    /// This method uses the responder chain to find an object that can open URLs
    /// since UIApplication.shared is not available in keyboard extensions
    static func openMainAppForVoice(from viewController: UIViewController?, completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "echo://voice") else { return }
        open(url: url, from: viewController, completion: completion)
    }

    /// Open the main Echo app settings
    static func openMainAppForSettings(from viewController: UIViewController?, completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "echo://settings") else { return }
        open(url: url, from: viewController, completion: completion)
    }

    private static func open(url: URL, from viewController: UIViewController?, completion: ((Bool) -> Void)?) {
        // Primary and most reliable method for extensions.
        if let extensionContext = viewController?.extensionContext {
            extensionContext.open(url) { success in
                if !success {
                    print("VoiceInputTrigger: Failed to open URL: \(url.absoluteString)")
                }
                completion?(success)
            }
            return
        }

        // Fallback: responder chain (older iOS versions / edge cases).
        var responder: UIResponder? = viewController
        while let current = responder {
            let selector = sel_registerName("openURL:")
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                completion?(true)
                return
            }
            responder = current.next
        }

        completion?(false)
    }
}
