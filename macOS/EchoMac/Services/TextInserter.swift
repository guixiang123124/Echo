import Foundation
import AppKit
import Carbon.HIToolbox

/// Inserts text into the currently focused application
/// Uses pasteboard + simulated Cmd+V for maximum compatibility
@MainActor
public final class TextInserter {
    // MARK: - Properties

    public enum StreamingAttachResult {
        case attached
        case failed(String)
    }

    public enum StreamingUpdateResult {
        case updated(method: String, characterCount: Int)
        case failed(String)
    }

    private struct StreamingInsertionState {
        let targetElement: AXUIElement
        var insertionRange: NSRange
        var expectedInsertedText: String
    }

    private var savedPasteboardContents: [NSPasteboard.PasteboardType: Data]?
    private var streamingState: StreamingInsertionState?

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
            return .failed("no focused element")
        }

        guard let selectedRange = selectedTextRange(for: focusedElement) else {
            return .failed("focused element has no selected range")
        }

        let normalizedRange = normalizedRange(for: focusedElement, selectedRange)
        streamingState = StreamingInsertionState(
            targetElement: focusedElement,
            insertionRange: normalizedRange,
            expectedInsertedText: ""
        )
        return .attached
    }

    /// Replace the currently active streaming insertion segment with the latest partial text.
    public func updateStreamingInsertion(_ text: String) -> StreamingUpdateResult {
        guard var state = streamingState else { return .failed("no active streaming session") }

        guard let focused = focusedElement(), axElementsEqual(focused, state.targetElement) else {
            streamingState = nil
            return .failed("focus moved to different element")
        }

        let replacementRange = normalizedRange(for: state.targetElement, state.insertionRange)
        state.insertionRange = replacementRange

        if replaceSelectedRange(on: state.targetElement, range: replacementRange, with: text) {
            let updatedRange = NSRange(location: replacementRange.location, length: (text as NSString).length)
            state.insertionRange = updatedRange
            state.expectedInsertedText = text
            streamingState = state
            _ = setSelectedRange(state.targetElement, location: updatedRange.location + updatedRange.length, length: 0)
            return .updated(method: "selected-text", characterCount: text.count)
        }

        guard let currentValue = elementValue(for: state.targetElement) else {
            streamingState = nil
            return .failed("unable to read element value for fallback replacement")
        }

        let nsText = currentValue as NSString
        let safeRange = normalizedRange(forLength: nsText.length, range: replacementRange)
        guard safeRange.location != NSNotFound else {
            streamingState = nil
            return .failed("replacement range invalid")
        }

        let currentSegment = nsText.substring(with: safeRange)
        if !state.expectedInsertedText.isEmpty && currentSegment != state.expectedInsertedText {
            streamingState = nil
            return .failed("insertion segment diverged from expected text")
        }

        let replaced = nsText.replacingCharacters(in: safeRange, with: text)
        guard setElementValue(state.targetElement, replaced) else {
            streamingState = nil
            return .failed("set value replacement failed")
        }

        let updatedRange = NSRange(location: safeRange.location, length: (text as NSString).length)
        state.insertionRange = updatedRange
        state.expectedInsertedText = text
        streamingState = state
        _ = setSelectedRange(state.targetElement, location: updatedRange.location + updatedRange.length, length: 0)
        return .updated(method: "ax-value", characterCount: text.count)
    }

    /// Finish streaming insertion and replace the active segment with final text.
    public func finishStreamingInsertion(with finalText: String) -> StreamingUpdateResult {
        let outcome = updateStreamingInsertion(finalText)
        if case .updated = outcome {
            streamingState = nil
        }
        return outcome
    }

    /// Cancel any active streaming insertion session.
    public func cancelStreamingInsertion() {
        streamingState = nil
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

        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return status == .success
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

        return valueRef as? String
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
