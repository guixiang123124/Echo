import SwiftUI
import EchoCore
import UIKit

// proc_pidpath is in libproc — used to resolve host app PID to bundle path.
// The main app has fewer sandbox restrictions than the keyboard extension,
// so PID resolution is done here instead of in the extension.
@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ buffersize: UInt32) -> Int32

struct MainView: View {
   private enum Tab: Int {
       case home = 0
       case history = 1
       case dictionary = 2
       case account = 3
   }

   fileprivate enum DeepLink {
       case settings
   }

   @State private var selectedTab: Tab = .home
   @State private var deepLink: DeepLink?
   @State private var isHandlingKeyboardVoiceIntent = false
   @EnvironmentObject var authSession: EchoAuthSession
   @EnvironmentObject var backgroundDictation: BackgroundDictationService
   @Environment(\.scenePhase) private var scenePhase
   private let keyboardIntentPoll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
   @State private var noIntentLogCounter = 0
   @State private var noIntentLastLog = Date.distantPast

   var body: some View {
       TabView(selection: $selectedTab) {
           EchoHomeView()
               .tabItem {
                   Label("Home", systemImage: "house")
               }
               .tag(Tab.home)

           EchoHistoryView()
               .tabItem {
                   Label("History", systemImage: "clock.fill")
               }
               .tag(Tab.history)

           EchoDictionaryView()
               .tabItem {
                   Label("Dictionary", systemImage: "book.closed")
               }
               .tag(Tab.dictionary)

           EchoAccountView()
               .tabItem {
                   Label("Account", systemImage: "person.crop.circle")
               }
               .tag(Tab.account)
       }
       .tint(.primary)
       .onReceive(authSession.$user) { user in
           CloudSyncService.shared.updateAuthState(user: user)
           BillingService.shared.updateAuthState(user: user)
           Task { await BillingService.shared.refresh() }
       }
    .onOpenURL { url in
           print("[EchoApp] onOpenURL received: \(url.absoluteString)")
           logEvent("onOpenURL received: \(url.absoluteString)")
           configureReturnContextFromURL(url)
           guard url.scheme == "echo" || url.scheme == "echoapp" else {
               print("[EchoApp] onOpenURL ignored due unsupported scheme: \(url.scheme ?? "<none>")")
               logEvent("onOpenURL unsupported scheme: \(url.scheme ?? "<none>")")
               return
           }
           let route = (url.host?.isEmpty == false ? url.host : nil)
               ?? url.pathComponents.dropFirst().first
               .map { $0.lowercased() }
           guard let route else { return }
           print("[EchoApp] onOpenURL parsed route: \(route)")
           logEvent("onOpenURL parsed route: \(route)")
           switch route {
           case "home":
               logEvent("onOpenURL route home")
               selectedTab = .home
               deepLink = nil
           case "history":
               logEvent("onOpenURL route history")
               selectedTab = .history
               deepLink = nil
           case "dictionary":
               logEvent("onOpenURL route dictionary")
               selectedTab = .dictionary
               deepLink = nil
           case "account":
               logEvent("onOpenURL route account")
               selectedTab = .account
               deepLink = nil
           case "voice":
               logEvent("onOpenURL route voice")
               handleVoiceDeepLink()
           case "settings":
               logEvent("onOpenURL route settings")
               deepLink = .settings
               AppGroupBridge().markLaunchAcknowledged()
               AppGroupBridge().clearPendingLaunchIntent()
           default:
               print("[EchoApp] onOpenURL unsupported route: \(route)")
               logEvent("onOpenURL unsupported route: \(route)")
               break
           }
       }
       .onAppear {
           consumeKeyboardLaunchIntentIfNeeded()
       }
       .onReceive(keyboardIntentPoll) { _ in
           consumeKeyboardLaunchIntentIfNeeded()
       }
       .onChange(of: scenePhase) { _, newValue in
           guard newValue == .active else { return }
           consumeKeyboardLaunchIntentIfNeeded()
       }
       .overlay(alignment: .top) {
           BackgroundDictationOverlay(service: backgroundDictation)
       }
       .sheet(item: $deepLink) { link in
           switch link {
           case .settings:
               SettingsView()
           }
       }
   }
}

