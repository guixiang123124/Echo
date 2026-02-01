import Testing
@testable import TypelessCore

@Suite("KeyboardKey Tests")
struct KeyboardKeyTests {

    @Test("Creates character key")
    func characterKey() {
        let key = KeyboardKey(action: .character("a"), label: "a")

        #expect(key.label == "a")
        #expect(key.width == .regular)
    }

    @Test("Creates key with custom width")
    func customWidth() {
        let key = KeyboardKey(
            action: .space,
            label: "space",
            width: .spacebar
        )

        #expect(key.width == .spacebar)
        #expect(key.width.multiplier == 5.0)
    }
}

@Suite("KeyboardLayout Tests")
struct KeyboardLayoutTests {

    @Test("QWERTY layout has 4 rows")
    func qwertyRowCount() {
        let rows = KeyboardLayout.qwertyRows(shift: .lowercased)
        #expect(rows.count == 4)
    }

    @Test("QWERTY first row has 10 keys")
    func qwertyFirstRow() {
        let rows = KeyboardLayout.qwertyRows(shift: .lowercased)
        #expect(rows[0].count == 10)
    }

    @Test("QWERTY shift produces uppercase labels")
    func qwertyShift() {
        let rows = KeyboardLayout.qwertyRows(shift: .uppercased)
        let firstKey = rows[0][0]

        #expect(firstKey.label == "Q")
    }

    @Test("QWERTY lowercase produces lowercase labels")
    func qwertyLowercase() {
        let rows = KeyboardLayout.qwertyRows(shift: .lowercased)
        let firstKey = rows[0][0]

        #expect(firstKey.label == "q")
    }

    @Test("Pinyin layout has 4 rows")
    func pinyinRowCount() {
        let rows = KeyboardLayout.pinyinRows(shift: .lowercased)
        #expect(rows.count == 4)
    }

    @Test("Pinyin bottom row has Chinese labels")
    func pinyinBottomRow() {
        let rows = KeyboardLayout.pinyinRows(shift: .lowercased)
        let bottomRow = rows[3]
        let spaceKey = bottomRow.first { $0.action == .space }

        #expect(spaceKey?.label == "空格")
    }

    @Test("Number layout has 4 rows")
    func numberRowCount() {
        let rows = KeyboardLayout.numberRows()
        #expect(rows.count == 4)
    }

    @Test("Symbol layout has 4 rows")
    func symbolRowCount() {
        let rows = KeyboardLayout.symbolRows()
        #expect(rows.count == 4)
    }
}

@Suite("KeyboardActionHandler Tests")
struct KeyboardActionHandlerTests {
    let handler = KeyboardActionHandler()

    @Test("Character action inserts text")
    func characterAction() {
        let op = handler.handle(
            action: .character("a"),
            currentMode: .english,
            shiftState: .lowercased
        )

        #expect(op == .insertText("a"))
    }

    @Test("Backspace returns delete backward")
    func backspaceAction() {
        let op = handler.handle(
            action: .backspace,
            currentMode: .english,
            shiftState: .lowercased
        )

        #expect(op == .deleteBackward)
    }

    @Test("Space inserts space character")
    func spaceAction() {
        let op = handler.handle(
            action: .space,
            currentMode: .english,
            shiftState: .lowercased
        )

        #expect(op == .insertText(" "))
    }

    @Test("Shift toggles between lower and upper")
    func shiftToggle() {
        let toLower = handler.handle(
            action: .shift,
            currentMode: .english,
            shiftState: .uppercased
        )
        let toUpper = handler.handle(
            action: .shift,
            currentMode: .english,
            shiftState: .lowercased
        )

        #expect(toLower == .changeShift(.lowercased))
        #expect(toUpper == .changeShift(.uppercased))
    }

    @Test("Switch language toggles English and Pinyin")
    func switchLanguage() {
        let toPinyin = handler.handle(
            action: .switchLanguage,
            currentMode: .english,
            shiftState: .lowercased
        )
        let toEnglish = handler.handle(
            action: .switchLanguage,
            currentMode: .pinyin,
            shiftState: .lowercased
        )

        #expect(toPinyin == .changeMode(.pinyin))
        #expect(toEnglish == .changeMode(.english))
    }

    @Test("Voice action triggers voice input")
    func voiceAction() {
        let op = handler.handle(
            action: .voice,
            currentMode: .english,
            shiftState: .lowercased
        )

        #expect(op == .triggerVoiceInput)
    }
}
