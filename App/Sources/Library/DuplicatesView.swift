import AppKit
import MiniAmpKit
import SwiftUI

/// Likely duplicates for review: songs with the same title and artist and about the same
/// length. Each group's best copy (see `Duplicates.isBetter`) is marked Keep.
struct DuplicatesView: View {
    let app: AppState
    let library: Library

    @State private var groups: [DuplicateGroup]?
    @State private var trashing: Trashing?

    /// Files waiting on the Move to Trash confirmation.
    struct Trashing: Identifiable {
        let id = UUID()
        var tracks: [Track]
        var description: String
    }

    var body: some View {
        Group {
            if let groups, !groups.isEmpty {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                DuplicateRow(entry: entry, isKeeper: index == 0)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { app.play(group.entries.map(\.info), from: entry.info.id) }
                                    .contextMenu { menu(for: entry, in: group) }
                            }
                        } header: {
                            header(group)
                        }
                    }
                }
                .listStyle(.inset)
            } else if groups != nil {
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.circle",
                                       description: Text("No two songs share a title, an artist, and a length."))
            } else {
                Color.clear
            }
        }
        .navigationTitle("Duplicates")
        .navigationSubtitle(groups.map { $0.isEmpty ? "" : "\($0.count) group\($0.count == 1 ? "" : "s")" } ?? "")
        .task(id: library.revision) { await reload() }
        .confirmationDialog("Move \(trashing?.description ?? "") to the Trash?", isPresented: Binding(
            get: { trashing != nil }, set: { if !$0 { trashing = nil } }), presenting: trashing
        ) { target in
            Button("Move to Trash", role: .destructive) {
                app.perform { try await library.moveToTrash(target.tracks) }
            }
        } message: { _ in
            Text("The files go to the Trash, where Put Back can restore them, and leave the library.")
        }
    }

    private func header(_ group: DuplicateGroup) -> some View {
        HStack {
            Text("\(group.title) — \(group.artist)").lineLimit(1)
            Spacer()
            Button("Not Duplicates") {
                app.perform {
                    try await library.database.writer.write { try Duplicates.dismiss(group, $0) }
                    await reload()
                }
            }
            .help("Stop showing these together (until another copy turns up)")
            Button("Keep Best…") {
                let others = group.entries.dropFirst().map(\.info.track).filter { !$0.isEvicted }
                trashing = Trashing(tracks: others, description: others.count == 1 ? "the other copy" : "the other \(others.count) copies")
            }
            .help("Keep the copy marked Keep, and move the rest to the Trash")
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    @ViewBuilder
    private func menu(for entry: DuplicateGroup.Entry, in group: DuplicateGroup) -> some View {
        Button("Play") { app.play(group.entries.map(\.info), from: entry.info.id) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.info.track.url]) }
        Divider()
        Button("Move to Trash…", role: .destructive) {
            trashing = Trashing(tracks: [entry.info.track], description: "“\(entry.info.track.url.lastPathComponent)”")
        }
        .disabled(entry.info.track.isEvicted)
    }

    private func reload() async {
        do {
            groups = try await library.database.writer.read { try Duplicates.find($0) }
        } catch {
            app.error = "\(error)"
        }
    }
}

private struct DuplicateRow: View {
    let entry: DuplicateGroup.Entry
    let isKeeper: Bool

    var body: some View {
        let track = entry.info.track
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(TrackFormat.short(track)).monospacedDigit()
                    if isKeeper {
                        Text("Keep")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    if track.isEvicted {
                        Image(systemName: "icloud").foregroundStyle(.secondary).help("Only in iCloud")
                    }
                }
                Text(track.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(track.path)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeFormat.minutes(track.durationMs / 1000)).monospacedDigit()
                Text("\(entry.plays) play\(entry.plays == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
