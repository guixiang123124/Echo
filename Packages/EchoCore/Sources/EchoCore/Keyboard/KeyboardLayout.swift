import Foundation

/// Generates keyboard key layouts for different input modes
public enum KeyboardLayout {
    /// Generate QWERTY layout rows for English input
    public static func qwertyRows(shift: ShiftState) -> [[KeyboardKey]] {
        let letters: [[String]] = [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m"]
        ]

        let isUppercase = shift != .lowercased

        let row1 = letters[0].map { char in
            let display = isUppercase ? char.uppercased() : char
            return KeyboardKey(
                action: .character(display),
                label: display
            )
        }

        let row2 = letters[1].map { char in
            let display = isUppercase ? char.uppercased() : char
            return KeyboardKey(
                action: .character(display),
                label: display
            )
        }

        var row3: [KeyboardKey] = [
            KeyboardKey(action: .shift, label: "shift", width: .wide)
        ]
        row3 += letters[2].map { char in
            let display = isUppercase ? char.uppercased() : char
            return KeyboardKey(
                action: .character(display),
                label: display
            )
        }
        row3.append(KeyboardKey(action: .backspace, label: "delete", width: .wide))

        let row4: [KeyboardKey] = [
            KeyboardKey(action: .switchToNumbers, label: "123", width: .wide),
            KeyboardKey(action: .switchLanguage, label: "EN/中", width: .wide),
            KeyboardKey(action: .space, label: "space", width: .spacebar),
            KeyboardKey(action: .enter, label: "return", width: .wide)
        ]

        return [row1, row2, row3, row4]
    }

    /// Generate Pinyin layout rows for Chinese input
    public static func pinyinRows(shift: ShiftState) -> [[KeyboardKey]] {
        // Pinyin uses the same QWERTY layout for letter input
        // but the bottom row differs to support Chinese-specific actions
        let letters: [[String]] = [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m"]
        ]

        let row1 = letters[0].map { char in
            KeyboardKey(action: .character(char), label: char)
        }

        let row2 = letters[1].map { char in
            KeyboardKey(action: .character(char), label: char)
        }

        var row3: [KeyboardKey] = [
            KeyboardKey(action: .shift, label: "shift", width: .wide)
        ]
        row3 += letters[2].map { char in
            KeyboardKey(action: .character(char), label: char)
        }
        row3.append(KeyboardKey(action: .backspace, label: "delete", width: .wide))

        let row4: [KeyboardKey] = [
            KeyboardKey(action: .switchToNumbers, label: "123", width: .wide),
            KeyboardKey(action: .switchLanguage, label: "中/EN", width: .wide),
            KeyboardKey(action: .space, label: "空格", width: .spacebar),
            KeyboardKey(action: .enter, label: "确定", width: .wide)
        ]

        return [row1, row2, row3, row4]
    }

    /// Generate number and symbol rows
    public static func numberRows() -> [[KeyboardKey]] {
        let row1 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].map { char in
            KeyboardKey(action: .character(char), label: char)
        }

        let row2 = ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { char in
            KeyboardKey(action: .character(char), label: char)
        }

        var row3: [KeyboardKey] = [
            KeyboardKey(action: .switchToSymbols, label: "#+=", width: .wide)
        ]
        row3 += [".", ",", "?", "!", "'"].map { char in
            KeyboardKey(action: .character(char), label: char)
        }
        row3.append(KeyboardKey(action: .backspace, label: "delete", width: .wide))

        let row4: [KeyboardKey] = [
            KeyboardKey(action: .switchToLetters, label: "ABC", width: .wide),
            KeyboardKey(action: .switchLanguage, label: "EN/中", width: .wide),
            KeyboardKey(action: .space, label: "space", width: .spacebar),
            KeyboardKey(action: .enter, label: "return", width: .wide)
        ]

        return [row1, row2, row3, row4]
    }

    /// Generate symbol rows
    public static func symbolRows() -> [[KeyboardKey]] {
        let row1 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { char in
            KeyboardKey(action: .character(char), label: char)
        }

        let row2 = ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "·"].map { char in
            KeyboardKey(action: .character(char), label: char)
        }

        var row3: [KeyboardKey] = [
            KeyboardKey(action: .switchToNumbers, label: "123", width: .wide)
        ]
        row3 += [".", ",", "?", "!", "'"].map { char in
            KeyboardKey(action: .character(char), label: char)
        }
        row3.append(KeyboardKey(action: .backspace, label: "delete", width: .wide))

        let row4: [KeyboardKey] = [
            KeyboardKey(action: .switchToLetters, label: "ABC", width: .wide),
            KeyboardKey(action: .switchLanguage, label: "EN/中", width: .wide),
            KeyboardKey(action: .space, label: "space", width: .spacebar),
            KeyboardKey(action: .enter, label: "return", width: .wide)
        ]

        return [row1, row2, row3, row4]
    }
}