extension MainView.DeepLink: Identifiable {
   var id: String {
       switch self {
       case .settings: return "settings"
       }
   }
}

   private extension MainView {
    private func logEvent(_ message: String, category: String = "MainView") {
        rlog("[\(category)] \(message)")
        AppGroupBridge().appendDebugEvent(message, source: "mainapp", category: category)
    }

    func handleVoiceDeepLink() {
        guard !isHandlingKeyboardVoiceIntent else {
            logEvent("handleVoiceDeepLink skipped: already handling")
            print("[EchoApp] handleVoiceDeepLink skipped: already handling")
            return
        }

        logEvent("handleVoiceDeepLink started")
        isHandlingKeyboardVoiceIntent = true
        let bridge = AppGroupBridge()
        bridge.markLaunchAcknowledged()

        Task {
            defer {
                Task { @MainActor in
                    isHandlingKeyboardVoiceIntent = false
                }
            }

            await MainActor.run {
                backgroundDictation.activate(authSession: authSession)
                logEvent("main app activated for keyboard intent")
            }

            // Toggle: if already recording, stop instead of starting a new session.
            let currentState = await MainActor.run { backgroundDictation.state }
            switch currentState {
            case .recording, .transcribing:
                print("[EchoApp] handleVoiceDeepLink: already recording, toggling to stop")
                logEvent("state already recording/transcribing, toggling stop. state=\(currentState)")
                await backgroundDictation.stopDictation()
                await MainActor.run {
                    bridge.clearPendingLaunchIntent()
                    autoReturnToHostApp()
                }
                return

            case .finalizing:
                print("[EchoApp] handleVoiceDeepLink: finalizing, returning immediately")
                logEvent("state finalizing, returning immediately")
                await MainActor.run {
                    bridge.clearPendingLaunchIntent()
                    autoReturnToHostApp()
                }
                return

            case .idle, .error:
                break // Proceed to start
            }

            await backgroundDictation.startDictationForKeyboardIntent()
            logEvent("startDictationForKeyboardIntent called")

            // Wait briefly for recording to initialize, then return regardless.
            // On cold launch the audio engine may take a moment to spin up.
            // The recording continues in background via audio background mode.
            let started = await waitForRecordingState(timeout: 1.5)
            print("[EchoApp] handleVoiceDeepLink: recording started=\(started), state=\(backgroundDictation.state)")
            logEvent("waitForRecordingState result=\(started), finalState=\(backgroundDictation.state)")

            await MainActor.run {
                bridge.clearPendingLaunchIntent()
                logEvent("cleared pending launch intent")

                if case .error = backgroundDictation.state {
                    print("[EchoApp] handleVoiceDeepLink: error state, staying in app")
                    logEvent("error state after start attempt; stay in app")
                    return
                }

                // Always return to the previous app. Even if recording hasn't
                // fully started yet, the audio background mode keeps us alive.
                autoReturnToHostApp()
            }
        }
    }

    func waitForRecordingState(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .recording = backgroundDictation.state {
                return true
            }
            if case .transcribing = backgroundDictation.state {
                return true
            }
            if case .finalizing = backgroundDictation.state {
                return true
            }
            if case .error = backgroundDictation.state {
                return false
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return false
    }


    private func logIntentPollNoIntent() {
        noIntentLogCounter += 1
        let now = Date()
        // Throttle noisy poll logs. We still keep evidence by batching counts.
        if now.timeIntervalSince(noIntentLastLog) >= 3.0 {
            if noIntentLogCounter == 1 {
                logEvent("consumeKeyboardLaunchIntentIfNeeded no intent", category: "MainView.Intent")
            } else {
                logEvent("consumeKeyboardLaunchIntentIfNeeded no intent x\(noIntentLogCounter)", category: "MainView.Intent")
            }
            noIntentLogCounter = 0
            noIntentLastLog = now
        }
    }

    private func isValidHostBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if bundleID == Bundle.main.bundleIdentifier { return false }
        if bundleID.hasSuffix(".keyboard") { return false }
        if bundleID.hasPrefix("com.apple.") { return false }
        return bundleID.contains(".")
    }

    private func configureReturnContextFromURL(_ url: URL) {
        let bridge = AppGroupBridge()
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let queryItems = components.queryItems ?? []

        if let hostBundle = queryItems.first(where: { $0.name == "hostBundle" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
           isValidHostBundleID(hostBundle) {
            print("[EchoApp] onOpenURL captured hostBundle: \(hostBundle)")
            bridge.setReturnAppBundleID(hostBundle)
            bridge.clearReturnAppPID()
            bridge.appendDebugEvent("hostBundle parsed from URL: \(hostBundle)", source: "mainapp", category: "MainView.Return")
            return
        }

        if let hostProcessName = queryItems.first(where: { $0.name == "hostProcessName" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostProcessName.isEmpty,
           bridge.returnAppBundleID == nil {
            let candidate = hostProcessName.lowercased()
            if let bundleID = matchBundleIDByProcessName(candidate) {
                print("[EchoApp] onOpenURL mapped hostProcessName \(hostProcessName) -> \(bundleID)")
                bridge.setReturnAppBundleID(bundleID)
                bridge.clearReturnAppPID()
                bridge.appendDebugEvent("hostProcessName mapped to bundleID from URL: \(candidate) -> \(bundleID)", source: "mainapp", category: "MainView.Return")
                return
            }
            print("[EchoApp] onOpenURL captured hostProcessName: \(hostProcessName)")
            bridge.appendDebugEvent("hostProcessName parsed from URL: \(hostProcessName)", source: "mainapp", category: "MainView.Return")
        }

        if let hostPIDString = queryItems.first(where: { $0.name == "hostPID" })?.value,
           let hostPID = Int32(hostPIDString),
           hostPID > 0,
           bridge.returnAppBundleID == nil {
            print("[EchoApp] onOpenURL captured hostPID: \(hostPID)")
            bridge.setReturnAppPID(hostPID)
            bridge.appendDebugEvent("hostPID parsed from URL: \(hostPID)", source: "mainapp", category: "MainView.Return")
        }
    }

    func consumeKeyboardLaunchIntentIfNeeded() {
        let bridge = AppGroupBridge()
        guard let intent = bridge.consumePendingLaunchIntent(maxAge: 30) else {
            logIntentPollNoIntent()
            return
        }
       noIntentLogCounter = 0
       noIntentLastLog = Date()
       logEvent("consumeKeyboardLaunchIntentIfNeeded got intent=\(intent)", category: "MainView.Intent")
       switch intent {
        case .voice, .voiceControl:
            handleVoiceDeepLink()
        case .settings:
            deepLink = .settings
            bridge.markLaunchAcknowledged()
        }
    }

    func autoReturnToHostApp() {
        let bridge = AppGroupBridge()
        let suspendDelay: TimeInterval = 0.08
        logEvent("autoReturnToHostApp start")

        // Try returning to the specific host app by bundle ID.
        // This is needed for third-party apps where suspend() goes to Home screen.
        if let hostBundleID = bridge.returnAppBundleID, !hostBundleID.isEmpty {
            logEvent("autoReturnToHostApp use return bundleID=\(hostBundleID)")
            bridge.clearReturnAppBundleID()
            bridge.clearReturnAppPID()
            rlog("[EchoApp] autoReturnToHostApp: got host bundle ID = \(hostBundleID), trying LSApplicationWorkspace now")

            if openAppByBundleID(hostBundleID) {
                AppGroupBridge().appendDebugEvent("autoReturnToHostApp bundleID open success: \(hostBundleID)", source: "mainapp", category: "MainView.Return")
                rlog("[EchoApp] autoReturnToHostApp: LSApplicationWorkspace succeeded for \(hostBundleID)")
                return
            }

            AppGroupBridge().appendDebugEvent("autoReturnToHostApp bundleID open failed, fallback suspend", source: "mainapp", category: "MainView.Return")
            rlog("[EchoApp] autoReturnToHostApp: LSApplicationWorkspace failed for \(hostBundleID), fallback suspend in \(suspendDelay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + suspendDelay) {
                AppGroupBridge().appendDebugEvent("autoReturnToHostApp fallback suspend", source: "mainapp", category: "MainView.Return")
                suspendApp()
            }
            return
        }

        // Fallback: resolve host app PID to bundle ID, single-attempt.
        if let hostPID = bridge.returnAppPID {
            logEvent("autoReturnToHostApp use return PID=\(hostPID)")
            bridge.clearReturnAppPID()

            if let resolvedBundleID = resolveBundleIDFromPID(hostPID) {
                rlog("[EchoApp] autoReturnToHostApp: resolved PID \(hostPID) -> \(resolvedBundleID), trying LSApplicationWorkspace now")
                if openAppByBundleID(resolvedBundleID) {
                    AppGroupBridge().appendDebugEvent("autoReturnToHostApp PID resolved bundleID open success: \(resolvedBundleID)", source: "mainapp", category: "MainView.Return")
                    rlog("[EchoApp] autoReturnToHostApp: LSApplicationWorkspace succeeded for \(resolvedBundleID) (from PID \(hostPID))")
                    return
                }
                AppGroupBridge().appendDebugEvent("autoReturnToHostApp PID resolved bundleID open failed: \(resolvedBundleID)", source: "mainapp", category: "MainView.Return")
                rlog("[EchoApp] autoReturnToHostApp: LSApplicationWorkspace failed for \(resolvedBundleID)")
            } else {
                AppGroupBridge().appendDebugEvent("autoReturnToHostApp PID resolve failed for \(hostPID)", source: "mainapp", category: "MainView.Return")
                rlog("[EchoApp] autoReturnToHostApp: PID resolve failed for \(hostPID)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + suspendDelay) {
                AppGroupBridge().appendDebugEvent("autoReturnToHostApp using fallback suspend after PID path", source: "mainapp", category: "MainView.Return")
                suspendApp()
            }
            return
        }

        // Fallback: suspend (works for system apps)
        rlog("[EchoApp] autoReturnToHostApp: no host bundle ID or PID available, scheduling suspend in \(suspendDelay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + suspendDelay) {
            AppGroupBridge().appendDebugEvent("autoReturnToHostApp using fallback suspend", source: "mainapp", category: "MainView.Return")
            suspendApp()
        }
    }

    /// Resolve a PID to a bundle ID using multiple strategies.
    /// Strategy 1: direct PID field on LSApplicationWorkspace application objects.
    /// Strategy 2: proc_pidpath (fails on iOS sandbox but kept for diagnostics).
    /// Strategy 3: sysctl KERN_PROC_PID → process name → match installed apps.
    func resolveBundleIDFromPID(_ pid: Int32) -> String? {
        // Strategy 1: scan installed app proxies for matching PID.
        if let bundleID = matchBundleIDByProcessID(pid) {
            rlog("[EchoApp] resolveBundleIDFromPID: PID \(pid) matched running app proxy: \(bundleID)")
            return bundleID
        }

        // Strategy 2: proc_pidpath (best effort; often restricted in sandbox)
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLen > 0 {
            let execPath = String(cString: pathBuffer)
            rlog("[EchoApp] resolveBundleIDFromPID: proc_pidpath OK: \(execPath)")
            let appBundlePath = (execPath as NSString).deletingLastPathComponent
            let infoPlistPath = appBundlePath + "/Info.plist"
            if let dict = NSDictionary(contentsOfFile: infoPlistPath),
               let bundleID = dict["CFBundleIdentifier"] as? String,
               !bundleID.isEmpty {
                rlog("[EchoApp] resolveBundleIDFromPID: resolved PID \(pid) -> \(bundleID) via proc_pidpath")
                return bundleID
            }
        } else {
            rlog("[EchoApp] resolveBundleIDFromPID: proc_pidpath(\(pid)) failed (returned \(pathLen))")
        }

        // Strategy 3: sysctl → process name → match installed apps via LSApplicationWorkspace.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            rlog("[EchoApp] resolveBundleIDFromPID: sysctl KERN_PROC_PID failed for PID \(pid)")
            return nil
        }

        let processName = withUnsafePointer(to: info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
        guard !processName.isEmpty else {
            rlog("[EchoApp] resolveBundleIDFromPID: empty process name for PID \(pid)")
            return nil
        }
        rlog("[EchoApp] resolveBundleIDFromPID: PID \(pid) process name = '\(processName)'")
        let normalizedProcessName = processName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedCandidate = normalizedProcessName.isEmpty ? processName : normalizedProcessName
        if let bundleID = matchBundleIDByProcessName(normalizedCandidate) {
            return bundleID
        }

        rlog("[EchoApp] resolveBundleIDFromPID: all strategies failed for PID \(pid)")
        return nil
    }


    /// Match a process ID against installed app proxies using LSApplicationWorkspace.
    func matchBundleIDByProcessID(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        guard let apps = installedApplicationsFromWorkspace() else { return nil }

        let bundleIDSel = NSSelectorFromString("applicationIdentifier")
        let pidSelectors = [
            "pid",
            "processIdentifier",
            "applicationProcessIdentifier",
            "bundleSeedID",
            "pidString",
            "bundleIdentifier"
        ]

        for app in apps {
            for selName in pidSelectors {
                let sel = NSSelectorFromString(selName)
                let value = extractInt32(from: app, selector: sel)
                if let value, value == pid {
                    guard let idResult = app.perform?(bundleIDSel),
                          let bundleID = idResult.takeUnretainedValue() as? String else {
                        continue
                    }
                    rlog("[EchoApp] matchBundleIDByProcessID: matched selector '\(selName)' -> \(pid), bundleID=\(bundleID)")
                    return bundleID
                }
            }
        }

        rlog("[EchoApp] matchBundleIDByProcessID: no running-app PID match for \(pid)")
        return nil
    }

    /// Parse an Int32 value from an object's selector result.
    private func extractInt32(from obj: AnyObject, selector: Selector) -> Int32? {
        guard let nsObj = obj as? NSObject else { return nil }
        guard nsObj.responds(to: selector) else { return nil }

        if let method = nsObj.method(for: selector) {
            typealias Fn = @convention(c) (AnyObject, Selector) -> Int32
            let fn = unsafeBitCast(method, to: Fn.self)
            let v = fn(nsObj, selector)
            if v > 0 { return v }
        }

        if let result = nsObj.perform(selector) {
            let value = result.takeUnretainedValue()
            if let n = value as? NSNumber {
                let intValue = n.int32Value
                if intValue > 0 { return intValue }
            }
            if let s = value as? NSString {
                let intValue = Int32(s.intValue)
                if intValue > 0 { return intValue }
            }
            if let s = value as? String {
                let intValue = Int32(s)
                if let intValue, intValue > 0 { return intValue }
            }
        }

        return nil
    }

    private func installedApplicationsFromWorkspace() -> [AnyObject]? {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") else {
            rlog("[EchoApp] installedApplicationsFromWorkspace: LSApplicationWorkspace not available")
            return nil
        }

        let defaultWsSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defaultWsSel),
              let wsResult = (wsClass as AnyObject).perform(defaultWsSel) else {
            rlog("[EchoApp] installedApplicationsFromWorkspace: defaultWorkspace unavailable")
            return nil
        }

        let workspace = wsResult.takeUnretainedValue()
        let allAppsSel = NSSelectorFromString("allApplications")
        guard (workspace as AnyObject).responds(to: allAppsSel),
              let appsResult = (workspace as AnyObject).perform(allAppsSel),
              let apps = appsResult.takeUnretainedValue() as? [AnyObject] else {
            rlog("[EchoApp] installedApplicationsFromWorkspace: allApplications unavailable")
            return nil
        }

        return apps
    }

    /// Match a process name against installed apps using LSApplicationWorkspace.
    func matchBundleIDByProcessName(_ processName: String) -> String? {
        guard let apps = installedApplicationsFromWorkspace() else {
            return nil
        }

        let bundleIDSel = NSSelectorFromString("applicationIdentifier")
        let bundleURLSel = NSSelectorFromString("bundleURL")
        rlog("[EchoApp] matchBundleIDByProcessName: searching \(apps.count) apps for '\(processName)'")

        // Pass 1: exact match against .app directory name (fast)
        for app in apps {
            guard let urlResult = app.perform?(bundleURLSel),
                  let url = urlResult.takeUnretainedValue() as? URL,
                  url.lastPathComponent.hasSuffix(".app") else { continue }
            let execName = String(url.lastPathComponent.dropLast(4))
            if execName == processName {
                if let idResult = app.perform?(bundleIDSel),
                   let bundleID = idResult.takeUnretainedValue() as? String {
                    rlog("[EchoApp] matchBundleIDByProcessName: exact match '\(processName)' → \(bundleID)")
                    return bundleID
                }
            }
        }

        // Pass 2: prefix match for truncated names (MAXCOMLEN = 16 chars)
        if processName.count >= 15 {
            for app in apps {
                guard let urlResult = app.perform?(bundleURLSel),
                      let url = urlResult.takeUnretainedValue() as? URL,
                      url.lastPathComponent.hasSuffix(".app") else { continue }
                let execName = String(url.lastPathComponent.dropLast(4))
                if execName.hasPrefix(processName) {
                    if let idResult = app.perform?(bundleIDSel),
                       let bundleID = idResult.takeUnretainedValue() as? String {
                        rlog("[EchoApp] matchBundleIDByProcessName: prefix match '\(processName)' → \(bundleID) (full: \(execName))")
                        return bundleID
                    }
                }
            }
        }

        // Pass 3: match against CFBundleExecutable from Info.plist (slower but handles
        // apps where directory name differs from executable name)
        for app in apps {
            guard let urlResult = app.perform?(bundleURLSel),
                  let url = urlResult.takeUnretainedValue() as? URL else { continue }
            let infoPlistURL = url.appendingPathComponent("Info.plist")
            guard let dict = NSDictionary(contentsOf: infoPlistURL),
                  let cfExec = dict["CFBundleExecutable"] as? String else { continue }
            let matches = cfExec == processName || (processName.count >= 15 && cfExec.hasPrefix(processName))
            if matches {
                if let idResult = app.perform?(bundleIDSel),
                   let bundleID = idResult.takeUnretainedValue() as? String {
                    rlog("[EchoApp] matchBundleIDByProcessName: Info.plist match '\(processName)' → \(bundleID) (exec: \(cfExec))")
                    return bundleID
                }
            }
        }

        // Pass 4: relaxed match against tokens and display/executable names.
        if let tokens = processName.split(separator: "-").first {
            for app in apps {
                guard let idResult = app.perform?(bundleIDSel), let bundleID = idResult.takeUnretainedValue() as? String else { continue }
                guard let urlResult = app.perform?(bundleURLSel), let url = urlResult.takeUnretainedValue() as? URL else { continue }
                let appPathName = url.lastPathComponent.lowercased()
                if appPathName.contains(processName.lowercased()) || appPathName.contains(tokens.lowercased()) {
                    rlog("[EchoApp] matchBundleIDByProcessName: relaxed token match '\(processName)' → \(bundleID) (app: \(appPathName))")
                    return bundleID
                }

                if let dict = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
                   let displayName = dict["CFBundleDisplayName"] as? String,
                   let exec = dict["CFBundleExecutable"] as? String,
                   displayName.lowercased().contains(processName.lowercased()) || exec.lowercased().contains(processName.lowercased()) || displayName.lowercased().contains(tokens.lowercased()) || exec.lowercased().contains(tokens.lowercased()) {
                    rlog("[EchoApp] matchBundleIDByProcessName: display/exec relaxed match '\(processName)' → \(bundleID) (exec: \(exec), display: \(displayName))")
                    return bundleID
                }
            }
        }

        rlog("[EchoApp] matchBundleIDByProcessName: no match for '\(processName)' in \(apps.count) apps")
        return nil
    }

    func suspendApp() {
        let selector = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: selector) else {
            rlog("[EchoApp] suspendApp: suspend selector not available")
            return
        }
        rlog("[EchoApp] suspendApp: calling suspend now")
        UIApplication.shared.perform(selector)
    }

    func openAppByBundleID(_ bundleID: String) -> Bool {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") else {
            rlog("[EchoApp] LSApplicationWorkspace class not found")
            AppGroupBridge().appendDebugEvent("LSApplicationWorkspace class missing", source: "mainapp", category: "MainView.Return")
            return false
        }

        let defaultWsSel = NSSelectorFromString("defaultWorkspace")
        guard wsClass.responds(to: defaultWsSel) else {
            rlog("[EchoApp] LSApplicationWorkspace does not respond to defaultWorkspace")
            AppGroupBridge().appendDebugEvent("LSApplicationWorkspace defaultWorkspace missing", source: "mainapp", category: "MainView.Return")
            return false
        }
        guard let wsResult = (wsClass as AnyObject).perform(defaultWsSel) else {
            rlog("[EchoApp] defaultWorkspace returned nil")
            AppGroupBridge().appendDebugEvent("LSApplicationWorkspace defaultWorkspace call returned nil", source: "mainapp", category: "MainView.Return")
            return false
        }
        let workspace = wsResult.takeUnretainedValue()

        let openSel = NSSelectorFromString("openApplicationWithBundleIdentifier:")
        guard (workspace as AnyObject).responds(to: openSel) else {
            rlog("[EchoApp] workspace does not respond to openApplicationWithBundleIdentifier:")
            AppGroupBridge().appendDebugEvent("workspace openApplicationWithBundleIdentifier selector missing", source: "mainapp", category: "MainView.Return")
            return false
        }

        rlog("[EchoApp] opening app via LSApplicationWorkspace: \(bundleID)")
        AppGroupBridge().appendDebugEvent("LSApplicationWorkspace opening bundleID=\(bundleID)", source: "mainapp", category: "MainView.Return")
        _ = (workspace as AnyObject).perform(openSel, with: bundleID)
        return true
    }
}

enum EchoMobileTheme {
   static let pageBackground = Color(.systemGroupedBackground)
   static let cardBackground = Color(.secondarySystemBackground)
   static let cardSurface = Color(.systemBackground)
   static let border = Color(.separator).opacity(0.3)
   static let mutedText = Color(.secondaryLabel)
   static let accent = Color(red: 0.11, green: 0.53, blue: 0.98)

   static let accentSoft = Color(
       UIColor { traits in
           traits.userInterfaceStyle == .dark
               ? UIColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 1.0)
               : UIColor(red: 0.87, green: 0.94, blue: 1.0, alpha: 1.0)
       }
   )

   static let heroGradientStart = Color(
       UIColor { traits in
           traits.userInterfaceStyle == .dark
               ? UIColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1.0)
               : UIColor(red: 0.94, green: 0.97, blue: 1.0, alpha: 1.0)
       }
   )

   static let heroGradientEnd = Color(
       UIColor { traits in
           traits.userInterfaceStyle == .dark
               ? UIColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1.0)
               : UIColor(red: 0.92, green: 0.93, blue: 1.0, alpha: 1.0)
       }
   )

   static let heroGradient = LinearGradient(
       colors: [heroGradientStart, heroGradientEnd],
       startPoint: .topLeading,
       endPoint: .bottomTrailing
   )
}

