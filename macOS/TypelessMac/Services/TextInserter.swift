import Foundation
import AppKit
import Carbon.HIToolbox

/// Inserts text into the currently focused application
/// Uses pasteboard + simulated Cmd+V for maximum compatibility
@MainActor
public final class TextInserter {
    // MARK: - Properties

    private var savedPasteboardContents: [NSPasteboard.PasteboardType: Data]?

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
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard focusedStatus == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }

        let focusedElement = unsafeBitCast(focusedRef, to: AXUIElement.self)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
        let currentText = valueRef as? String else {
            return false
        }

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
        let selectedRangeRef,
        CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return false
        }
        let selectedRangeAX = unsafeBitCast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(selectedRangeAX) == .cfRange else {
            return false
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeAX, .cfRange, &selectedRange) else {
            return false
        }

        let nsText = currentText as NSString
        let range = NSRange(location: selectedRange.location, length: selectedRange.length)
        guard range.location != NSNotFound,
              range.location <= nsText.length,
              range.location + range.length <= nsText.length else {
            return false
        }

        let replaced = nsText.replacingCharacters(in: range, with: text)
        let setValueStatus = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            replaced as CFTypeRef
        )
        guard setValueStatus == .success else {
            return false
        }

        var newRange = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let newRangeAX = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                newRangeAX
            )
        }

        return true
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
