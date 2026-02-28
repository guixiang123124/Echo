import UIKit
import EchoCore

/// Handles triggering voice input from the keyboard extension
/// Since keyboard extensions cannot access the microphone,
/// we redirect to the main app via URL scheme
enum VoiceInputTrigger {
    private static let launchAckTimeout: TimeInterval = 2.0
    private static let launchAckPollInterval: TimeInterval = 0.15
    private static let directStartWaitTimeout: TimeInterval = 1.0
    private static let directStopWaitTimeout: TimeInterval = 0.7
    private static let directCommandHeartbeatWindow: TimeInterval = 2.5
    private static let dictationStateFreshnessWindow: TimeInterval = 2.6
    private static let dictationStateRequestSlack: TimeInterval = 0.4

    /// Check if the voice engine is ready (running and healthy)
    /// Returns true if we can send Start/Stop commands without jumping
    static var isEngineReady: Bool {
        let bridge = AppGroupBridge()
        return shouldUseDirectCommand(bridge: bridge)
    }

    /// Smart voice trigger: if dictation is ready, send direct command;
    /// otherwise, jump to main app to start engine.
    /// otherwise, jump to main app to start engine.
    static func triggerVoiceInput(
        isCurrentlyRecording: Bool,
        from viewController: UIViewController?,
        completion: ((Bool) -> Void)? = nil
    ) {
        let bridge = AppGroupBridge()
        let priorState = bridge.readDictationState()
        let requestAt = Date().timeIntervalSince1970
        var isRecordingNow = isDictationRecordingNow(bridge)
        if !isRecordingNow && isCurrentlyRecording && bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow) {
            isRecordingNow = true
        }
        let shouldDirect = shouldUseDirectCommand(bridge: bridge)
        print("[VoiceInputTrigger] triggerVoiceInput: direct=\(shouldDirect), isRecordingNow=\(isRecordingNow), isCurrentlyRecording=\(isCurrentlyRecording), state=\(String(describing: priorState)), heartbeats=\(bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow)), engineHealthy=\(bridge.isEngineHealthy)")

        // Prefer direct command path when dictation is ready.
        if shouldDirect {
            let darwin = DarwinNotificationCenter.shared
            if isRecordingNow {
                darwin.post(.dictationStop)
                waitForDictationStop(
                    maxWait: directStopWaitTimeout,
                    requestAt: requestAt,
                    priorSessionId: priorState?.sessionId
                ) { stopped in
                    if stopped {
                        completion?(true)
                    } else {
                        print("[VoiceInputTrigger] direct stop failed, fallback to app launch")
                        openMainAppForVoice(from: viewController, completion: completion)
                    }
                }
            } else {
                darwin.post(.dictationStart)
                waitForDictationStart(
                    maxWait: directStartWaitTimeout,
                    priorSessionId: priorState?.sessionId,
                    requestAt: requestAt
                ) { started in
                    if started {
                        completion?(true)
                    } else {
                        print("[VoiceInputTrigger] direct start failed, fallback to app launch")
                        openMainAppForVoice(from: viewController, completion: completion)
                    }
                }
            }
            return
        }

