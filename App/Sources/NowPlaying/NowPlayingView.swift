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
        .modifier(InspectorPanel(tint: app.tint))
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
        let chosen = upcoming.filter { !player.autoplayItems.contains($0.item) }
        let autoplayed = upcoming.filter { player.autoplayItems.contains($0.item) }
        let remaining = remainingCount(player.queue, shown: upcoming.count)
        return List {
            Section("Now Playing") {
                QueueRow(entry: current, artwork: artwork, isCurrent: true, state: player.state)
            }
            Section {
                rows(chosen)
                if remaining > 0, autoplayed.isEmpty {
                    Text("and \(remaining) more").foregroundStyle(.secondary).font(.callout)
                }
                if upcoming.isEmpty {
                    Text(player.repeatMode != .off ? "The queue starts over."
                         : app.autoplays ? "Autoplay adds songs like this one."
                         : "This is the last song.")
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
                    if !chosen.isEmpty {
                        Button("Clear") { Task { await player.clearUpNext() } }
                            .buttonStyle(.link)
                            .help("Take the songs you queued out of Up Next; the song playing and autoplay's stay")
                    }
                    AutoplayToggle(app: app)
                }
            }
            if !autoplayed.isEmpty {
                Section {
                    rows(autoplayed)
                    if remaining > 0 {
                        Text("and \(remaining) more").foregroundStyle(.secondary).font(.callout)
                    }
                } header: {
                    HStack {
                        Text("Autoplay")
                        Spacer()
                        Button("Clear") { Task { await player.clearAutoplay() } }
                            .buttonStyle(.link)
                            .help("Take autoplay's songs out of Up Next")
                    }
                }
            }
        }
        .listStyle(.inset)
        .clearsPlayerBar(app)
    }

    /// Up Next's rows for `section`, which can be dragged to reorder what plays next.
    private func rows(_ section: [Row]) -> some View {
        let player = app.player
        let artwork = app.library?.artwork
        // Each row keeps the file it shows: SwiftUI can still be drawing a row from the
        // queue before (one just replaced by a shorter one), so never index the queue here.
        // Identified by the item, whose index lasts as long as the queue, so a dragged row
        // moves rather than being redrawn as a new one.
        return ForEach(section, id: \.item) { row in
            QueueRow(entry: entries[row.url] ?? QueueEntry(fileName: row.url), artwork: artwork)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { play(row) }
                .contextMenu {
                    Button("Play Now") { play(row) }
                    Button("Play Next") {
                        guard let position = stillThere(row), position != (player.queue.position ?? -1) + 1 else { return }
                        Task { await player.playNext(fromPosition: position) }
                    }
                    .disabled(row.position == (player.queue.position ?? -1) + 1)
                    Divider()
                    Button("Remove from Up Next") {
                        guard let position = stillThere(row) else { return }
                        Task { await player.removeFromQueue(atPosition: position) }
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                }
        }
        .onMove { offsets, destination in move(offsets, to: destination, in: section) }
    }

    /// Where the row's song is in the play order now, if the queue still has it there: it may
    /// have changed under the row.
    private func stillThere(_ row: Row) -> Int? {
        let queue = app.player.queue
        guard queue.order.indices.contains(row.position), queue.order[row.position] == row.item,
              queue.items[row.item] == row.url else { return nil }
        return row.position
    }

    /// Rows dragged from `offsets` to before `destination` (offsets into `upcoming`), as order
    /// positions. Nothing moves if the queue changed under the rows.
    private func move(_ offsets: IndexSet, to destination: Int, in upcoming: [Row]) {
        let rows = offsets.map { upcoming[$0] }
        guard rows.allSatisfy({ stillThere($0) != nil }) else { return }
        let to = destination < upcoming.count ? upcoming[destination].position
            : (upcoming.last.map { $0.position + 1 } ?? 0)
        Task { await app.player.moveInQueue(fromPositions: rows.map(\.position), toPosition: to) }
    }

    private func play(_ row: Row) {
        guard stillThere(row) != nil else { return }
        app.perform { [player = app.player] in try await player.jump(toItem: row.item) }
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
                        fileURL: entry.inLibrary ? nil : entry.url, size: .small, cornerRadius: Theme.Radius.small)
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

/// Turns autoplay on and off from Up Next's header, as in Settings › Playback.
private struct AutoplayToggle: View {
    @Bindable var app: AppState

    var body: some View {
        Toggle(isOn: $app.autoplays) { Image(systemName: "infinity") }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .disabled(app.library == nil)
            .help(app.autoplays ? "Autoplay is on: when Up Next runs out, songs like the last ones keep playing"
                                : "Turn on autoplay: when Up Next runs out, keep playing songs like the last ones")
            .accessibilityLabel("Autoplay")
    }
}

/// The inspector's look. On macOS 26 and later, a glass panel against the library and inset
/// from the window's edges, running its full height, tinted with the cover. Before that, the
/// column itself takes the cover's colour, strongest at the top where the song is.
private struct InspectorPanel: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // Against the library on the leading side, with no gap: the library doesn't run on
            // under the column, as it does under the sidebar, so a gap would show as a strip.
            let radius = Theme.Radius.floatingPanel
            let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
            content
                .scrollContentBackground(.hidden)
                .padding(.trailing, Theme.Spacing.s)
                .background {
                    Color.clear
                        .glassEffect(.regular.tint(tint?.opacity(Theme.Tint.inspector.top)), in: shape)
                        .padding([.top, .trailing, .bottom], Theme.Spacing.s)
                        .ignoresSafeArea()
                }
                .animation(.easeInOut(duration: 0.6), value: tint)
        } else {
            content
                .scrollContentBackground(tint == nil ? .automatic : .hidden)
                .background {
                    if let tint {
                        LinearGradient(colors: [tint.opacity(Theme.Tint.inspector.top), tint.opacity(Theme.Tint.inspector.bottom)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()
                    }
                }
                .animation(.easeInOut(duration: 0.6), value: tint)
        }
    }
}
