import Foundation

/// Manages user-defined custom terms for better ASR correction
public actor UserDictionary {
    private var terms: Set<String>
    private let storageKey: String

    public init(storageKey: String = "echo.user_dictionary") {
        self.terms = []
        self.storageKey = storageKey
    }

    /// Load terms from UserDefaults
    public func load(from defaults: UserDefaults) {
        let saved = defaults.stringArray(forKey: storageKey) ?? []
        terms = Set(saved)
    }

    /// Save terms to UserDefaults
    public func save(to defaults: UserDefaults) {
        defaults.set(Array(terms).sorted(), forKey: storageKey)
    }

    /// Add a custom term
    public func addTerm(_ term: String) {
        terms.insert(term)
    }

    /// Remove a custom term
    public func removeTerm(_ term: String) {
        terms.remove(term)
    }

    /// Check if a term exists
    public func containsTerm(_ term: String) -> Bool {
        terms.contains(term)
    }

    /// Get all terms sorted alphabetically
    public func allTerms() -> [String] {
        Array(terms).sorted()
    }

    /// Get terms count
    public var count: Int {
        terms.count
    }
}
