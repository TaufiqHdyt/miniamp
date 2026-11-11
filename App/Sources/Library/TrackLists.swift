import AppKit
import MiniAmpKit
import SwiftUI

/// The tracks in a scope, sorted by a column header, reloaded whenever the library changes.
struct TrackListView: View {
    let app: AppState
    let library: Library
    let scope: TrackScope
    let title: String
    @State private var rows = TrackRows()
    private var tracks: [TrackInfo] { rows.tracks }
    @State private var loaded = false
    /// What `rows` shows, and when it was read: library changes reload at most once a second.
    @State private var shown: (scope: TrackScope, sort: TrackSort)?
    @State private var lastLoad: ContinuousClock.Instant?
    /// Sort per kind of list ("songs", "artist", …), so an album keeps album order while Songs is by title.
    @SceneStorage("trackSorts") private var savedSorts = ""

    private var playlist: Int64? { if case .playlist(let id) = scope { id } else { nil } }
    private var inPlaylist: Bool { playlist != nil }

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
        TrackTable(app: app, rows: rows, playlist: playlist,
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
            .task { await cycleSortsIfAsked() }
    }

    /// For performance checks (`-perfCycleSort YES -logHangs YES`): re-sorts Songs a few
    /// times, so each reload of an on-screen list gets measured.
    private func cycleSortsIfAsked() async {
        guard UserDefaults.standard.bool(forKey: "perfCycleSort"), case .all = scope else { return }
        try? await Task.sleep(for: .seconds(3))
        for column in [TrackSort.Column.title, .artist, .duration, .quality, .year, .albumOrder] {
            sort = TrackSort(column, ascending: column != .duration)
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func load() async {
        let scope = scope, sort = sort
        // A scan commits a batch every fraction of a second. Waiting for a pause would leave
        // the list empty until the scan ends, so reload at most once a second instead. A new
        // scope or sort loads at once.
        if let shown, shown.scope == scope, shown.sort == sort, let lastLoad {
            try? await Task.sleep(until: lastLoad + .seconds(1))
            guard !Task.isCancelled else { return }
        }
        lastLoad = .now
        do {
            let found = try await library.tracks(in: scope, sort: sort)
            // Keep the result even if another change came in meanwhile (it's fresh, and
            // dropping it could starve the list during a scan), unless the question changed.
            guard scope == self.scope, sort == self.sort else { return }
            let measured = MainThreadWatchdog.measure("show \(found.count) songs")
            if found != rows.tracks { rows = TrackRows(found) }
            shown = (scope, sort)
            loaded = true
            measured()
        } catch {
            app.error = "\(error)"
        }
    }
}

/// Library search results: best matches first until a header is clicked.
struct SearchResultsView: View {
    let app: AppState
    let library: Library
    let query: String
    @State private var rows = TrackRows()
    private var results: [TrackInfo] { rows.tracks }
    @State private var sort = TrackSort(.relevance)
    @State private var searched = false

    static let limit = 1000

    var body: some View {
        TrackTable(app: app, rows: rows, sort: $sort)
            .overlay {
                if searched && results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            .navigationSubtitle(subtitle)
            .task(id: SearchQuery(text: query, sort: sort, revision: library.revision)) {
                // Wait for a pause in typing.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                do {
                    let found = try await library.search(query, sort: sort, limit: Self.limit)
                    guard !Task.isCancelled else { return }
                    if found != rows.tracks { rows = TrackRows(found) }
                    searched = true
                } catch {
                    app.error = "\(error)"
                }
            }
    }

    private var subtitle: String {
        switch results.count {
        case 0: ""
        case 1: "1 song"
        case Self.limit: "First \(Self.limit) songs"
        default: "\(results.count) songs"
        }
    }

    private struct SearchQuery: Equatable {
        var text: String
        var sort: TrackSort
        var revision: Int
    }
}

/// A list's rows, held by reference.
///
/// As a plain array in @State, every reload had SwiftUI compare the old and new arrays field by
/// field: about 110 ms of main thread for 10,000 tracks. A reference compares by identity.
final class TrackRows {
    let tracks: [TrackInfo]
    init(_ tracks: [TrackInfo] = []) { self.tracks = tracks }
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
