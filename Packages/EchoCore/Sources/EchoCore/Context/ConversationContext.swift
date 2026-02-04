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
        var parts: [String] = []

        if !recentTexts.isEmpty {
            let contextLines = recentTexts.reversed().joined(separator: "\n")
            parts.append("Recent context:\n\(contextLines)")
        }

        if !userTerms.isEmpty {
            let terms = userTerms.joined(separator: ", ")
            parts.append("User dictionary terms: \(terms)")
        }

        return parts.joined(separator: "\n\n")
    }

    public static let empty = ConversationContext()
}
