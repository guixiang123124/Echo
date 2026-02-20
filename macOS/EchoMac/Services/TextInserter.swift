import Foundation
import AppKit
import Carbon.HIToolbox

/// Inserts text into the currently focused application
/// Uses pasteboard + simulated Cmd+V for maximum compatibility
@MainActor
public final class TextInserter {
    // MARK: - Properties

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
    /// Returns true when the focused element supports Accessibility replacement.
    public func startStreamingInsertionSession() -> Bool {
        guard let focusedElement = focusedElement(),
              let currentValue = elementValue(for: focusedElement),
              let selectedRange = selectedTextRange(for: focusedElement) else {
            return false
        }

        let nsText = currentValue as NSString
        let normalizedStart = max(0, min(Int(selectedRange.location), nsText.length))
        let normalizedLength = max(0, min(Int(selectedRange.length), nsText.length - normalizedStart))
        let normalizedRange = NSRange(location: normalizedStart, length: normalizedLength)

        let initialInsertedText: String
        if normalizedRange.length > 0 {
            initialInsertedText = nsText.substring(with: normalizedRange)
        } else {
            initialInsertedText = ""
        }

        streamingState = StreamingInsertionState(
            targetElement: focusedElement,
            insertionRange: normalizedRange,
            expectedInsertedText: initialInsertedText
        )
        return true
    }

    /// Replace the currently active streaming insertion segment with the latest partial text.
    /// Returns false when the Accessibility session can no longer be maintained.
    public func updateStreamingInsertion(_ text: String) -> Bool {
        guard var state = streamingState else { return false }
        guard isStreamingTargetStillValid(for: state) else {
            streamingState = nil
            return false
        }

        guard let currentValue = elementValue(for: state.targetElement) else {
            streamingState = nil
            return false
        }

        let nsText = currentValue as NSString
        let safeRange = state.insertionRange
        guard safeRange.location != NSNotFound,
              safeRange.location >= 0,
              safeRange.length >= 0,
              safeRange.location <= nsText.length,
              safeRange.location + safeRange.length <= nsText.length else {
            streamingState = nil
            return false
        }

        let currentSegment = nsText.substring(with: safeRange)
        guard currentSegment == state.expectedInsertedText else {
            // External edits touched our insertion segment; abort streaming mode to avoid corrupting text.
            streamingState = nil
            return false
        }

        let replaced = nsText.replacingCharacters(in: safeRange, with: text)
        guard setElementValue(state.targetElement, replaced) else {
            streamingState = nil
            return false
        }

        let updatedRange = NSRange(location: safeRange.location, length: (text as NSString).length)
        state.insertionRange = updatedRange
        state.expectedInsertedText = text
        streamingState = state

        _ = setSelectedRange(state.targetElement, location: updatedRange.location + updatedRange.length, length: 0)
        return true
    }

    /// Finish streaming insertion and replace the active segment with final text.
    /// Returns false if streaming session was not active.
    public func finishStreamingInsertion(with finalText: String) -> Bool {
        guard updateStreamingInsertion(finalText) else { return false }
        streamingState = nil
        return true
    }

    /// Cancel any active streaming insertion session.
    public func cancelStreamingInsertion() {
        streamingState = nil
    }

    private func isStreamingTargetStillValid(for state: StreamingInsertionState) -> Bool {
        guard let focusedElement = focusedElement(),
              axElementsEqual(focusedElement, state.targetElement) else {
            return false
        }

        guard let selectedRange = selectedTextRange(for: state.targetElement) else {
            return false
        }

        let caretLocation = state.insertionRange.location + state.insertionRange.length
        let isCaretAtExpectedEnd = selectedRange.location == caretLocation && selectedRange.length == 0
        let isSegmentSelected = selectedRange.location == state.insertionRange.location
            && selectedRange.length == state.insertionRange.length
        guard isCaretAtExpectedEnd || isSegmentSelected else {
            return false
        }

        guard let currentValue = elementValue(for: state.targetElement) else {
            return false
        }

        let nsText = currentValue as NSString
        guard state.insertionRange.location >= 0,
              state.insertionRange.location + state.insertionRange.length <= nsText.length else {
            return false
        }

        let actualInsertedText = nsText.substring(with: state.insertionRange)
        return actualInsertedText == state.expectedInsertedText
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
