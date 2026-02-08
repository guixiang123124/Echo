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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: $filter) {
                            ForEach(Filter.allCases) { f in
                                Text(f.title).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)

                        dictionaryCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Button {
                    newTerm = ""
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.black))
                        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 10)
                }
                .padding(.trailing, 18)
                .padding(.bottom, 18)
            }
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.large)
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
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Text("No words yet")
                        .font(.headline)
                    Text("Echo remembers unique names and terms to improve recognition and editing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 14)
            } else {
                ForEach(entries.indices, id: \.self) { idx in
                    let item = entries[idx]
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
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

                    if idx < entries.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
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
}

