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
        AppGroupBridge().setPendingLaunchIntent(.voice)
        let urls = [AppGroupBridge.voiceInputURL, URL(string: "echo://voice")!]
        open(urls: urls, from: viewController, completion: completion)
    }

    /// Open the main Echo app settings
    static func openMainAppForSettings(from viewController: UIViewController?, completion: ((Bool) -> Void)? = nil) {
        AppGroupBridge().setPendingLaunchIntent(.settings)
        let urls = [AppGroupBridge.settingsURL, URL(string: "echo://settings")!]
        open(urls: urls, from: viewController, completion: completion)
    }

    private static func open(urls: [URL], from viewController: UIViewController?, completion: ((Bool) -> Void)?) {
        func attempt(at index: Int) {
            guard index < urls.count else {
                AppGroupBridge().clearPendingLaunchIntent()
                completion?(false)
                return
            }
            open(url: urls[index], from: viewController) { success in
                if success {
                    completion?(true)
                    return
                }
                attempt(at: index + 1)
            }
        }

        attempt(at: 0)
    }

    private static func open(url: URL, from viewController: UIViewController?, completion: ((Bool) -> Void)?) {
        var finished = false
        let finish: (Bool) -> Void = { success in
            guard !finished else { return }
            finished = true
            completion?(success)
        }

        let fail: () -> Void = {
            AppGroupBridge().clearPendingLaunchIntent()
            finish(false)
        }

        let confirmFallbackLaunch: () -> Void = {
            waitForLaunchAcknowledgement { acknowledged in
                if acknowledged {
                    finish(true)
                    return
                }
                fail()
            }
        }

        // Primary path for app extension -> host app open.
        if let extensionContext = viewController?.extensionContext {
            let timeout = DispatchWorkItem {
                guard !finished else { return }
                let fallback = openViaResponderChain(url: url, from: viewController)
                if fallback {
                    confirmFallbackLaunch()
                    return
                }
                print("VoiceInputTrigger: Timeout opening URL: \(url.absoluteString)")
                fail()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: timeout)

            extensionContext.open(url) { success in
                timeout.cancel()
                guard !finished else { return }
                if success {
                    finish(true)
                    return
                }

                // Fallback when extensionContext.open fails on some host app states.
                let fallback = openViaResponderChain(url: url, from: viewController)
                if fallback {
                    confirmFallbackLaunch()
                    return
                }
                print("VoiceInputTrigger: Failed to open URL: \(url.absoluteString)")
                fail()
            }
            return
        }

        let opened = openViaResponderChain(url: url, from: viewController)
        if opened {
            confirmFallbackLaunch()
            return
        }
        fail()
    }

    private static func openViaResponderChain(url: URL, from viewController: UIViewController?) -> Bool {
        var responder: UIResponder? = viewController
        while let current = responder {
            let selector = sel_registerName("openURL:")
            if current.responds(to: selector) {
                typealias OpenURLFunc = @convention(c) (AnyObject, Selector, URL) -> Bool
                let implementation = current.method(for: selector)
                let function = unsafeBitCast(implementation, to: OpenURLFunc.self)
                if function(current, selector, url) {
                    return true
                }
            }
            responder = current.next
        }
        return false
    }

    private static func waitForLaunchAcknowledgement(
        timeout: TimeInterval = 1.6,
        pollInterval: TimeInterval = 0.15,
        completion: @escaping (Bool) -> Void
    ) {
        let bridge = AppGroupBridge()
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if bridge.hasRecentLaunchAcknowledgement(maxAge: 8) {
                completion(true)
                return
            }
            if Date() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                poll()
            }
        }

        poll()
    }
}
