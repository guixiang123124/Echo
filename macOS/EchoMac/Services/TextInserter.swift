import Foundation
import AppKit
import Carbon.HIToolbox

/// Inserts text into the currently focused application
/// Uses pasteboard + simulated Cmd+V for maximum compatibility
@MainActor
public final class TextInserter {
    // MARK: - Properties

    public struct StreamingInsertFailure: Sendable {
        public enum Category: String, Sendable {
            case focus
            case selection
            case accessibility
            case state
            case unknown
        }

        public let category: Category
        public let details: String

        public init(category: Category, details: String) {
            self.category = category
            self.details = details
        }
    }

    public enum StreamingAttachResult {
        case attached
        case failed(StreamingInsertFailure)
    }

    public enum StreamingUpdateResult {
        case updated(method: String, characterCount: Int)
        case failed(StreamingInsertFailure)
    }

    private struct StreamingInsertionState {
        let targetElement: AXUIElement
        var insertionRange: NSRange
        var expectedInsertedText: String
        var useKeyboardFallback: Bool
    }

    private var savedPasteboardContents: [NSPasteboard.PasteboardType: Data]?
    private var streamingState: StreamingInsertionState?
    private var streamingFallbackText: String = ""

    // MARK: - Public Methods

    /// Insert text at the current cursor position
    public func insert(_ text: String, restoreClipboard: Bool = true) async {
        guard !text.isEmpty else { return }

        // Prefer direct Accessibility insertion when the focused element supports it.
        // This avoids relying on synthetic Cmd+V for editors that block event posting.
        if insertViaAccessibility(text) {
            print("✅ Inserted text via Accessibility API (\(text.count) chars)")
            return
        }

        if restoreClipboard {
            // Save current pasteboard contents
            savePasteboard()
        }

        // Set the text to pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V keystroke
        await simulatePaste()

        // Small delay to ensure paste completes
        try? await Task.sleep(for: .milliseconds(100))

        if restoreClipboard {
            // Restore previous pasteboard contents
            restorePasteboard()
        } else {
            savedPasteboardContents = nil
        }

        print("✅ Inserted text: \"\(text.prefix(50))...\"")
    }

    // MARK: - Streaming Insertion

    /// Start a replacement-based streaming insertion session against the focused UI element.
    public func startStreamingInsertionSession() -> StreamingAttachResult {
        guard let focusedElement = focusedElement() else {
            return .failed(.init(category: .focus, details: "focus missing: no focused UI element"))
        }

        if let selectedRange = selectedTextRange(for: focusedElement) {
            let normalizedRange = normalizedRange(for: focusedElement, selectedRange)
            streamingState = StreamingInsertionState(
                targetElement: focusedElement,
                insertionRange: normalizedRange,
                expectedInsertedText: "",
                useKeyboardFallback: false
            )
            return .attached
        }

        guard let nsText = elementValue(for: focusedElement).flatMap({ $0 as NSString? }) else {
            print("⚠️ Streaming start no selection/value fallback; using keyboard-only insertion")
            streamingState = StreamingInsertionState(
                targetElement: focusedElement,
                insertionRange: NSRange(location: 0, length: 0),
                expectedInsertedText: "",
                useKeyboardFallback: true
            )
            streamingFallbackText = ""
            return .attached
        }

        let fallbackRange = NSRange(location: nsText.length, length: 0)
        let canMoveCaret = setSelectedRange(focusedElement, location: fallbackRange.location, length: 0)
        if !canMoveCaret {
            print("⚠️ Streaming start could not set insertion range on focused element; continuing with AX value replacement")
        }

        streamingState = StreamingInsertionState(
            targetElement: focusedElement,
            insertionRange: fallbackRange,
            expectedInsertedText: "",
            useKeyboardFallback: false
        )
        streamingFallbackText = ""
        return .attached
    }

    /// Replace the currently active streaming insertion segment with the latest partial text.
    public func updateStreamingInsertion(_ text: String) -> StreamingUpdateResult {
        guard var state = streamingState else {
            return .failed(.init(category: .state, details: "session inactive"))
        }

        let normalizedInput = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        if normalizedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !state.expectedInsertedText.isEmpty else {
                return .updated(method: state.useKeyboardFallback ? "keyboard-fallback-noop" : "selected-text-noop", characterCount: 0)
            }

            // Ignore empty partial/final payloads to avoid wiping in-flight insertion.
            streamingState = state
            return .updated(
                method: state.useKeyboardFallback ? "keyboard-fallback-noop" : "selected-text-noop",
                characterCount: state.expectedInsertedText.utf16.count
            )
        }

