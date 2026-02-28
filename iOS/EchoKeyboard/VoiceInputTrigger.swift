import UIKit
import EchoCore

/// Handles triggering voice input from the keyboard extension
/// Since keyboard extensions cannot access the microphone,
/// we redirect to the main app via URL scheme
enum VoiceInputTrigger {
    private static let launchAckTimeout: TimeInterval = 2.2
    private static let launchAckPollInterval: TimeInterval = 0.15

    /// Check if the voice engine is ready (running and healthy)
    /// Returns true if we can send Start/Stop commands without jumping
    static var isEngineReady: Bool {
        let bridge = AppGroupBridge()
        return bridge.isEngineHealthy
    }

    /// Smart voice trigger: if background dictation alive, use Darwin notification;
    /// if engine healthy (old path), send voice command;
    /// otherwise, jump to main app to start engine.
    static func triggerVoiceInput(
        isCurrentlyRecording: Bool,
        from viewController: UIViewController?,
        completion: ((Bool) -> Void)? = nil
    ) {
        let bridge = AppGroupBridge()

        // Prefer Darwin notification path if background dictation is alive
        if bridge.hasRecentHeartbeat(maxAge: 6) {
            let darwin = DarwinNotificationCenter.shared
            if isCurrentlyRecording {
                darwin.post(.dictationStop)
            } else {
                darwin.post(.dictationStart)
            }
            completion?(true)
            return
        }

        if bridge.isEngineHealthy {
            let command: AppGroupBridge.VoiceCommand = isCurrentlyRecording ? .stop : .start
            bridge.sendVoiceCommand(command)
            completion?(true)
        } else {
            openMainAppForVoice(from: viewController, completion: completion)
        }
    }

    /// Send Start command directly (when engine is already running)
    static func sendStartCommand() {
        AppGroupBridge().sendVoiceCommand(.start)
    }

    /// Send Stop command directly (when engine is already running)
    static func sendStopCommand() {
        AppGroupBridge().sendVoiceCommand(.stop)
    }

    /// Open the main Echo app for voice recording.
    /// Includes a trace ID so the app can match the launch acknowledgement.
    static func openMainAppForVoice(from viewController: UIViewController?, completion: ((Bool) -> Void)? = nil) {
        AppGroupBridge().setPendingLaunchIntent(.voice)
        let trace = UUID().uuidString.prefix(8)
        let urls = [
            URL(string: "echo://voice?trace=\(trace)")!,
            URL(string: "echo:///voice?trace=\(trace)")!,
            URL(string: "echoapp://voice?trace=\(trace)")!,
            URL(string: "echoapp:///voice?trace=\(trace)")!
        ]
        open(urls: urls, from: viewController, completion: completion)
    }

    /// Open the main Echo app settings
    static func openMainAppForSettings(from viewController: UIViewController?, completion: ((Bool) -> Void)? = nil) {
        AppGroupBridge().setPendingLaunchIntent(.settings)
        let urls = [
            AppGroupBridge.settingsURL,
            URL(string: "echo:///settings")!,
            URL(string: "echoapp://settings")!,
            URL(string: "echoapp:///settings")!
        ]
        open(urls: urls, from: viewController, completion: completion)
    }

    private static func open(urls: [URL], from viewController: UIViewController?, completion: ((Bool) -> Void)?) {
        var didFinish = false

        let finish: (Bool) -> Void = { success in
            guard !didFinish else { return }
            didFinish = true
            completion?(success)
        }

        func attempt(at index: Int) {
            guard index < urls.count else {
                AppGroupBridge().clearPendingLaunchIntent()
                finish(false)
                return
            }

            let candidate = urls[index]
            open(url: candidate, from: viewController) { didInvoke in
                guard didInvoke else {
                    attempt(at: index + 1)
                    return
                }

                waitForLaunchAcknowledgement(timeout: launchAckTimeout, pollInterval: launchAckPollInterval) { acknowledged in
                    guard !didFinish else { return }
                    print("[VoiceInputTrigger] launch ack for \(candidate.absoluteString): \(acknowledged)")
                    if acknowledged {
                        finish(true)
                        return
                    }

                    print("[VoiceInputTrigger] launch ack not observed for \(candidate.absoluteString), trying next URL")
                    attempt(at: index + 1)
                }
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
        var didFinish = false

        let finish: (Bool) -> Void = { success in
            guard !didFinish else { return }
            didFinish = true
            completion?(success)
        }

        let fail: () -> Void = {
            AppGroupBridge().clearPendingLaunchIntent()
            finish(false)
        }

        let reportOpenAttempt: (_ path: String, _ success: Bool) -> Void = { path, success in
            print("[VoiceInputTrigger] open via \(path) result for \(urlString): \(success)")
        }

        let tryFallbackOpen: () -> Bool = {
            if let inputViewController = resolvedViewController as? UIInputViewController,
               openViaInputViewController(url, from: inputViewController) {
                reportOpenAttempt("UIInputViewController.openURL", true)
                return true
            }
            if openViaResponderChain(url: url, from: resolvedViewController) {
                reportOpenAttempt("Responder chain", true)
                return true
            }
            return false
        }

        // Primary path for app extension -> host app open.
        if let extensionContext = resolvedViewController.extensionContext {
            reportOpenAttempt("extensionContext.open", true)

            let timeout = DispatchWorkItem {
                guard !didFinish else { return }
                print("[VoiceInputTrigger] extensionContext.open timeout, trying fallback")
                finish(tryFallbackOpen())
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)

            extensionContext.open(url) { success in
                timeout.cancel()
                reportOpenAttempt("extensionContext.open completion", success)
                guard !didFinish else { return }

                let invoked: Bool = {
                    if success {
                        return true
                    }
                    print("[VoiceInputTrigger] extensionContext.open reported failure, trying fallback")
                    return tryFallbackOpen()
                }()

                finish(invoked)
            }
            return
        }

        if tryFallbackOpen() {
            finish(true)
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
                    var result = false
                    var callbackCalled = false
                    function(current, selector, url) { opened in
                        callbackCalled = true
                        result = opened
                        print("VoiceInputTrigger: \(selector.description) completion result for \(url.absoluteString): \(opened)")
                    }
                    if callbackCalled {
                        return result
                    }
                    return true

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
                    var result = false
                    var callbackCalled = false
                    function(current, selector, url, [:]) { opened in
                        callbackCalled = true
                        result = opened
                        print("VoiceInputTrigger: openURL:options:completionHandler: completion result for \(url.absoluteString): \(opened)")
                    }
                    if callbackCalled {
                        return result
                    }
                    return true

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
                    var result = false
                    var callbackCalled = false
                    function(current, selector, url, [:], { opened in
                        callbackCalled = true
                        result = opened
                        print("VoiceInputTrigger: openURL:options:completionHandler:sourceApplication: completion result for \(url.absoluteString): \(opened)")
                    }, "")
                    if callbackCalled {
                        return result
                    }
                    return true

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
            var result = false
            var callbackCalled = false
            function(viewController, selector, url) { opened in
                callbackCalled = true
                result = opened
                print("VoiceInputTrigger: openURL:completion result for \(url.absoluteString): \(opened)")
            }
            print("VoiceInputTrigger: openURL:completion handler invocation attempted for \(url.absoluteString)")

            if callbackCalled {
                return result
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
