import Foundation

public enum DictionaryTermSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case autoAdded
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoAdded: return "Auto-added"
        case .manual: return "Manually-added"
        }
    }
}

public struct DictionaryTermEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { term.lowercased() }
    public let term: String
    public let source: DictionaryTermSource
    public let createdAt: Date

    public init(term: String, source: DictionaryTermSource, createdAt: Date = Date()) {
        self.term = term
        self.source = source
        self.createdAt = createdAt
    }
}

/// Simple on-device dictionary for custom terms.
/// Persisted via App Group UserDefaults so the main app and keyboard can share it.
public actor EchoDictionaryStore {
    public static let shared = EchoDictionaryStore()

    /// Safety valve: keep auto-added terms capped to avoid pollution.
    public static let defaultMaxAutoAddedTerms = 200

    private let defaults: UserDefaults
    private let storageKey = "echo.dictionary.entries.v1"
    private var entries: [DictionaryTermEntry] = []

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppSettings.appGroupIdentifier)
            ?? .standard
        self.entries = Self.decodeEntries(
            from: self.defaults,
            storageKey: self.storageKey
        )
    }

    public func load() {
        entries = Self.decodeEntries(from: defaults, storageKey: storageKey)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Ignore persistence errors; keep in-memory state.
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .echoDictionaryChanged, object: nil)
        }
    }

    public func all(filter: DictionaryTermSource? = nil) -> [DictionaryTermEntry] {
        let filtered = filter == nil ? entries : entries.filter { $0.source == filter }
        return filtered
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }

    public func contains(_ term: String) -> Bool {
        let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.contains { $0.term.lowercased() == key }
    }

    public func add(term: String, source: DictionaryTermSource) {
        add(terms: [term], source: source)
    }

    public func add(terms: [String], source: DictionaryTermSource) {
        let cleanedTerms: [String] = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanedTerms.isEmpty else { return }

        var changed = false

        for cleaned in cleanedTerms {
            let key = cleaned.lowercased()
            if let idx = entries.firstIndex(where: { $0.term.lowercased() == key }) {
                // Upgrade source if needed (manual wins).
                if entries[idx].source != .manual, source == .manual {
                    entries[idx] = DictionaryTermEntry(term: cleaned, source: .manual, createdAt: entries[idx].createdAt)
                    changed = true
                }
                continue
            }

            entries.append(DictionaryTermEntry(term: cleaned, source: source))
            changed = true
        }

        if source == .autoAdded {
            changed = enforceAutoAddedLimit(maxCount: Self.defaultMaxAutoAddedTerms) || changed
        }

        if changed {
            persist()
        }
    }

    public func remove(term: String) {
        let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let oldCount = entries.count
        entries.removeAll { $0.term.lowercased() == key }
        if entries.count != oldCount {
            persist()
        }
    }

    public func clearAutoAdded() {
        let oldCount = entries.count
        entries.removeAll { $0.source == .autoAdded }
        if entries.count != oldCount {
            persist()
        }
    }

    public func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
        Task { @MainActor in
            NotificationCenter.default.post(name: .echoDictionaryChanged, object: nil)
        }
    }

    @discardableResult
    private func enforceAutoAddedLimit(maxCount: Int) -> Bool {
        guard maxCount >= 0 else { return false }

        let autoAdded = entries.filter { $0.source == .autoAdded }
        guard autoAdded.count > maxCount else { return false }

        // Remove oldest auto-added entries first.
        let toRemoveCount = autoAdded.count - maxCount
        let oldest = autoAdded
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(toRemoveCount)

        let oldestIds = Set(oldest.map { $0.id })
        let oldCount = entries.count
        entries.removeAll { $0.source == .autoAdded && oldestIds.contains($0.id) }
        return entries.count != oldCount
    }

    private static func decodeEntries(from defaults: UserDefaults, storageKey: String) -> [DictionaryTermEntry] {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([DictionaryTermEntry].self, from: data)
        } catch {
            return []
        }
    }
}
