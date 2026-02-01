import Foundation

/// Provides autocomplete suggestions for text input
public actor AutocompleteService {
    private var recentWords: [String] = []
    private let maxRecent: Int = 100

    public init() {}

    /// Get suggestions based on current input prefix
    public func suggestions(for prefix: String, language: KeyboardInputMode) -> [String] {
        guard !prefix.isEmpty else { return [] }

        let lowered = prefix.lowercased()

        switch language {
        case .english:
            return englishSuggestions(for: lowered)
        case .pinyin:
            return [] // Pinyin uses PinyinEngine instead
        case .numbers, .symbols:
            return []
        }
    }

    /// Record a word as recently used
    public func recordWord(_ word: String) {
        recentWords.removeAll { $0.lowercased() == word.lowercased() }
        recentWords.insert(word, at: 0)
        if recentWords.count > maxRecent {
            recentWords = Array(recentWords.prefix(maxRecent))
        }
    }

    // MARK: - Private

    private func englishSuggestions(for prefix: String) -> [String] {
        // First check recent words
        let recentMatches = recentWords
            .filter { $0.lowercased().hasPrefix(prefix) }
            .prefix(3)

        // Then check common words dictionary
        let dictMatches = CommonEnglishWords.words
            .filter { $0.hasPrefix(prefix) }
            .prefix(5)

        var results = Array(recentMatches)
        for word in dictMatches where !results.contains(where: { $0.lowercased() == word }) {
            results.append(word)
        }

        return Array(results.prefix(5))
    }
}

/// Common English words for basic autocomplete
enum CommonEnglishWords {
    static let words: [String] = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
        "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
        "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
        "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
        "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
        "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
        "even", "new", "want", "because", "any", "these", "give", "day", "most", "us",
        "great", "between", "need", "large", "under", "never", "each", "right", "last",
        "help", "through", "much", "before", "line", "too", "means", "old", "must",
        "big", "here", "end", "does", "another", "well", "while", "should", "home",
        "thank", "thanks", "please", "sorry", "hello", "goodbye", "morning", "evening",
        "today", "tomorrow", "yesterday", "always", "never", "sometimes", "maybe",
        "really", "very", "already", "still", "again", "together", "enough"
    ].sorted()
}
