import Foundation

/// Tracks recent input context for LLM correction accuracy
public struct ConversationContext: Sendable {
    /// Recent transcriptions (newest first), used for contextual correction
    public let recentTexts: [String]

    /// Maximum number of recent texts to keep
    public let maxHistory: Int

    /// Custom user dictionary terms for this session
    public let userTerms: [String]

    public init(
        recentTexts: [String] = [],
        maxHistory: Int = 10,
        userTerms: [String] = []
    ) {
        self.recentTexts = Array(recentTexts.prefix(maxHistory))
        self.maxHistory = maxHistory
        self.userTerms = userTerms
    }

    /// Add a new text to the context, returning updated context (immutable)
    public func adding(text: String) -> ConversationContext {
        let updated = [text] + recentTexts
        return ConversationContext(
            recentTexts: Array(updated.prefix(maxHistory)),
            maxHistory: maxHistory,
            userTerms: userTerms
        )
    }

    /// Add user terms, returning updated context (immutable)
    public func withUserTerms(_ terms: [String]) -> ConversationContext {
        ConversationContext(
            recentTexts: recentTexts,
            maxHistory: maxHistory,
            userTerms: terms
        )
    }

    /// Format context for LLM prompt
    public func formatForPrompt() -> String {
        compactForPrompt()
    }

    /// Build a compact, high-signal prompt context.
    /// - Parameters:
    ///   - focusText: Current utterance for relevance scoring.
    ///   - maxRecent: Max recent context lines.
    ///   - maxChars: Max total context characters.
    ///   - maxUserTerms: Max dictionary terms.
    /// - Returns: Compact prompt text containing only high-value context.
    public func compactForPrompt(
        focusText: String? = nil,
        maxRecent: Int = 3,
        maxChars: Int = 900,
        maxUserTerms: Int = 48
    ) -> String {
        var dedupedRecent: [(text: String, recencyIndex: Int)] = []
        var seenRecent = Set<String>()
        dedupedRecent.reserveCapacity(recentTexts.count)

        for (index, raw) in recentTexts.enumerated() {
            let cleaned = Self.normalizeLine(raw)
            guard cleaned.count >= 2 else { continue }
            let key = Self.normalizationKey(cleaned)
            guard !seenRecent.contains(key) else { continue }
            seenRecent.insert(key)
            dedupedRecent.append((cleaned, index))
        }

        var dedupedTerms: [String] = []
        var seenTerms = Set<String>()
        dedupedTerms.reserveCapacity(userTerms.count)
        for term in userTerms {
            let cleaned = Self.normalizeLine(term)
            guard !cleaned.isEmpty else { continue }
            let key = Self.normalizationKey(cleaned)
            guard !seenTerms.contains(key) else { continue }
            seenTerms.insert(key)
            dedupedTerms.append(cleaned)
            if dedupedTerms.count >= maxUserTerms {
                break
            }
        }

        let focusTokens = Self.tokenize(focusText ?? "")
        let scoredRecent = dedupedRecent
            .map { item in
                (
                    text: item.text,
                    recencyIndex: item.recencyIndex,
                    score: Self.relevanceScore(
                        line: item.text,
                        focusTokens: focusTokens,
                        userTerms: dedupedTerms,
                        recencyIndex: item.recencyIndex
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.recencyIndex < rhs.recencyIndex
                }
                return lhs.score > rhs.score
            }

        var selectedRecent = Array(scoredRecent.prefix(max(0, maxRecent)))
            .sorted { $0.recencyIndex > $1.recencyIndex } // older -> newer
            .map(\.text)
        var selectedTerms = dedupedTerms

        func render(_ recent: [String], _ terms: [String]) -> String {
            var parts: [String] = []
            if !recent.isEmpty {
                parts.append("Recent context:\n\(recent.joined(separator: "\n"))")
            }
            if !terms.isEmpty {
                parts.append("User dictionary terms: \(terms.joined(separator: ", "))")
            }
            return parts.joined(separator: "\n\n")
        }

        var output = render(selectedRecent, selectedTerms)
        while output.count > maxChars, selectedRecent.count > 1 {
            selectedRecent.removeFirst()
            output = render(selectedRecent, selectedTerms)
        }
        while output.count > maxChars, selectedTerms.count > 8 {
            selectedTerms.removeLast()
            output = render(selectedRecent, selectedTerms)
        }
        if output.count > maxChars {
            output = String(output.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    public static let empty = ConversationContext()
}

private extension ConversationContext {
    static func normalizeLine(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func normalizationKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    static func tokenize(_ text: String) -> Set<String> {
        let normalized = text.lowercased()
        let pattern = #"[a-z0-9]{2,}|[\p{Han}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        var tokens = Set<String>()
        regex.enumerateMatches(in: normalized, options: [], range: range) { match, _, _ in
            guard let match,
                  let r = Range(match.range, in: normalized) else { return }
            let token = String(normalized[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.count >= 2 {
                tokens.insert(token)
            }
        }
        return tokens
    }

    static func relevanceScore(
        line: String,
        focusTokens: Set<String>,
        userTerms: [String],
        recencyIndex: Int
    ) -> Int {
        var score = max(0, 80 - recencyIndex * 6)
        if !focusTokens.isEmpty {
            let lineTokens = tokenize(line)
            let overlap = focusTokens.intersection(lineTokens).count
            score += overlap * 15
        }
        if userTerms.contains(where: { term in
            guard !term.isEmpty else { return false }
            return line.localizedCaseInsensitiveContains(term)
        }) {
            score += 20
        }
        return score
    }
}
