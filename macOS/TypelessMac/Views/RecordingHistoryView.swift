import SwiftUI
import AVFoundation
import AppKit
import Combine

@MainActor
final class RecordingHistoryViewModel: ObservableObject {
    @Published var entries: [RecordingStore.RecordingEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?

    func load() {
        Task { await reload() }
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        let items = await RecordingStore.shared.fetchRecent(limit: 200)
        entries = items
        isLoading = false
    }

    func play(entry: RecordingStore.RecordingEntry) {
        guard let url = entry.audioURL else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            errorMessage = "Failed to play audio: \(error.localizedDescription)"
        }
    }

    func openInFinder(entry: RecordingStore.RecordingEntry) {
        guard let url = entry.audioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct RecordingHistoryView: View {
    @StateObject private var model = RecordingHistoryViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.isLoading {
                ProgressView()
                    .padding()
            } else if model.entries.isEmpty {
                emptyState
            } else {
                list
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .typelessRecordingSaved)) { _ in
            model.load()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording History")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Audio is stored locally. Old recordings are auto-pruned after 7 days.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Refresh") {
                model.load()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No recordings yet.")
                .font(.headline)
            Text("Record something and it will appear here.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List(model.entries) { entry in
            RecordingRow(entry: entry, onPlay: { model.play(entry: entry) }, onReveal: { model.openInFinder(entry: entry) })
        }
        .listStyle(.inset)
    }
}

struct RecordingRow: View {
    let entry: RecordingStore.RecordingEntry
    let onPlay: () -> Void
    let onReveal: () -> Void

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: entry.createdAt)
    }

    private var durationText: String {
        String(format: "%.2fs", entry.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(timestamp)
                    .font(.headline)

                Text(durationText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if entry.audioURL != nil {
                    Button {
                        onPlay()
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Play recording")

                    Button {
                        onReveal()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .padding(.leading, 4)
                }
            }

            if let transcript = entry.transcriptFinal, !transcript.isEmpty {
                Text(transcript)
                    .font(.body)
            } else if let transcript = entry.transcriptRaw, !transcript.isEmpty {
                Text(transcript)
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                Text("No transcription available.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Text(entry.asrProviderName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let error = entry.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }

                Spacer()

                Text(entry.status.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(entry.status == "success" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .cornerRadius(6)
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    RecordingHistoryView()
}