        let insertionText = normalizedInput

        if let focused = focusedElement(),
           !axElementsEqual(focused, state.targetElement) {
            print("⚠️ Streaming update target changed from session element")
            state.useKeyboardFallback = true
        }

        let replacementRange = normalizedRange(for: state.targetElement, state.insertionRange)
        state.insertionRange = replacementRange

        if state.useKeyboardFallback {
            if insertionText == state.expectedInsertedText {
                streamingState = state
                return .updated(method: "keyboard-fallback", characterCount: insertionText.utf16.count)
            }

            if performKeyboardStreamingUpdate(insertionText, state: &state) {
                streamingState = state
                return .updated(method: "keyboard-fallback", characterCount: insertionText.utf16.count)
            }

            return .failed(.init(category: .accessibility, details: "keyboard streaming update failed"))
        }

        if replaceSelectedRange(on: state.targetElement, range: replacementRange, with: insertionText) {
            let updatedRange = NSRange(location: replacementRange.location, length: (insertionText as NSString).length)
            state.insertionRange = updatedRange
            state.expectedInsertedText = insertionText
            streamingState = state
            _ = setSelectedRange(state.targetElement, location: updatedRange.location + updatedRange.length, length: 0)
            return .updated(method: "selected-text", characterCount: insertionText.utf16.count)
        }

        if replaceInElementValue(on: state.targetElement, range: replacementRange, with: insertionText) {
            let updatedRange = NSRange(location: replacementRange.location, length: (insertionText as NSString).length)
            state.insertionRange = updatedRange
            state.expectedInsertedText = insertionText
            streamingState = state
            _ = setSelectedRange(state.targetElement, location: updatedRange.location + updatedRange.length, length: 0)
            return .updated(method: "ax-value", characterCount: insertionText.utf16.count)
        }

        guard let currentValue = elementValue(for: state.targetElement) else {
            state.useKeyboardFallback = true
            if performKeyboardStreamingUpdate(insertionText, state: &state) {
                streamingState = state
                return .updated(method: "keyboard-fallback", characterCount: insertionText.utf16.count)
            }

            return .failed(.init(category: .accessibility, details: "AX read failed while applying fallback replacement"))
        }

        let nsText = currentValue as NSString
        let safeRange = normalizedRange(forLength: nsText.length, range: replacementRange)
        guard safeRange.location != NSNotFound else {
            streamingState = nil
            return .failed(.init(category: .selection, details: "selection range invalid (AX replacement range resolved outside element length)"))
        }

        let currentSegment = nsText.substring(with: safeRange)
        if !state.expectedInsertedText.isEmpty && currentSegment != state.expectedInsertedText {
            print("⚠️ Streaming selection drift; replacing observed segment with latest partial")
        }

        let replaced = nsText.replacingCharacters(in: safeRange, with: insertionText)
        guard setElementValue(state.targetElement, replaced) else {
            state.useKeyboardFallback = true
            if performKeyboardStreamingUpdate(insertionText, state: &state) {
                streamingState = state
                return .updated(method: "keyboard-fallback", characterCount: insertionText.count)
            }

            return .failed(.init(category: .accessibility, details: "set value replacement failed"))
        }