        print("[VoiceInputTrigger] direct command path not used, opening main app")
        openMainAppForVoice(from: viewController, completion: completion)
    }

    private static func shouldUseDirectCommand(bridge: AppGroupBridge) -> Bool {
        let hasHeartbeat = bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow)
        guard hasHeartbeat else {
            return false
        }

        let isHealthy = bridge.isEngineHealthy
        guard isHealthy else {
            return false
        }

        guard bridge.hasRecentDictationState(maxAge: dictationStateFreshnessWindow) else {
            return false
        }

        if let dictationState = bridge.readDictationState(),
           dictationState.state == .error {
            return false
        }

        return true
    }

    private static func isDictationRecordingNow(_ bridge: AppGroupBridge) -> Bool {
        guard let dictationState = bridge.readDictationState() else { return false }
        if isDictationStateRecordingLike(dictationState.state)
            && bridge.hasRecentDictationState(maxAge: dictationStateFreshnessWindow)
            && bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow) {
            return true
        }

        // Fallback to explicit recording flag if state is not available yet.
        return bridge.isRecording && bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow)
    }

    private static func isDictationStateRecordingLike(_ state: AppGroupBridge.DictationState?) -> Bool {
        switch state {
        case .recording, .transcribing:
            return true
        case .idle, .error, .finalizing, nil:
            // .finalizing means recording already stopped and ASR is processing.
            // Treat it as "not recording" so waitForDictationStop can confirm
            // the stop quickly instead of timing out during finalization.
            return false
        }
    }

    private static func waitForDictationStart(
        maxWait: TimeInterval,
        priorSessionId: String?,
        requestAt: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Date()
        let bridge = AppGroupBridge()

        func check() {
            guard let current = bridge.readDictationStateWithTimestamp() else {
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed < maxWait else {
                    completion(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    check()
                }
                return
            }

            let started = isDictationStateRecordingLike(current.state)
                && bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow)
                && current.at >= requestAt - dictationStateRequestSlack
                && (priorSessionId == nil || current.sessionId != priorSessionId)
            if started {
                completion(true)
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            guard elapsed < maxWait else {
                completion(false)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                check()
            }
        }

        check()
    }

    private static func waitForDictationStop(
        maxWait: TimeInterval,
        requestAt: TimeInterval,
        priorSessionId: String?,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Date()
        let bridge = AppGroupBridge()

        func check() {
            guard let currentState = bridge.readDictationStateWithTimestamp() else {
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed < maxWait else {
                    completion(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    check()
                }
                return
            }

            let isCurrentRecordingLike = isDictationStateRecordingLike(currentState.state)
            let hasHeartbeat = bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow)
            let currentSessionId = currentState.sessionId
            let hasDifferentSession = priorSessionId != nil && currentSessionId != priorSessionId

            let currentStateFreshForRequest = currentState.at >= requestAt - dictationStateRequestSlack
            let stopped = currentStateFreshForRequest && hasHeartbeat && !isCurrentRecordingLike && (hasDifferentSession || !currentSessionId.isEmpty)
            if stopped {
                completion(true)
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            guard elapsed < maxWait else {
                completion(false)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                check()
            }
        }

        check()
    }

    /// Send Start command directly (when engine is already running)
    static func sendStartCommand() {
        AppGroupBridge().sendVoiceCommand(.start)
    }

    /// Send Stop command directly (when engine is already running)
    static func sendStopCommand() {
        AppGroupBridge().sendVoiceCommand(.stop)
    }

    // MARK: - UIApplication Runtime URL Opening (iOS 18+ keyboard extension workaround)

    /// Open a URL from a keyboard extension using UIApplication.shared via runtime access.
    /// On iOS 18+, extensionContext.open(), responder chain, and SwiftUI Link all fail
    /// for keyboard extensions. This runtime approach is used by virtually all production
    /// third-party keyboards (Gboard, SwiftKey, Fleksy, etc.).
    ///
    /// Uses the modern `open(_:options:completionHandler:)` API which properly handles
    /// cold launches (app completely killed), unlike the deprecated `openURL:`.
    @discardableResult
    static func openURLFromExtension(_ url: URL) -> Bool {
        let sharedSel = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sharedSel) else {
            print("[VoiceInputTrigger] UIApplication does not respond to sharedApplication")
            return false
        }
        guard let result = UIApplication.perform(sharedSel) else {
            print("[VoiceInputTrigger] UIApplication.perform(sharedApplication) returned nil")
            return false
        }
        let app = result.takeUnretainedValue()

        // Use the modern open(_:options:completionHandler:) API for reliable cold launches.
        let openSel = NSSelectorFromString("openURL:options:completionHandler:")
        if app.responds(to: openSel) {
            print("[VoiceInputTrigger] Opening URL via UIApplication.open (modern API): \(url.absoluteString)")
            typealias OpenFunc = @convention(c) (AnyObject, Selector, URL, [String: Any], ((Bool) -> Void)?) -> Void
            let imp = app.method(for: openSel)
            let open = unsafeBitCast(imp, to: OpenFunc.self)
            open(app, openSel, url, [:], { success in
                print("[VoiceInputTrigger] UIApplication.open completion: \(success)")
            })
            return true
        }

        // Fallback to deprecated openURL: for older iOS
        let legacySel = NSSelectorFromString("openURL:")
        if app.responds(to: legacySel) {
            print("[VoiceInputTrigger] Opening URL via UIApplication.openURL (legacy): \(url.absoluteString)")
            app.perform(legacySel, with: url)
            return true
        }

        print("[VoiceInputTrigger] UIApplication does not respond to any openURL selector")
        return false
    }

    /// Open the main Echo app for voice recording.
    /// Includes a trace ID so the app can match the launch acknowledgement.
    static func openMainAppForVoice(from viewController: UIViewController?, completion: ((Bool) -> Void)? = nil) {
        AppGroupBridge().setPendingLaunchIntent(.voice)
        let trace = UUID().uuidString.prefix(8)
        let urls = [
            AppGroupBridge.voiceInputURL,
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
                    if !acknowledged {
                        print("[VoiceInputTrigger] launch ack not observed for \(candidate.absoluteString)")
                    }
                }
                finish(true)
            }
        }

        attempt(at: 0)
    }

    private static func open(url: URL, from viewController: UIViewController?, completion: ((Bool) -> Void)?) {
        let urlString = url.absoluteString
        var didFinish = false

        let finish: (Bool) -> Void = { success in
            guard !didFinish else { return }
            didFinish = true
            completion?(success)
        }

        // Primary path: UIApplication runtime access (most reliable on iOS 18+)
        if openURLFromExtension(url) {
            print("[VoiceInputTrigger] open via UIApplication runtime succeeded for \(urlString)")
            finish(true)
            return
        }

        guard let viewController else {
            completion?(false)
            return
        }

        let resolvedViewController = viewController

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

        // Fallback: extensionContext.open (unreliable on iOS 18+ but still worth trying)
        if let extensionContext = resolvedViewController.extensionContext {
            reportOpenAttempt("extensionContext.open", true)

            let timeout = DispatchWorkItem {
                guard !didFinish else { return }
                print("[VoiceInputTrigger] extensionContext.open timeout, trying fallback")
                _ = tryFallbackOpen()
                finish(true)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)

            extensionContext.open(url) { success in
                timeout.cancel()
                reportOpenAttempt("extensionContext.open completion", success)
                guard !didFinish else { return }

                if !success {
                    print("[VoiceInputTrigger] extensionContext.open reported failure, trying fallback")
                    _ = tryFallbackOpen()
                }

                finish(true)
            }
            return
        }

        if tryFallbackOpen() {
            finish(true)
            return
        }

        finish(false)
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