struct EchoCard<Content: View>: View {
   let content: Content

   init(@ViewBuilder content: () -> Content) {
       self.content = content()
   }

   var body: some View {
       content
           .padding(16)
           .background(
               RoundedRectangle(cornerRadius: 18, style: .continuous)
                   .fill(EchoMobileTheme.cardSurface)
           )
           .overlay(
               RoundedRectangle(cornerRadius: 18, style: .continuous)
                   .stroke(EchoMobileTheme.border, lineWidth: 1)
           )
   }
}

struct EchoSectionHeading: View {
   let title: String
   let subtitle: String?

   init(_ title: String, subtitle: String? = nil) {
       self.title = title
       self.subtitle = subtitle
   }

   var body: some View {
       VStack(alignment: .leading, spacing: 4) {
           Text(title)
               .font(.system(size: 34, weight: .bold, design: .rounded))
               .foregroundStyle(.primary)
           if let subtitle {
               Text(subtitle)
                   .font(.system(size: 16))
                   .foregroundStyle(EchoMobileTheme.mutedText)
                   .fixedSize(horizontal: false, vertical: true)
           }
       }
   }
}

struct EchoStatusDot: View {
   let color: Color

   var body: some View {
       Circle()
           .fill(color)
           .frame(width: 8, height: 8)
   }
}
