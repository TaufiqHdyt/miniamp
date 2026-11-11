import MiniAmpKit
import SwiftUI

/// The inspector: the current track's cover and details, then what plays next.
struct NowPlayingView: View {
    let app: AppState
    @State private var entries: [URL: QueueEntry] = [:]
    /// The library revision `entries` were read at.
    @State private var entriesRevision = 0

    /// Rows shown in Up Next. A whole-library queue is thousands long; nobody scrolls that far.
    static let upcomingLimit = 200

    var body: some View {
        let player = app.player
        let upcoming = upcomingRows(player.queue)
        VStack(spacing: 0) {
            if let url = player.queue.current {
                let entry = entries[url] ?? QueueEntry(fileName: url)
                CurrentTrack(entry: entry, artwork: app.library?.artwork)
                    .padding([.horizontal, .top], 16)
                if let path = player.signalPath {
                    QualityBadge(path: path).padding(.vertical, 10)
                } else {
                    Spacer().frame(height: 16)
                }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note",
                                       description: Text("Double-click a song to play it."))
                    .frame(maxHeight: 260)
            }
            Divider()
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                if player.queue.isShuffled { Image(systemName: "shuffle").foregroundStyle(.secondary).help("Shuffled") }
                if player.repeatMode != .off {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(.secondary)
                        .help(player.repeatMode == .one ? "Repeating one" : "Repeating all")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            List {
                ForEach(upcoming, id: \.position) { row in
                    let url = player.queue.items[row.item]
                    UpNextRow(entry: entries[url] ?? QueueEntry(fileName: url))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { app.perform { try await player.jump(toItem: row.item) } }
                }
                let remaining = remainingCount(player.queue, shown: upcoming.count)
                if remaining > 0 {
                    Text("and \(remaining) more").foregroundStyle(.secondary).font(.callout)
                }
                if upcoming.isEmpty && !player.queue.isEmpty {
                    Text(player.repeatMode == .off ? "This is the last song." : "The queue starts over.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            .listStyle(.plain)
        }
        // Read the tags of what's shown when the queue moves, or when the library changes (a retag).
        .task(id: Shown(urls: [player.queue.current].compactMap { $0 } + upcoming.map { player.queue.items[$0.item] },
                        revision: app.library?.revision ?? 0)) {
            let urls = [player.queue.current].compactMap { $0 } + upcoming.map { player.queue.items[$0.item] }
            let revision = app.library?.revision ?? 0
            // After a library change, read everything again so retagged files show their new tags.
            let stale = revision != entriesRevision
            let wanted = stale ? urls : urls.filter { entries[$0] == nil }
            guard !wanted.isEmpty else { return }
            let loaded = await QueueEntry.load(wanted, from: app.library)
            guard !Task.isCancelled else { return }
            if stale {
                entries = loaded
                entriesRevision = revision
            } else {
                entries.merge(loaded) { _, new in new }
            }
        }
    }

    private struct Row { var position: Int; var item: Int }

    private struct Shown: Equatable {
        var urls: [URL]
        var revision: Int
    }

    /// The next rows in play order after the current one.
    private func upcomingRows(_ queue: PlayQueue<URL>) -> [Row] {
        guard let position = queue.position else { return [] }
        let end = min(queue.order.count, position + 1 + Self.upcomingLimit)
        return (position + 1 ..< end).map { Row(position: $0, item: queue.order[$0]) }
    }

    private func remainingCount(_ queue: PlayQueue<URL>, shown: Int) -> Int {
        guard let position = queue.position else { return 0 }
        return queue.order.count - position - 1 - shown
    }
}

private struct CurrentTrack: View {
    let entry: QueueEntry
    let artwork: ArtworkCache?

    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(key: entry.artworkKey, artwork: artwork,
                        fileURL: entry.inLibrary ? nil : entry.url, cornerRadius: 8)
                .frame(maxWidth: 360)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            VStack(spacing: 3) {
                Text(entry.title).font(.title3.bold()).multilineTextAlignment(.center)
                if let artist = entry.artist, !artist.isEmpty { Text(artist).foregroundStyle(.secondary) }
                if let album = entry.album, !album.isEmpty { Text(album).foregroundStyle(.secondary).font(.callout) }
            }
            .lineLimit(2)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct UpNextRow: View {
    let entry: QueueEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let ms = entry.durationMs, ms > 0 {
                Text(TimeFormat.minutes(ms / 1000)).monospacedDigit().foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}
