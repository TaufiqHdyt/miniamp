import MiniAmpKit
import SwiftUI

/// The inspector, in one of two panes, each opened by its own button in the player bar:
/// Up Next (the song playing, then what follows, each with its cover) or Lyrics.
struct NowPlayingView: View {
    let app: AppState
    @State private var entries: [URL: QueueEntry] = [:]
    /// The library revision `entries` were read at.
    @State private var entriesRevision = 0

    /// Rows shown in Up Next. A whole-library queue is thousands long; nobody scrolls that far.
    static let upcomingLimit = 200

    var body: some View {
        let player = app.player
        // Lyrics don't need the queue's tags read.
        let upcoming = app.inspectorPane == .upNext ? upcomingRows(player.queue) : []
        Group {
            if let url = player.queue.current {
                let entry = entries[url] ?? QueueEntry(fileName: url)
                switch app.inspectorPane {
                case .upNext:
                    upNext(current: entry, upcoming: upcoming)
                case .lyrics:
                    LyricsView(app: app, url: url) {
                        QueueRow(entry: entry, artwork: app.library?.artwork, isCurrent: true, state: player.state)
                    }
                    .id(url)
                }
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note",
                                       description: Text("Double-click a song to play it."))
            }
        }
        // The cover's colour, strongest at the top where the song is, fading down the list.
        .scrollContentBackground(app.tint == nil ? .automatic : .hidden)
        .background {
            if let tint = app.tint {
                LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.6), value: app.tint)
        // Read the tags of what's shown when the queue moves, or when the library changes (a retag).
        .task(id: Shown(urls: [player.queue.current].compactMap { $0 } + upcoming.map(\.url),
                        revision: app.library?.revision ?? 0)) {
            let urls = [player.queue.current].compactMap { $0 } + upcoming.map(\.url)
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

    private func upNext(current: QueueEntry, upcoming: [Row]) -> some View {
        let player = app.player
        let artwork = app.library?.artwork
        return List {
            Section("Now Playing") {
                QueueRow(entry: current, artwork: artwork, isCurrent: true, state: player.state)
            }
            Section {
                // Each row keeps the file it shows: SwiftUI can still be drawing a row from the
                // queue before (one just replaced by a shorter one), so never index the queue here.
                ForEach(upcoming, id: \.self) { row in
                    QueueRow(entry: entries[row.url] ?? QueueEntry(fileName: row.url), artwork: artwork)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            // Only if it's still that song: the queue may have changed under the row.
                            guard player.queue.items.indices.contains(row.item), player.queue.items[row.item] == row.url else { return }
                            app.perform { try await player.jump(toItem: row.item) }
                        }
                }
                let remaining = remainingCount(player.queue, shown: upcoming.count)
                if remaining > 0 {
                    Text("and \(remaining) more").foregroundStyle(.secondary).font(.callout)
                }
                if upcoming.isEmpty {
                    Text(player.repeatMode == .off ? "This is the last song." : "The queue starts over.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            } header: {
                HStack {
                    Text("Up Next")
                    Spacer()
                    if player.queue.isShuffled { Image(systemName: "shuffle").help("Shuffled") }
                    if player.repeatMode != .off {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .help(player.repeatMode == .one ? "Repeating one" : "Repeating all")
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private struct Row: Hashable {
        var position: Int
        var item: Int
        var url: URL
    }

    private struct Shown: Equatable {
        var urls: [URL]
        var revision: Int
    }

    /// The next rows in play order after the current one.
    private func upcomingRows(_ queue: PlayQueue<URL>) -> [Row] {
        guard let position = queue.position else { return [] }
        let end = min(queue.order.count, position + 1 + Self.upcomingLimit)
        return (position + 1 ..< end).map { Row(position: $0, item: queue.order[$0], url: queue.items[queue.order[$0]]) }
    }

    private func remainingCount(_ queue: PlayQueue<URL>, shown: Int) -> Int {
        guard let position = queue.position else { return 0 }
        return queue.order.count - position - 1 - shown
    }
}

/// A queue entry: cover, title over artist and album, and its length. The song playing is
/// marked with the playing bars and its format.
private struct QueueRow: View {
    let entry: QueueEntry
    let artwork: ArtworkCache?
    var isCurrent = false
    var state: Player.State = .stopped

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(key: entry.artworkKey, artwork: artwork,
                        fileURL: entry.inLibrary ? nil : entry.url, size: .small, cornerRadius: 4)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help([entry.title, entry.subtitle].compactMap { $0 }.joined(separator: "\n"))
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if isCurrent {
                    PlayingBars(isPlaying: state == .playing)
                        .help(state == .playing ? "Playing" : "Paused")
                } else if let ms = entry.durationMs, ms > 0 {
                    Text(TimeFormat.minutes(ms / 1000)).monospacedDigit()
                }
                if isCurrent { Text(entry.format).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
