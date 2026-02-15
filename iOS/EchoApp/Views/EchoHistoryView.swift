import SwiftUI
import EchoCore

struct EchoHistoryView: View {
    @EnvironmentObject private var authSession: EchoAuthSession

    @State private var entries: [RecordingStore.RecordingEntry] = []
    @State private var keepHistoryDays: Int = KeepHistoryPolicy.read()
    @State private var showKeepHistoryDialog = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EchoSectionHeading("History")
                    headerCard
                    historySections
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
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
                            .frame(width: 32, height: 32)
                    }
                }
            }
            .background(EchoMobileTheme.pageBackground)
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
        EchoCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showKeepHistoryDialog = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "archivebox")
                            .foregroundStyle(EchoMobileTheme.mutedText)
                            .frame(width: 22)
                        Text("Keep history")
                            .foregroundStyle(.primary)
                            .font(.system(size: 18, weight: .semibold))
                        Spacer()
                        Text(KeepHistoryPolicy.describe(days: keepHistoryDays))
                            .foregroundStyle(EchoMobileTheme.mutedText)
                            .font(.system(size: 18, weight: .regular))
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.vertical, 10)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock")
                        .foregroundStyle(EchoMobileTheme.mutedText)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your data stays private")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Your voice dictations are stored on device. If you enable cloud sync, we also upload dictation metadata to your account so it can sync across devices.")
                            .font(.system(size: 14))
                            .foregroundStyle(EchoMobileTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var historySections: some View {
        let grouped = groupByDay(entries)
        return VStack(alignment: .leading, spacing: 18) {
            if grouped.isEmpty {
                EchoCard {
                    Text("No recordings yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(EchoMobileTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
            }
            ForEach(grouped, id: \.day) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.dayTitle)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
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
                            .fill(EchoMobileTheme.cardSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(EchoMobileTheme.border, lineWidth: 1)
                    )
                }
            }
        }
    }

    private func historyRow(_ entry: RecordingStore.RecordingEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(EchoMobileTheme.mutedText)
            Text(entry.transcriptFinal ?? entry.transcriptRaw ?? entry.error ?? "(No text)")
                .font(.system(size: 18))
                .foregroundStyle(.primary)
                .lineLimit(4)

            Text(autoEditSummary(for: entry))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

private func autoEditSummary(for entry: RecordingStore.RecordingEntry) -> String {
    let providerName: String
    if let id = entry.correctionProviderId {
        switch id {
        case "openai_gpt": providerName = "OpenAI GPT-4o"
        case "claude": providerName = "Claude"
        case "doubao": providerName = "Doubao"
        case "qwen": providerName = "Qwen"
        default: providerName = id
        }
    } else {
        providerName = "Off"
    }

    let modified: String
    if let raw = entry.transcriptRaw,
       let final = entry.transcriptFinal,
       !raw.isEmpty,
       !final.isEmpty,
       raw != final {
        modified = "edited"
    } else if entry.correctionProviderId != nil {
        modified = "no change"
    } else {
        modified = ""
    }

    return modified.isEmpty ? "Auto Edit: \(providerName)" : "Auto Edit: \(providerName) (\(modified))"
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
