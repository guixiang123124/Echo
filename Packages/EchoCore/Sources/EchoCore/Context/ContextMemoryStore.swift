import Foundation

/// Persistent store for conversation context across app sessions
public actor ContextMemoryStore {
    private var context: ConversationContext
    private let storageKey: String
    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "echo.context_memory"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.context = .empty
    }

    /// Load context from persistent storage
    public func load() {
        let texts = defaults.stringArray(forKey: storageKey) ?? []
        let terms = defaults.stringArray(forKey: "\(storageKey).terms") ?? []
        context = ConversationContext(recentTexts: texts, userTerms: terms)
    }

    /// Save current context to persistent storage
    public func save() {
        defaults.set(context.recentTexts, forKey: storageKey)
        defaults.set(context.userTerms, forKey: "\(storageKey).terms")
    }

    /// Get the current context
    public func currentContext() -> ConversationContext {
        context
    }

    /// Add a transcription to context and persist
    public func addTranscription(_ text: String) {
        context = context.adding(text: text)
        save()
    }

    /// Update user terms and persist
    public func updateUserTerms(_ terms: [String]) {
        context = context.withUserTerms(terms)
        save()
    }

    /// Clear all stored context
    public func clear() {
        context = .empty
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: "\(storageKey).terms")
    }
}
