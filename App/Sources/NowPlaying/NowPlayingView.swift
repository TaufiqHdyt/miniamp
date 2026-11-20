import MiniAmpKit
import SwiftUI

/// Up Next: what plays after the song playing (which the player bar shows), each with its
/// cover; then what autoplay adds. On macOS 26 and later a glass panel floating over the
/// library, as the sidebar does; before that, the inspector.
struct NowPlayingView: View {
    let app: AppState
    /// The floating panel (macOS 26 and later), rather than the inspector.
    var floating = false
    private var entries: [URL: QueueEntry] { app.upNextEntries }

    /// Rows shown in Up Next. A whole-library queue is thousands long; nobody scrolls that far.
    static let upcomingLimit = 200

    var body: some View {
        let player = app.player
        let upcoming = upcomingRows(player.queue)
        Group {
            if player.queue.current != nil {
                upNext(upcoming: upcoming)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note",
                                       description: Text("Double-click a song to play it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(UpNextPanel(tint: app.tint, floating: floating))
        // Read the tags of what's shown when the queue moves, or when the library changes (a retag).
        .task(id: Shown(urls: upcoming.map(\.url), revision: app.library?.revision ?? 0)) {
            let urls = upcoming.map(\.url)
            let revision = app.library?.revision ?? 0
            // After a library change, read everything again so retagged files show their new tags.
            let stale = revision != app.upNextEntriesRevision
            let wanted = stale ? urls : urls.filter { entries[$0] == nil }
            guard !wanted.isEmpty else { return }
            let loaded = await QueueEntry.load(wanted, from: app.library)
            guard !Task.isCancelled else { return }
            // Only ever over what's there: a read that comes back short (the library busy
            // recording a play) leaves the rows as they were, not as file names.
            var merged = entries
            if stale {
                let shown = Set(urls)
                merged = merged.filter { shown.contains($0.key) }
                app.upNextEntriesRevision = revision
            }
            merged.merge(loaded.filter { $0.value.inLibrary || merged[$0.key] == nil }) { _, new in new }
            if merged != entries { app.upNextEntries = merged }
        }
    }

    private func upNext(upcoming: [Row]) -> some View {
        let player = app.player
        let chosen = upcoming.filter { !player.autoplayItems.contains($0.item) }
        let autoplayed = upcoming.filter { player.autoplayItems.contains($0.item) }
        let remaining = remainingCount(player.queue, shown: upcoming.count)
        // Headings and notes are rows, laid out as the songs are, so everything shares one
        // edge on each side (section headers sit apart, with their own insets).
        return List {
            heading("Up Next", first: true) {
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
            }
            rows(chosen)
            if remaining > 0, autoplayed.isEmpty { note("and \(remaining) more") }
            if chosen.isEmpty {
                note(!autoplayed.isEmpty ? "Nothing queued: Play Next and Play Last add songs here."
                     : player.repeatMode != .off ? "The queue starts over."
                     : "This is the last song.")
            }
            heading("Autoplay", first: false) {
                if !autoplayed.isEmpty {
                    Button("Clear") { Task { await player.clearAutoplay() } }
                        .buttonStyle(.link)
                        .help("Take autoplay's songs out of Up Next")
                }
                AutoplayToggle(app: app)
            }
            rows(autoplayed)
            if remaining > 0, !autoplayed.isEmpty { note("and \(remaining) more") }
            if autoplayed.isEmpty {
                note(app.autoplays ? "When Up Next runs out, songs like the last ones keep playing."
                     : "Off. Turn it on to keep playing songs like the last ones when Up Next runs out.")
            }
        }
        .listStyle(.plain)
        // The floating panel ends above the player bar; the inspector runs on under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: floating ? Theme.Spacing.s : app.playerBarInset).allowsHitTesting(false)
        }
    }

    /// Every row's inset from the list's edges; each pads its content by `rowPadding` inside
    /// that, so a song's hover highlight has room and text lines up across rows.
    static let rowInsets = EdgeInsets(top: 1, leading: Theme.Spacing.xs, bottom: 1, trailing: Theme.Spacing.xs)
    static let rowPadding: CGFloat = Theme.Spacing.m

    private func heading(_ title: String, first: Bool, @ViewBuilder accessories: () -> some View) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(title).font(first ? .title3.weight(.semibold) : .headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            accessories()
        }
        .padding(.horizontal, Self.rowPadding)
        .padding(.top, first ? Theme.Spacing.s : Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.xs)
        .listRowInsets(Self.rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(QueueRow.dimmed)
            .font(.callout)
            .padding(.horizontal, Self.rowPadding)
            .padding(.vertical, Theme.Spacing.xs)
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(Self.rowInsets)
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

/// A queue entry: cover, title over artist and album, and its length; lit under the pointer,
/// on the glass rather than between separators.
private struct QueueRow: View {
    /// Secondary text as a plain colour, not the vibrant `.secondary`: that one follows what's
    /// behind the glass, so it flickered as the library swapped for a full view under it.
    static let dimmed = Color.primary.opacity(0.6)

    let entry: QueueEntry
    let artwork: ArtworkCache?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(key: entry.artworkKey, artwork: artwork,
                        fileURL: entry.inLibrary ? nil : entry.url, size: .small, cornerRadius: Theme.Radius.small)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Self.dimmed).lineLimit(1)
                }
            }
            .help([entry.title, entry.subtitle].compactMap { $0 }.joined(separator: "\n"))
            Spacer(minLength: 4)
            if let ms = entry.durationMs, ms > 0 {
                Text(TimeFormat.minutes(ms / 1000)).monospacedDigit().font(.caption).foregroundStyle(Self.dimmed)
            }
        }
        .padding(.horizontal, NowPlayingView.rowPadding)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.08 : 0))
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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

/// Up Next's look. Floating (macOS 26 and later): a glass card tinted with the cover, rounded
/// like the sidebar. In the inspector: the column takes the cover's colour, strongest at the
/// top.
private struct UpNextPanel: ViewModifier {
    let tint: Color?
    let floating: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), floating {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.floatingPanel, style: .continuous)
            content
                .scrollContentBackground(.hidden)
                .padding(.top, Theme.Spacing.xs)
                .clipShape(shape)
                .glassEffect(.regular.tint(tint?.opacity(Theme.Tint.inspector.top)), in: shape)
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
