import AppKit
import MiniAmpKit
import SwiftUI

/// The tracks in a scope, sorted by a column header, reloaded whenever the library changes.
struct TrackListView: View {
    let app: AppState
    let library: Library
    let scope: TrackScope
    let title: String
    @State private var tracks: [TrackInfo] = []
    @State private var loaded = false
    /// Sort per kind of list ("songs", "artist", …), so an album keeps album order while Songs is by title.
    @SceneStorage("trackSorts") private var savedSorts = ""

    private var inPlaylist: Bool { if case .playlist = scope { true } else { false } }

    private var sortKey: String {
        switch scope {
        case .all: "songs"
        case .artist: "artist"
        case .album: "album"
        case .playlist: "playlist"
        }
    }

    private var sort: TrackSort {
        get { SortStorage.decode(savedSorts)[sortKey] ?? (inPlaylist ? TrackSort(.playlistOrder) : .albumOrder) }
        nonmutating set {
            var all = SortStorage.decode(savedSorts)
            all[sortKey] = newValue
            savedSorts = SortStorage.encode(all)
        }
    }

    var body: some View {
        TrackTable(app: app, tracks: tracks, inPlaylist: inPlaylist,
                   sort: Binding(get: { sort }, set: { sort = $0 }))
            .overlay {
                if loaded && tracks.isEmpty {
                    ContentUnavailableView(library.folders.isEmpty ? "No music yet" : "Nothing here",
                                           systemImage: "music.note",
                                           description: Text(library.folders.isEmpty
                                               ? "Add a music folder in Settings."
                                               : "No tracks match."))
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(tracks.isEmpty ? "" : "\(tracks.count) songs")
            .task(id: TrackQuery(scope: scope, sort: sort, revision: library.revision)) {
                await load()
            }
    }

    private func load() async {
        let sort = sort
        // A scan commits in batches; let a burst of changes settle before reloading.
        if loaded { try? await Task.sleep(for: .milliseconds(150)) }
        guard !Task.isCancelled else { return }
        do {
            let found = try await library.tracks(in: scope, sort: sort)
            guard !Task.isCancelled else { return }
            tracks = found
            loaded = true
        } catch {
            app.error = "\(error)"
        }
    }
}

private struct TrackQuery: Equatable {
    var scope: TrackScope
    var sort: TrackSort
    var revision: Int
}

/// "songs=title:1;album=albumOrder:1", for SceneStorage.
private enum SortStorage {
    static func decode(_ text: String) -> [String: TrackSort] {
        var sorts: [String: TrackSort] = [:]
        for entry in text.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].split(separator: ":")
            guard value.count == 2, let column = TrackSort.Column(rawValue: String(value[0])) else { continue }
            sorts[String(parts[0])] = TrackSort(column, ascending: value[1] == "1")
        }
        return sorts
    }

    static func encode(_ sorts: [String: TrackSort]) -> String {
        sorts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.column.rawValue):\($0.value.ascending ? 1 : 0)" }
            .joined(separator: ";")
    }
}

/// A table of tracks. Double-click (or Return) plays the list from that row. Clicking a
/// header sorts by it; the rows arrive already sorted from the database.
struct TrackTable: View {
    let app: AppState
    let tracks: [TrackInfo]
    var inPlaylist = false
    @Binding var sort: TrackSort
    @State private var selection: Set<TrackInfo.ID> = []
    @SceneStorage("trackColumns") private var columns = TableColumnCustomization<TrackInfo>()

    var body: some View {
        let positions = inPlaylist
            ? Dictionary(tracks.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a }) : [:]
        Table(tracks, selection: $selection, sortOrder: sortOrder, columnCustomization: $columns) {
            TableColumn("#", value: \.sortTrackNumber) { info in
                Text(inPlaylist ? positions[info.id].map(String.init) ?? "" : info.track.trackNumber.map(String.init) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 24, ideal: 30, max: 50)
            .customizationID("number")
            TableColumn("Title", value: \.track.title) { info in
                TitleCell(app: app, info: info)
            }
            .width(min: 120, ideal: 260)
            .customizationID("title")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Artist", value: \.sortArtist) { info in Text(info.artistName ?? "") }
                .width(min: 80, ideal: 160)
                .customizationID("artist")
            TableColumn("Album", value: \.sortAlbum) { info in Text(info.albumTitle ?? "") }
                .width(min: 80, ideal: 180)
                .customizationID("album")
            TableColumn("Year", value: \.sortYear) { info in
                Text(info.track.year.map(String.init) ?? "").monospacedDigit()
            }
            .width(min: 36, ideal: 44, max: 60)
            .customizationID("year")
            .defaultVisibility(.hidden)
            TableColumn("Genre", value: \.sortGenre) { info in Text(info.track.genre ?? "") }
                .width(min: 60, ideal: 110)
                .customizationID("genre")
                .defaultVisibility(.hidden)
            TableColumn("Time", value: \.track.durationMs) { info in
                Text(TimeFormat.minutes(info.track.durationMs / 1000))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 50, max: 70)
            .customizationID("time")
            TableColumn("Quality", value: \.track.sampleRate) { info in
                QualityCell(info: info, isDownloading: app.isWaitingToPlay(info.id))
            }
            .width(min: 70, ideal: 110, max: 160)
            .customizationID("quality")
            TableColumn("Date Added", value: \.track.addedAt) { info in
                Text(info.track.addedAt, format: .dateTime.year().month().day())
            }
            .width(min: 70, ideal: 90, max: 130)
            .customizationID("added")
            .defaultVisibility(.hidden)
        }
        .contextMenu(forSelectionType: TrackInfo.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            app.play(tracks, from: ids.first)
        }
    }

