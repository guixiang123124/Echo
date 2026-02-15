import SwiftUI
import EchoCore

struct EchoDictionaryView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case autoAdded
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .autoAdded: return "Auto-added"
            case .manual: return "Manually-added"
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var entries: [DictionaryTermEntry] = []
    @State private var showAddSheet = false
    @State private var newTerm = ""
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        EchoSectionHeading(
                            "Dictionary",
                            subtitle: "Teach Echo names, product terms, and phrases to improve dictation quality."
                        )

                        HStack(spacing: 8) {
                            ForEach(Filter.allCases) { f in
                                Button {
                                    filter = f
                                } label: {
                                    HStack(spacing: 6) {
                                        if f == .autoAdded {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 11, weight: .semibold))
                                        } else if f == .manual {
                                            Image(systemName: "leaf")
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                        Text(f.title)
                                    }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(filter == f ? .primary : EchoMobileTheme.mutedText)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(filter == f ? EchoMobileTheme.accentSoft : EchoMobileTheme.cardBackground)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(EchoMobileTheme.mutedText)
                            TextField("Search terms", text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                            if !query.isEmpty {
                                Button {
                                    query = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(EchoMobileTheme.cardSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(EchoMobileTheme.border, lineWidth: 1)
                        )

                        dictionaryCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(EchoMobileTheme.pageBackground)

                Button {
                    newTerm = ""
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.black))
                        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 10)
                }
                .padding(.trailing, 18)
                .padding(.bottom, 18)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await EchoDictionaryStore.shared.clearAutoAdded() }
                        } label: {
                            Label("Clear Auto-added", systemImage: "sparkles")
                        }

                        Button(role: .destructive) {
                            Task { await EchoDictionaryStore.shared.clear() }
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await refresh() }
        .onChange(of: filter) { _, _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .echoDictionaryChanged)) { _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                Form {
                    Section("New word") {
                        TextField("Enter a term", text: $newTerm)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        Button("Add") {
                            Task {
                                await EchoDictionaryStore.shared.add(term: newTerm, source: .manual)
                                showAddSheet = false
                            }
                        }
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("Add Word")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showAddSheet = false }
                    }
                }
            }
        }
    }

    private var dictionaryCard: some View {
        VStack(spacing: 0) {
            if filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Text("No words yet")
                        .font(.headline)
                    Text("Echo remembers unique names and terms to improve recognition and editing.")
                        .font(.footnote)
                        .foregroundStyle(EchoMobileTheme.mutedText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 14)
            } else {
                ForEach(filteredEntries.indices, id: \.self) { idx in
                    let item = filteredEntries[idx]
                    HStack(spacing: 12) {
                        Image(systemName: item.source == .manual ? "leaf" : "sparkles")
                            .foregroundStyle(item.source == .manual ? Color(.systemTeal) : Color(.systemMint))
                            .frame(width: 18)
                        Text(item.term)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await EchoDictionaryStore.shared.remove(term: item.term) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }

                    if idx < filteredEntries.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(EchoMobileTheme.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(EchoMobileTheme.border, lineWidth: 1)
        )
    }

    private func refresh() async {
        let filterSource: DictionaryTermSource?
        switch filter {
        case .all: filterSource = nil
        case .autoAdded: filterSource = .autoAdded
        case .manual: filterSource = .manual
        }
        entries = await EchoDictionaryStore.shared.all(filter: filterSource)
    }

    private var filteredEntries: [DictionaryTermEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return entries }
        return entries.filter { $0.term.localizedCaseInsensitiveContains(term) }
    }
}
