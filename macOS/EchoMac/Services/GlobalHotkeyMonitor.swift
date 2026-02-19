import Foundation
import Cocoa
import Carbon.HIToolbox

/// Monitor for global hotkey events (Fn, Option, Command keys)
/// Uses CGEventTap for robust global event monitoring
@MainActor
public final class GlobalHotkeyMonitor: ObservableObject {
    // MARK: - Types

    public enum HotkeyEvent {
        case pressed
        case released
    }

    public typealias HotkeyHandler = (HotkeyEvent) -> Void

    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: HotkeyHandler?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    @Published public private(set) var isMonitoring = false
    @Published public private(set) var currentHotkeyPressed = false

    private let settings: MacAppSettings

    // For double-tap detection
    private var lastCommandPressTime: Date?
    private let doubleTapInterval: TimeInterval = 0.3

    // MARK: - Initialization

    public init(settings: MacAppSettings = MacAppSettings()) {
        self.settings = settings
    }

    deinit {
        // Clean up - we can't call stop() from deinit due to MainActor
        // The resources will be cleaned up automatically
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    // MARK: - Public Methods

    /// Start monitoring for hotkey events
    public func start(handler: @escaping HotkeyHandler) {
        guard !isMonitoring else { return }

        self.handler = handler

        // Create event tap for flags changed events (modifier keys)
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        // We need to use a workaround for the callback since CGEventTap doesn't play nice with Swift
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // Re-enable the tap
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passRetained(event)
            }

            Task { @MainActor in
                monitor.handleEvent(event)
            }

            return Unmanaged.passRetained(event)
        }

        // Create the event tap
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            print("⚠️ Failed to create event tap - falling back to NSEvent monitor")
            startFallbackMonitors()
            return
        }

        // Create run loop source
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let source = runLoopSource else {
            print("❌ Failed to create run loop source")
            return
        }

        // Add to run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isMonitoring = true
        print("✅ Global hotkey monitoring started for: \(settings.hotkeyType.displayName)")
    }

    /// Stop monitoring for hotkey events
    public func stop() {
        guard isMonitoring else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        handler = nil
        isMonitoring = false
        currentHotkeyPressed = false

        print("🛑 Global hotkey monitoring stopped")
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: CGEvent) {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        handleFlagsChanged(flags: flags, keyCode: keyCode)
    }

    private func handleFlagsChanged(flags: CGEventFlags, keyCode: Int64) {

        switch settings.hotkeyType {
        case .fn:
            handleFnKey(flags: flags, keyCode: keyCode)

        case .rightOption:
            handleModifierKey(
                flags: flags,
                keyCode: keyCode,
                targetKeyCodes: [kVK_RightOption, kVK_Option],
                flagToCheck: .maskAlternate
            )

        case .leftOption:
            handleModifierKey(
                flags: flags,
                keyCode: keyCode,
                targetKeyCodes: [kVK_Option, kVK_RightOption],
                flagToCheck: .maskAlternate
            )

        case .rightCommand:
            handleModifierKey(
                flags: flags,
                keyCode: keyCode,
                targetKeyCodes: [kVK_RightCommand, kVK_Command],
                flagToCheck: .maskCommand
            )

        case .doubleCommand:
            handleDoubleCommand(flags: flags, keyCode: keyCode)
        }
    }

    private func startFallbackMonitors() {
        // Use NSEvent global + local monitor as a fallback when CGEventTap fails.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            let keyCode = Int64(event.keyCode)
            Task { @MainActor in
                self.handleFlagsChanged(flags: flags, keyCode: keyCode)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            let keyCode = Int64(event.keyCode)
            Task { @MainActor in
                self.handleFlagsChanged(flags: flags, keyCode: keyCode)
            }
            return event
        }

        isMonitoring = true
        print("✅ Global hotkey monitoring started (NSEvent fallback) for: \(settings.hotkeyType.displayName)")
    }

    private func handleFnKey(flags: CGEventFlags, keyCode: Int64) {
        // Fn key is detected via .maskSecondaryFn flag.
        // Important: only react to the physical Fn/Globe key events to avoid
        // accidental capture when Caps Lock is remapped to Globe/Fn at OS level.
        let isPhysicalFnEvent = keyCode == Int64(kVK_Function)

        if !isPhysicalFnEvent {
            // If we were previously pressed, still allow release when Fn flag clears.
            if currentHotkeyPressed, !flags.contains(.maskSecondaryFn) {
                currentHotkeyPressed = false
                handler?(.released)
            }
            return
        }

        let fnPressed = flags.contains(.maskSecondaryFn)
        if fnPressed != currentHotkeyPressed {
            currentHotkeyPressed = fnPressed
            handler?(fnPressed ? .pressed : .released)
        }
    }

    private func handleModifierKey(
        flags: CGEventFlags,
        keyCode: Int64,
        targetKeyCodes: [Int],
        flagToCheck: CGEventFlags
    ) {
        if currentHotkeyPressed, !flags.contains(flagToCheck) {
            currentHotkeyPressed = false
            handler?(.released)
            return
        }

        // Check if this is a target key we want
        guard targetKeyCodes.contains(Int(keyCode)) else { return }

        let isPressed = flags.contains(flagToCheck)

        if isPressed != currentHotkeyPressed {
            currentHotkeyPressed = isPressed
            handler?(isPressed ? .pressed : .released)
        }
    }

    private func handleDoubleCommand(flags: CGEventFlags, keyCode: Int64) {
        // Either left or right command key
        let isCommandKey = keyCode == kVK_Command || keyCode == kVK_RightCommand
        guard isCommandKey else { return }

        let commandPressed = flags.contains(.maskCommand)

        // Detect press (not release)
        if commandPressed {
            let now = Date()
            if let lastPress = lastCommandPressTime,
               now.timeIntervalSince(lastPress) < doubleTapInterval {
                // Double tap detected - toggle state
                currentHotkeyPressed.toggle()
                handler?(currentHotkeyPressed ? .pressed : .released)
                lastCommandPressTime = nil // Reset
            } else {
                lastCommandPressTime = now
            }
        }
    }
}

// MARK: - Key Code Constants

private let kVK_Option = 58
private let kVK_RightOption = 61
private let kVK_Command = 55
private let kVK_RightCommand = 54
private let kVK_Function = 63