        let updatedRange = NSRange(location: safeRange.location, length: (insertionText as NSString).length)
        state.insertionRange = updatedRange
        state.expectedInsertedText = insertionText
        streamingState = state
        _ = setSelectedRange(state.targetElement, location: updatedRange.location + updatedRange.length, length: 0)
        return .updated(method: "ax-value", characterCount: insertionText.utf16.count)
    }

    /// Finish streaming insertion and replace the active segment with final text.
    public func finishStreamingInsertion(with finalText: String) -> StreamingUpdateResult {
        let sanitizedFinalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedFinalText.isEmpty else {
            return .updated(method: "final-noop", characterCount: 0)
        }

        let outcome = updateStreamingInsertion(sanitizedFinalText)
        if case .updated = outcome {
            streamingState = nil
            streamingFallbackText = ""
        }
        return outcome
    }

    /// Cancel any active streaming insertion session.
    public func cancelStreamingInsertion() {
        streamingState = nil
        streamingFallbackText = ""
    }

    /// Apply a keyboard-based streaming update by diffing against last applied text.
    /// This is intentionally conservative and used as a fallback when the normal
    /// accessibility streaming session cannot be kept active.
    public func applyStreamingKeyboardFallback(_ text: String) -> StreamingUpdateResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            if streamingFallbackText.isEmpty {
                return .updated(method: "keyboard-fallback-noop", characterCount: 0)
            }
            return .updated(method: "keyboard-fallback-hold", characterCount: streamingFallbackText.utf16.count)
        }

        let previousUnits = Array(streamingFallbackText)
        let incomingUnits = Array(normalized)

        var commonPrefix = 0
        while commonPrefix < previousUnits.count &&
              commonPrefix < incomingUnits.count &&
              previousUnits[commonPrefix] == incomingUnits[commonPrefix] {
            commonPrefix += 1
        }

        if previousUnits.count > commonPrefix {
            if !sendBackspace(count: previousUnits.count - commonPrefix) {
                return .failed(.init(category: .accessibility, details: "keyboard fallback failed to delete drifted stream segment"))
            }
        }

        if incomingUnits.count > commonPrefix {
            let tailUnits = incomingUnits.dropFirst(commonPrefix)
            let tailText = String(tailUnits)
            if !sendTextViaKeyboard(tailText) {
                return .failed(.init(category: .accessibility, details: "keyboard fallback failed to type stream segment"))
            }
        }

        streamingFallbackText = normalized
        return .updated(method: "keyboard-fallback-delta", characterCount: normalized.utf16.count)
    }

    /// Reset fallback-only stream cache state.
    public func resetStreamingFallbackState() {
        streamingFallbackText = ""
    }

    private func normalizedRange(for element: AXUIElement, _ range: CFRange) -> NSRange {
        if let value = elementValue(for: element) {
            let nsText = value as NSString
            return normalizedRange(forLength: nsText.length, range: NSRange(location: range.location, length: range.length))
        }
        return NSRange(location: max(0, range.location), length: max(0, range.length))
    }

    private func normalizedRange(for element: AXUIElement, _ range: NSRange) -> NSRange {
        if let value = elementValue(for: element) {
            let nsText = value as NSString
            return normalizedRange(forLength: nsText.length, range: range)
        }
        return NSRange(location: max(0, range.location), length: max(0, range.length))
    }

    private func normalizedRange(forLength length: Int, range: NSRange) -> NSRange {
        guard length >= 0 else { return NSRange(location: NSNotFound, length: 0) }
        let start = max(0, min(range.location, length))
        let maxLen = max(0, length - start)
        let normalizedLength = max(0, min(range.length, maxLen))
        return NSRange(location: start, length: normalizedLength)
    }

    private func replaceSelectedRange(on element: AXUIElement, range: NSRange, with text: String) -> Bool {
        guard setSelectedRange(element, location: range.location, length: range.length) else {
            return false
        }

        return replaceInElementValue(on: element, range: range, with: text)
    }

    // MARK: - Pasteboard Management

    private func savePasteboard() {
        let pasteboard = NSPasteboard.general
        var contents: [NSPasteboard.PasteboardType: Data] = [:]

        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) {
                contents[type] = data
            }
        }

        savedPasteboardContents = contents
    }

    private func restorePasteboard() {
        guard let contents = savedPasteboardContents, !contents.isEmpty else {
            savedPasteboardContents = nil
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        for (type, data) in contents {
            pasteboard.setData(data, forType: type)
        }

        savedPasteboardContents = nil
    }

    // MARK: - Keystroke Simulation

    private func simulatePaste() async {
        // Create key down event for V with Command modifier
        let keyCode = CGKeyCode(kVK_ANSI_V)

        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            print("❌ Failed to create keyboard events")
            return
        }

        // Add Command modifier
        keyDownEvent.flags = .maskCommand
        keyUpEvent.flags = .maskCommand

        // Post events
        keyDownEvent.post(tap: .cghidEventTap)

        // Small delay between down and up
        try? await Task.sleep(for: .milliseconds(10))

        keyUpEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Accessibility Insertion

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard let focusedElement = focusedElement(),
              let currentText = elementValue(for: focusedElement),
              let selectedRange = selectedTextRange(for: focusedElement) else {
            return false
        }

        let nsText = currentText as NSString
        let nsRange = NSRange(location: selectedRange.location, length: selectedRange.length)

        guard nsRange.location != NSNotFound,
              nsRange.location <= nsText.length,
              nsRange.location + nsRange.length <= nsText.length else {
            return false
        }

        let replaced = nsText.replacingCharacters(in: nsRange, with: text)
        let setValueStatus = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            replaced as CFTypeRef
        )
        guard setValueStatus == .success else {
            return false
        }

        var newRange = CFRange(location: nsRange.location + (text as NSString).length, length: 0)
        if let newRangeAX = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                newRangeAX
            )
        }

        return true
    }

    private func replaceInElementValue(on element: AXUIElement, range: NSRange, with text: String) -> Bool {
        guard let currentValue = elementValue(for: element) else { return false }

        let nsText = currentValue as NSString
        guard range.location != NSNotFound,
              range.location <= nsText.length,
              range.location + range.length <= nsText.length else {
            return false
        }

        let replaced = nsText.replacingCharacters(in: range, with: text)
        return setElementValue(element, replaced)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef,
        CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private func axElementsEqual(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func elementValue(for element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success else {
            return nil
        }

        if let value = valueRef as? String {
            return value
        }

        if let attributed = valueRef as? NSAttributedString {
            return attributed.string
        }

        return nil
    }

    private func setElementValue(_ element: AXUIElement, _ value: String) -> Bool {
        return AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
        let selectedRangeRef,
        CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let selectedRangeAX = unsafeBitCast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(selectedRangeAX) == .cfRange else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeAX, .cfRange, &selectedRange) else {
            return nil
        }

        return selectedRange
    }

    private func setSelectedRange(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        var cfRange = CFRange(location: location, length: length)
        guard let selectedRange = AXValueCreate(.cfRange, &cfRange) else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            selectedRange
        ) == .success
    }

    private func performKeyboardStreamingUpdate(_ text: String, state: inout StreamingInsertionState) -> Bool {
        let previousText = state.expectedInsertedText
        if previousText == text {
            return true
        }

        let previousUnits = Array(previousText)
        let incomingUnits = Array(text)
        let commonPrefix = longestCommonPrefix(previousUnits, incomingUnits)

        if commonPrefix > 0 {
            if previousUnits.count > commonPrefix {
                let trimCount = previousUnits.count - commonPrefix
                if trimCount > 0, !sendBackspace(count: trimCount) {
                    print("⚠️ Streaming keyboard fallback backspace failed")
                    return false
                }
            }

            if incomingUnits.count > commonPrefix {
                let tailUnits = incomingUnits[commonPrefix...]
                let tail = String(tailUnits)
                if !sendTextViaKeyboard(tail) {
                    print("⚠️ Streaming keyboard fallback send-text failed")
                    return false
                }
            }
        } else {
            if !previousText.isEmpty, !sendBackspace(count: previousUnits.count) {
                print("⚠️ Streaming keyboard fallback full replace backspace failed")
                return false
            }
            if !text.isEmpty, !sendTextViaKeyboard(text) {
                print("⚠️ Streaming keyboard fallback send-text failed")
                return false
            }
        }

        state.expectedInsertedText = text
        state.useKeyboardFallback = true
        return true
    }

    private func sendTextViaKeyboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        for character in text {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let downEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: true),
                  let upEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: false) else {
                return false
            }

            var unicode = Array(String(character).utf16)
            downEvent.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
            upEvent.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)

            downEvent.post(tap: .cghidEventTap)
            upEvent.post(tap: .cghidEventTap)

            if text.utf16.count > 1 {
                usleep(800)
            }
        }

        return true
    }

    private func sendBackspace(count: Int) -> Bool {
        guard count > 0,
              let source = CGEventSource(stateID: .hidSystemState),
              let downEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else {
            return false
        }

        for _ in 0..<count {
            downEvent.post(tap: CGEventTapLocation.cghidEventTap)
            upEvent.post(tap: CGEventTapLocation.cghidEventTap)
        }
        return true
    }

    private func longestCommonPrefix(_ left: [Character], _ right: [Character]) -> Int {
        var length = 0
        let limit = min(left.count, right.count)

        while length < limit && left[length] == right[length] {
            length += 1
        }

        return length
    }
}

// MARK: - Alternative: Character-by-Character Input

extension TextInserter {
    /// Insert text character by character (fallback method)
    /// Use this if paste doesn't work in certain applications
    public func insertCharacterByCharacter(_ text: String) async {
        for character in text {
            await simulateKeyPress(for: character)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func simulateKeyPress(for character: Character) async {
        let string = String(character)

        // Use CGEvent with Unicode input
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        var unicodeChars = Array(string.utf16)
        event?.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: &unicodeChars)
        event?.post(tap: .cghidEventTap)

        // Key up
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        upEvent?.post(tap: .cghidEventTap)
    }
}

// MARK: - Key Codes

private let kVK_ANSI_V: Int = 9