    /// The header state for `sort`, and back: Table reports a click as a new first comparator.
    private var sortOrder: Binding<[KeyPathComparator<TrackInfo>]> {
        Binding {
            let column: TrackSort.Column = sort.column == .playlistOrder ? .albumOrder : sort.column
            guard var comparator = Self.headers.first(where: { $0.column == column })?.comparator else { return [] }
            comparator.order = sort.ascending ? .forward : .reverse
            return [comparator]
        } set: { comparators in
            guard let first = comparators.first else { return }
            let column = Self.headers.first { $0.comparator.keyPath == first.keyPath }?.column ?? .albumOrder
            let resolved: TrackSort.Column = column == .albumOrder && inPlaylist ? .playlistOrder : column
            sort = TrackSort(resolved, ascending: first.order == .forward)
        }
    }

    /// "#" is album order (or playlist order): sorting by track number alone mixes albums together.
    private static let headers: [(comparator: KeyPathComparator<TrackInfo>, column: TrackSort.Column)] = [
        (KeyPathComparator(\.sortTrackNumber), .albumOrder),
        (KeyPathComparator(\.track.title), .title),
        (KeyPathComparator(\.sortArtist), .artist),
        (KeyPathComparator(\.sortAlbum), .album),
        (KeyPathComparator(\.sortYear), .year),
        (KeyPathComparator(\.sortGenre), .genre),
        (KeyPathComparator(\.track.durationMs), .duration),
        (KeyPathComparator(\.track.sampleRate), .quality),
        (KeyPathComparator(\.track.addedAt), .dateAdded),
    ]

    @ViewBuilder
    private func menu(for ids: Set<TrackInfo.ID>) -> some View {
        let chosen = tracks.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Play") { app.play(chosen.count > 1 ? chosen : tracks, from: chosen.first?.id) }
            Button("Shuffle") { app.play(chosen.count > 1 ? chosen : tracks, from: nil, shuffled: true) }
            Divider()
            if chosen.contains(where: \.track.isEvicted) {
                Button("Download from iCloud") { app.library?.download(chosen.map(\.track)) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.track.url))
            }
        }
    }
}

/// Comparable stand-ins for the header key paths. The database does the actual sorting.
extension TrackInfo {
    var sortTrackNumber: Int { track.trackNumber ?? 0 }
    var sortArtist: String { artistName ?? "" }
    var sortAlbum: String { albumTitle ?? "" }
    var sortYear: Int { track.year ?? 0 }
    var sortGenre: String { track.genre ?? "" }
}

/// The title, with a speaker on the track that's playing.
private struct TitleCell: View {
    let app: AppState
    let info: TrackInfo

    var body: some View {
        HStack(spacing: 4) {
            if app.currentURL == info.track.url {
                Image(systemName: app.player.state == .playing ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.small)
            }
            Text(info.track.title)
        }
    }
}

private struct QualityCell: View {
    let info: TrackInfo
    let isDownloading: Bool

    var body: some View {
        if isDownloading {
            ProgressView().controlSize(.mini).help("Downloading from iCloud; plays when it's ready")
        } else if info.track.isEvicted {
            Label("In iCloud", systemImage: "icloud")
                .foregroundStyle(.secondary)
                .help("Not downloaded. Double-click to download and play.")
        } else {
            Text(TrackFormat.short(info.track))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

enum TrackFormat {
    /// "FLAC 96/24", "MP3 320k".
    static func short(_ track: Track) -> String {
        short(codec: track.codec, sampleRate: track.sampleRate, bits: track.bitsPerSample, bitrateKbps: track.bitrateKbps)
    }

    static func short(codec: String, sampleRate: Int, bits: Int?, bitrateKbps: Int) -> String {
        guard sampleRate > 0 else { return codec }
        let khz = Double(sampleRate) / 1000
        let rate = khz == khz.rounded() ? "\(Int(khz))" : String(format: "%.1f", khz)
        if let bits { return "\(codec) \(rate)/\(bits)" }
        return bitrateKbps > 0 ? "\(codec) \(bitrateKbps)k" : "\(codec) \(rate)"
    }
}

enum TimeFormat {
    /// "3:07", "1:02:03".
    static func minutes(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
