import Foundation

public enum DictionaryAutoAdder {
    /// Extract candidate terms that appear in `corrected` but not in `original`.
    ///
    /// This is intentionally conservative (quality > recall) to reduce dictionary pollution.
    public static func candidates(original: String, corrected: String) -> [String] {
        guard !original.isEmpty, !corrected.isEmpty else { return [] }
        guard original != corrected else { return [] }

        let originalTokens = Set(tokenize(original))
        let correctedTokens = Set(tokenize(corrected))

        let newTokens = correctedTokens.subtracting(originalTokens)
        let filtered = newTokens.filter { looksLikeUsefulTerm($0) }

        // Deterministic ordering.
        return filtered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func tokenize(_ text: String) -> [String] {
        // Split on whitespace and most punctuation, keep CJK runs.
        // For a v1 PoC: simple, fast, and predictable.
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)

        // Preserve CJK by first normalizing separators to spaces.
        let parts = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Further split mixed tokens like "EchoApp," already handled; keep as-is.
        return parts
    }

    private static func looksLikeUsefulTerm(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // Avoid very short noise.
        if t.count == 1 { return false }

        // Avoid pure numbers.
        if t.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return false
        }

        // Latin-ish: require at least one letter/digit and length.
        if t.unicodeScalars.allSatisfy({ $0.isASCII }) {
            // Filter common filler tokens.
            let lower = t.lowercased()
            let stop: Set<String> = ["a","an","the","and","or","to","of","in","on","for","with","is","are","i","you","we"]
            if stop.contains(lower) { return false }
            return t.count >= 3
        }

        // CJK: keep 2-8 chars.
        if containsCJK(t) {
            return (2...8).contains(t.count)
        }

        // Fallback: require >= 3 chars.
        return t.count >= 3
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            // Basic CJK Unified Ideographs block.
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }
}
