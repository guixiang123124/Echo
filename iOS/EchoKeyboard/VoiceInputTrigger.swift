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
        guard let viewController else {
            completion?(false)
            return
        }
        let resolvedViewController = viewController

        let urlString = url.absoluteString

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

        let reportOpenAttempt: (_ path: String, _ success: Bool) -> Void = { path, success in
            print("[VoiceInputTrigger] open via \(path) result for \(urlString): \(success)")
        }

        let awaitLaunchAckThenFinish: (String, @escaping () -> Void) -> Void = { method, onFailure in
            reportOpenAttempt("\(method) ack", false)
            waitForLaunchAcknowledgement(timeout: 1.5, pollInterval: 0.12) { acknowledged in
                if acknowledged {
                    reportOpenAttempt("\(method) ack", true)
                    finish(true)
                } else {
                    onFailure()
                }
            }
        }

        let fallback: () -> Void = {
            reportOpenAttempt("fallback:start", false)
            if let inputViewController = resolvedViewController as? UIInputViewController,
               openViaInputViewController(url, from: inputViewController) {
                reportOpenAttempt("UIInputViewController.openURL", true)
                awaitLaunchAckThenFinish("UIInputViewController.openURL") {
                    reportOpenAttempt("UIInputViewController.openURL", false)
                    fail()
                }
                return
            }
            if openViaResponderChain(url: url, from: resolvedViewController) {
                reportOpenAttempt("Responder chain", true)
                awaitLaunchAckThenFinish("Responder chain") {
                    reportOpenAttempt("Responder chain", false)
                    fail()
                }
                return
            }
            fail()
        }

        // Primary path for app extension -> host app open.
        if let extensionContext = resolvedViewController.extensionContext {
            reportOpenAttempt("extensionContext.open", true)
            let timeout = DispatchWorkItem {
                guard !finished else { return }
                print("[VoiceInputTrigger] extensionContext.open timeout, trying fallback")
                awaitLaunchAckThenFinish("extensionContext.open.timeout") {
                    fallback()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)

            extensionContext.open(url) { success in
                timeout.cancel()
                reportOpenAttempt("extensionContext.open completion", success)
                guard !finished else { return }
                if success {
                    awaitLaunchAckThenFinish("extensionContext.open") {
                        fallback()
                    }
                    return
                }
                fallback()
            }
            return
        }

        if let inputViewController = resolvedViewController as? UIInputViewController {
            if openViaInputViewController(url, from: inputViewController) {
                reportOpenAttempt("UIInputViewController.openURL", true)
                awaitLaunchAckThenFinish("UIInputViewController.openURL direct") {
                    fail()
                }
                return
            }
            fallback()
            return
        }

        if openViaResponderChain(url: url, from: resolvedViewController) {
            reportOpenAttempt("Responder chain", true)
            awaitLaunchAckThenFinish("Responder chain direct") {
                fail()
            }
            return
        }
        fail()
    }

    private static func openViaResponderChain(url: URL, from viewController: UIViewController?) -> Bool {
        var responder: UIResponder? = viewController
        while let current = responder {
            let selectors: [Selector] = [
                sel_registerName("openURL:"),
                sel_registerName("openURL:completionHandler:"),
                sel_registerName("openURL:options:completionHandler:"),
                sel_registerName("openURL:options:completionHandler:sourceApplication:"),
                sel_registerName("open:completionHandler:")
            ]

            for selector in selectors where current.responds(to: selector) {
                switch selector.description {
                case "openURL:":
                    typealias OpenURLFunc = @convention(c) (AnyObject, Selector, URL) -> Bool
                    let implementation = current.method(for: selector)
                    let function = unsafeBitCast(implementation, to: OpenURLFunc.self)
                    if function(current, selector, url) {
                        return true
                    }
                case "openURL:completionHandler:", "open:completionHandler:":
                    typealias OpenURLWithCompletionFunc = @convention(c) (AnyObject, Selector, URL, @escaping (Bool) -> Void) -> Void
                    let implementation = current.method(for: selector)
                    let function = unsafeBitCast(implementation, to: OpenURLWithCompletionFunc.self)
                    var called = false
                    function(current, selector, url) { _ in called = true }
                    if called {
                        return true
                    }
                case "openURL:options:completionHandler:":
                    typealias OpenURLWithOptionsFunc = @convention(c) (
                        AnyObject,
                        Selector,
                        URL,
                        [AnyHashable: Any],
                        @escaping (Bool) -> Void
                    ) -> Void
                    let implementation = current.method(for: selector)
                    let function = unsafeBitCast(implementation, to: OpenURLWithOptionsFunc.self)
                    var called = false
                    function(current, selector, url, [:], { _ in called = true })
                    if called {
                        return true
                    }
                case "openURL:options:completionHandler:sourceApplication:":
                    typealias OpenURLWithSourceFunc = @convention(c) (
                        AnyObject,
                        Selector,
                        URL,
                        [AnyHashable: Any],
                        @escaping (Bool) -> Void,
                        String
                    ) -> Void
                    let implementation = current.method(for: selector)
                    let function = unsafeBitCast(implementation, to: OpenURLWithSourceFunc.self)
                    var called = false
                    function(current, selector, url, [:], { _ in called = true }, "")
                    if called {
                        return true
                    }
                default:
                    break
                }
            }
            responder = current.next
        }
        return false
    }

    private static func openViaInputViewController(_ url: URL, from viewController: UIInputViewController) -> Bool {
        let selector = sel_registerName("openURL:completionHandler:")
        if viewController.responds(to: selector) {
            typealias OpenURLWithCompletionFunc = @convention(c) (AnyObject, Selector, URL, @escaping (Bool) -> Void) -> Void
            let implementation = viewController.method(for: selector)
            let function = unsafeBitCast(implementation, to: OpenURLWithCompletionFunc.self)
            function(viewController, selector, url) { opened in
                print("VoiceInputTrigger: openURL:completionHandler result for \(url.absoluteString): \(opened)")
            }
            return true
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
