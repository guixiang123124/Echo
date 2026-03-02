import UIKit
import EchoCore
import ObjectiveC

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
    private static let launchWarmupCommandWindow: TimeInterval = 2.8

    /// Check if the voice engine is ready (running and healthy)
    /// Returns true if we can send Start/Stop commands without jumping
    static var isEngineReady: Bool {
        let bridge = AppGroupBridge()
        return shouldUseDirectCommand(bridge: bridge)
    }

    /// Smart voice trigger: if dictation is ready, send direct command;
    /// otherwise, jump to main app to start engine.
    /// On iOS keyboard extensions we keep a warm-up path for the first few seconds
    /// after a launch request to avoid repeated deep-links.
    static func triggerVoiceInput(
        isCurrentlyRecording: Bool,
        from viewController: UIViewController?,
        completion: ((Bool) -> Void)? = nil
    ) {
        let bridge = AppGroupBridge()
        let requestAt = Date().timeIntervalSince1970
        let priorState = bridge.readDictationState()

        var isRecordingNow = isDictationRecordingNow(bridge)
        if !isRecordingNow && isCurrentlyRecording && bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow) {
            isRecordingNow = true
        }

        let shouldDirect = shouldUseDirectCommand(bridge: bridge)
        let warmupAfterLaunch = bridge.hasRecentPendingLaunchIntent(maxAge: launchWarmupCommandWindow)
        logEvent("triggerVoiceInput: direct=\(shouldDirect), warmupAfterLaunch=\(warmupAfterLaunch), isRecordingNow=\(isRecordingNow), isCurrentlyRecording=\(isCurrentlyRecording), state=\(String(describing: priorState)), heartbeats=\(bridge.hasRecentHeartbeat(maxAge: directCommandHeartbeatWindow)), engineHealthy=\(bridge.isEngineHealthy)")

        // Prefer direct command path when dictation is ready.
        if shouldDirect {
            sendDirectCommand(
                isRecordingNow: isRecordingNow,
                priorState: priorState,
                requestAt: requestAt,
                source: "primary",
                completion: { success in
                    if success {
                        completion?(true)
                    } else {
                        logEvent("primary direct command failed, fallback to app launch")
                        openMainAppForVoice(from: viewController, completion: completion)
                    }
                }
            )
            return
        }

        // If we recently attempted launch, try one quick direct command retry first.
        // This handles the "activate once, then keep toggling in keyboard" behavior.
        if warmupAfterLaunch {
            logEvent("warmup window active, retrying direct command first")
            sendDirectCommand(
                isRecordingNow: isRecordingNow,
                priorState: priorState,
                requestAt: requestAt,
                source: "warmup",
                completion: { success in
                    if success {
                        completion?(true)
                    } else {
                        logEvent("warmup direct retry failed, opening main app")
                        openMainAppForVoice(from: viewController, completion: completion)
                    }
                }
            )
            return
        }

        logEvent("direct path skipped, opening main app")
        openMainAppForVoice(from: viewController, completion: completion)
    }

    private static func sendDirectCommand(
        isRecordingNow: Bool,
        priorState: (state: AppGroupBridge.DictationState, sessionId: String)?,
        requestAt: TimeInterval,
        source: String,
        completion: ((Bool) -> Void)?
    ) {
        let darwin = DarwinNotificationCenter.shared
        if isRecordingNow {
            logEvent("sendDirectCommand(source=\(source)) -> stop")
            darwin.post(.dictationStop)
            waitForDictationStop(
                maxWait: directStopWaitTimeout,
                requestAt: requestAt,
                priorSessionId: priorState?.sessionId
            ) { stopped in
                completion?(stopped)
            }
            return
        }

        logEvent("sendDirectCommand(source=\(source)) -> start")
        darwin.post(.dictationStart)
        waitForDictationStart(
            maxWait: directStartWaitTimeout,
            priorSessionId: priorState?.sessionId,
            requestAt: requestAt
        ) { started in
            completion?(started)
        }
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

    private static func logEvent(_ message: String, category: String = "VoiceInputTrigger", source: String = "keyboard") {
        print("[VoiceInputTrigger] \(message)")
        AppGroupBridge().appendDebugEvent(message, source: source, category: category)
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
            logEvent("UIApplication.responds(sharedApplication)==false")
            return false
        }
        guard let result = UIApplication.perform(sharedSel) else {
            logEvent("UIApplication.sharedApplication perform returned nil")
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

    private struct HostAppInfo {
        let bundleID: String?
        let pid: Int32?
    }

    /// Save the host app's bundle ID (or PID as fallback) before opening the main app,
    /// so the main app can return to the host app directly.
    /// This is needed for third-party apps where suspend() goes to Home screen.
    @discardableResult
    static func saveHostAppBundleID(from viewController: UIViewController?) -> HostAppInfo {
        guard let vc = viewController else {
            rlog("[VoiceInputTrigger] saveHostAppBundleID: no viewController")
            return HostAppInfo(bundleID: nil, pid: nil)
        }
        let bridge = AppGroupBridge()

        // Primary: try to detect bundle ID directly
        if let bundleID = detectHostBundleID(from: vc) {
            rlog("[VoiceInputTrigger] saving host app bundle ID: \(bundleID)")
            bridge.setReturnAppBundleID(bundleID)
            return HostAppInfo(bundleID: bundleID, pid: nil)
        }

        // Fallback: save the host app PID so the main app can resolve it
        // (proc_pidpath is blocked by the extension sandbox, but the main app can use it)
        if let hostPID = detectHostPID(from: vc) {
            rlog("[VoiceInputTrigger] bundle ID detection failed, saving host PID: \(hostPID)")
            bridge.setReturnAppPID(hostPID)
            return HostAppInfo(bundleID: nil, pid: hostPID)
        }

        rlog("[VoiceInputTrigger] could not detect host app bundle ID or PID from any source")
        return HostAppInfo(bundleID: nil, pid: nil)
    }

    private static func hostCandidateTargets(from viewController: UIViewController) -> [NSObject] {
        var targets: [NSObject] = [viewController]

        // Add direct hierarchy and responder chain hosts.
        var responder = viewController.next
        while let current = responder {
            if let obj = current as? NSObject {
                targets.append(obj)
            }
            responder = current.next
        }

        // Add parent to handle older responder structures.
        if let parent = viewController.parent,
           let obj = parent as? NSObject {
            targets.append(obj)
        }

        if let context = viewController.extensionContext {
            targets.append(context)
        }

        return targets
    }

    private static func asNormalizedHostString(_ raw: Any) -> String? {
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let s = raw as? NSString {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed as String }
        }
        let fallback = String(describing: raw)
        if fallback.isEmpty || fallback == "<null>" || fallback == "(null)" {
            return nil
        }
        return fallback
    }

    private static func extractHostBundleFromProxy(_ proxy: NSObject) -> String? {
        let bundleSelectors = [
            "applicationIdentifier",
            "bundleIdentifier",
            "bundleId",
            "bundleID"
        ]
        for selectorName in bundleSelectors {
            let sel = NSSelectorFromString(selectorName)
            guard proxy.responds(to: sel) else { continue }
            if let result = proxy.perform(sel) {
                let obj = result.takeUnretainedValue()
                if let bundleID = asNormalizedHostString(obj), !bundleID.isEmpty {
                    return bundleID
                }
            }
        }
        return nil
    }

    private static func isValidHostBundleID(_ bundleID: String) -> Bool {
        return !bundleID.isEmpty
            && bundleID != Bundle.main.bundleIdentifier
            && !bundleID.hasSuffix(".keyboard")
            && !bundleID.hasPrefix("com.apple.")
            && bundleID.contains(".")
    }

    private static func detectHostBundleID(from viewController: UIViewController) -> String? {
        let targets = hostCandidateTargets(from: viewController)

        let allSelNames = [
            "_hostApplicationBundleIdentifier",
            "hostApplicationBundleIdentifier",
            "_hostBundleIdentifier",
            "hostBundleIdentifier",
            "_hostBundleID",
            "hostBundleID",
            "_hostBundleId",
            "hostBundleId",
            "hostBundle",
            "_hostApplicationProxy",
            "hostApplicationProxy",
            "hostApplication",
            "_hostApplication",
            "_hostBundleInfo",
            "hostBundleInfo"
        ]

        let hostProxySelNames = [
            "_hostApplicationProxy",
            "hostApplicationProxy",
            "_hostApplication",
            "hostApplication"
        ]

        rlog("[VoiceInputTrigger] detectHostBundleID start: vc=\(type(of: viewController)), candidates=\(targets.count)")

        for target in targets {
            let targetType = String(describing: type(of: target))

            for selName in hostProxySelNames {
                let sel = NSSelectorFromString(selName)
                guard target.responds(to: sel) else { continue }
                guard let result = target.perform(sel) else { continue }
                let obj = result.takeUnretainedValue()
                if let proxy = obj as? NSObject, let bundleID = extractHostBundleFromProxy(proxy), isValidHostBundleID(bundleID) {
                    rlog("[VoiceInputTrigger] detected host bundle via proxy \(targetType).\(selName): \(bundleID)")
                    return bundleID
                }
            }

            for selName in allSelNames {
                let sel = NSSelectorFromString(selName)
                guard target.responds(to: sel) else { continue }
                guard let result = target.perform(sel) else { continue }
                let raw = result.takeUnretainedValue()

                if let proxy = raw as? NSObject, let bundleID = extractHostBundleFromProxy(proxy), isValidHostBundleID(bundleID) {
                    rlog("[VoiceInputTrigger] detected host bundle via proxy object \(targetType).\(selName): \(bundleID)")
                    return bundleID
                }

                if let bundleID = asNormalizedHostString(raw), isValidHostBundleID(bundleID) {
                    rlog("[VoiceInputTrigger] detected host bundle via \(targetType).\(selName): \(bundleID)")
                    return bundleID
                }

                rlog("[VoiceInputTrigger] \(targetType).\(selName) returned unusable: \(raw)")
            }
        }

        // Note: proc_pidpath approach is not attempted here because it is blocked
        // by the keyboard extension sandbox. Instead, the PID is saved via
        // detectHostPID() and resolved by the main app.
        rlog("[VoiceInputTrigger] all host bundle ID detection methods failed")
        return nil
    }

    /// Extract the host app PID from the view controller hierarchy.
    /// The PID is passed to the main app via AppGroupBridge for resolution,
    /// since proc_pidpath is blocked by the keyboard extension sandbox.
    private static func detectHostPID(from viewController: UIViewController) -> Int32? {
        let targets = hostCandidateTargets(from: viewController)
        let pidSelNames = [
            "_hostProcessIdentifier",
            "hostProcessIdentifier",
            "_hostProcessId",
            "hostProcessId",
            "_hostPID",
            "hostPID",
            "hostProcessID",
            "_hostProcessID",
            "_hostPid"
        ]

        func asInt32(_ raw: Any) -> Int32? {
            if let n = raw as? NSNumber {
                return n.int32Value
            }
            if let s = raw as? NSString {
                return Int32(s.intValue)
            }
            if let s = raw as? String {
                return Int32(s)
            }
            let fallback = String(describing: raw)
            return Int32(fallback)
        }

        for target in targets {
            let targetType = String(describing: type(of: target))
            for pidSelName in pidSelNames {
                let pidSel = NSSelectorFromString(pidSelName)
                guard target.responds(to: pidSel) else {
                    continue
                }

                let method = target.method(for: pidSel)
                if method != nil {
                    // Int32-returning selector signature.
                    typealias PidFunc = @convention(c) (AnyObject, Selector) -> Int32
                    let getHostPid = unsafeBitCast(method, to: PidFunc.self)
                    let hostPid = getHostPid(target, pidSel)
                    if hostPid > 0 {
                        rlog("[VoiceInputTrigger] \(targetType).\(pidSelName) = \(hostPid) (typed)")
                        return hostPid
                    }
                }

                // Fallback when selector unexpectedly returns object.
                if let result = target.perform(pidSel) {
                    let obj = result.takeUnretainedValue()
                    if let hostPid = asInt32(obj), hostPid > 0 {
                        rlog("[VoiceInputTrigger] \(targetType).\(pidSelName) = \(hostPid) (object)")
                        return hostPid
                    }
                }
            }
        }

        rlog("[VoiceInputTrigger] no valid host PID found")
        return nil
    }

        /// Open the main Echo app for voice recording.
    /// Includes a trace ID so the app can match the launch acknowledgement.
    static func openMainAppForVoice(from viewController: UIViewController?, completion: ((Bool) -> Void)? = nil) {
        // Save the host app's bundle ID so main app can return to it
        let hostInfo = saveHostAppBundleID(from: viewController)
        AppGroupBridge().setPendingLaunchIntent(.voice)
        let trace = UUID().uuidString.prefix(8)
        logEvent("openMainAppForVoice trace=\(trace) intent set")

        func appendHostQuery(_ url: URL) -> URL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "trace", value: String(trace)))

            if let hostBundle = hostInfo.bundleID {
                items.append(URLQueryItem(name: "hostBundle", value: hostBundle))
            }
            if let hostPID = hostInfo.pid {
                items.append(URLQueryItem(name: "hostPID", value: String(hostPID)))
            }
            components?.queryItems = items
            return components?.url ?? url
        }

        let baseURLs: [URL] = [
            AppGroupBridge.voiceInputURL,
            URL(string: "echo://voice")!,
            URL(string: "echo:///voice")!,
            URL(string: "echoapp://voice")!,
            URL(string: "echoapp:///voice")!
        ]

        let urls = baseURLs.map(appendHostQuery)
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
        let bridge = AppGroupBridge()

        let finish: (Bool) -> Void = { success in
            guard !didFinish else { return }
            didFinish = true
            completion?(success)
        }

        var hadInvoked = false

        func attempt(at index: Int) {
            guard index < urls.count else {
                // Keep pending launch intent when no URL route is acknowledged.
                // This avoids silently dropping the intent and lets the
                // main app recover via its AppGroup poller within the
                // pending-intent validity window (default 30s).
                finish(hadInvoked && bridge.hasRecentPendingLaunchIntent())
                return
            }

            let candidate = urls[index]
            logEvent("trying launch url[\(index)]=\(candidate.absoluteString)")
            open(url: candidate, from: viewController) { didInvoke in
                if didInvoke {
                    hadInvoked = true
                } else {
                    logEvent("launch candidate did not invoke URL, trying next")
                    attempt(at: index + 1)
                    return
                }

                waitForLaunchAcknowledgement(timeout: launchAckTimeout, pollInterval: launchAckPollInterval) { acknowledged in
                    guard !didFinish else { return }
                    logEvent("launch ack for \(candidate.absoluteString): \(acknowledged)", category: "LaunchAck")
                    if acknowledged {
                        finish(true)
                    } else {
                        logEvent("launch ack not observed for \(candidate.absoluteString), trying next candidate")
                        attempt(at: index + 1)
                    }
                }
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

        // Step 1: Fire extensionContext.open() to register the "Back to [host app]"
        // navigation context with iOS. On iOS 18+ this may not actually open the URL,
        // but it tells the system that the host app is the return target when our app
        // calls suspend(). Without this, suspend() returns to the Home screen instead
        // of the host app for third-party apps.
        if let extensionContext = viewController?.extensionContext {
            logEvent("extensionContext.open for back-navigation context: \(urlString)")
            extensionContext.open(url, completionHandler: nil)
        }

        // Step 2: Actually open the URL via UIApplication runtime access.
        // This is the reliable path on iOS 18+ for keyboard extensions.
        if openURLFromExtension(url) {
            logEvent("open via UIApplication runtime succeeded for \(urlString)")
            finish(true)
            return
        }

        // Step 3: Fallbacks for older iOS versions
        guard let viewController else {
            completion?(false)
            return
        }

        if let inputViewController = viewController as? UIInputViewController,
           openViaInputViewController(url, from: inputViewController) {
            logEvent("open via UIInputViewController.openURL for \(urlString)")
            finish(true)
            return
        }

        if openViaResponderChain(url: url, from: viewController) {
            logEvent("open via responder chain for \(urlString)")
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
                        logEvent("VoiceInputTrigger: \(selector.description) completion result for \(url.absoluteString): \(opened)", category: "openViaResponderChain")
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
                        logEvent("openURL:options:completionHandler: completion result for \(url.absoluteString): \(opened)")
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
                        logEvent("openURL:options:completionHandler:sourceApplication: completion result for \(url.absoluteString): \(opened)")
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
                logEvent("openURL:completion result for \(url.absoluteString): \(opened)")
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
