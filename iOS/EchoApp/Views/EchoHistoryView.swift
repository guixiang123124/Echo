import SwiftUI
import EchoCore

struct EchoHistoryView: View {
    @EnvironmentObject private var authSession: EchoAuthSession

    @State private var entries: [RecordingStore.RecordingEntry] = []
    @State private var keepHistoryDays: Int = KeepHistoryPolicy.read()
    @State private var showKeepHistoryDialog = false
    @State private var showMenu = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    historySections
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            Task {
                                await RecordingStore.shared.deleteAll(userId: authSession.userId)
                                await refresh()
                            }
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .echoRecordingSaved)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog("Keep history", isPresented: $showKeepHistoryDialog, titleVisibility: .visible) {
            Button("Forever") { setKeepHistoryDays(KeepHistoryPolicy.forever) }
            Button("30 days") { setKeepHistoryDays(30) }
            Button("7 days") { setKeepHistoryDays(7) }
            Button("1 day") { setKeepHistoryDays(1) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How long do you want to keep your dictation history on this device?")
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showKeepHistoryDialog = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text("Keep history")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(KeepHistoryPolicy.describe(days: keepHistoryDays))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your data stays private")
                        .font(.body.weight(.semibold))
                    Text("Your voice dictations are stored on device. If you enable cloud sync, we also upload dictation metadata to your account so it can sync across devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var historySections: some View {
        let grouped = groupByDay(entries)
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(grouped, id: \.day) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.dayTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    VStack(spacing: 0) {
                        ForEach(section.items.indices, id: \.self) { idx in
                            let item = section.items[idx]
                            historyRow(item)
                            if idx < section.items.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                }
            }
        }
    }

    private func historyRow(_ entry: RecordingStore.RecordingEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(entry.transcriptFinal ?? entry.transcriptRaw ?? entry.error ?? "(No text)")
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh() async {
        let userId = authSession.userId
        entries = await RecordingStore.shared.fetchRecent(limit: 300, userId: userId)
    }

    private func setKeepHistoryDays(_ days: Int) {
        keepHistoryDays = days
        KeepHistoryPolicy.write(days: days)
        Task {
            // Trigger a cleanup pass after the policy changes.
            _ = await RecordingStore.shared.storageInfo()
            await refresh()
        }
    }
}

private struct HistoryDaySection {
    let day: Date
    let items: [RecordingStore.RecordingEntry]

    var dayTitle: String {
        day.formatted(.dateTime.month(.wide).day().year())
    }
}

private func groupByDay(_ items: [RecordingStore.RecordingEntry]) -> [HistoryDaySection] {
    let cal = Calendar.current
    let groups = Dictionary(grouping: items) { item in
        cal.startOfDay(for: item.createdAt)
    }
    return groups
        .map { HistoryDaySection(day: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
        .sorted { $0.day > $1.day }
}

private enum KeepHistoryPolicy {
    static let key = "echo.history.retentionDays"
    static let forever = -1

    static func read() -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return 7 }
        return defaults.integer(forKey: key)
    }

    static func write(days: Int) {
        UserDefaults.standard.set(days, forKey: key)
    }

    static func describe(days: Int) -> String {
        if days == forever { return "Forever" }
        if days <= 0 { return "Disabled" }
        if days == 1 { return "1 day" }
        return "\(days) days"
    }
}

