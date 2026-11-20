import MiniAmpKit
import SwiftUI

/// Every artist, shared credits split, as a grid of round covers. Clicking one opens their page.
struct ArtistsView: View {
    let app: AppState
    let library: Library
    @State private var artists: [ArtistSummary] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: Theme.Spacing.l)],
                      spacing: Theme.Spacing.l + 2) {
                ForEach(artists) { artist in
                    NavigationLink(value: LibraryDestination.artist(artist.id)) {
                        ArtistTile(artist: artist, artwork: library.artwork)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { play(artist, shuffled: false) }
                        Button("Shuffle") { play(artist, shuffled: true) }
                    }
                }
            }
            .padding(Theme.Spacing.page)
        }
        .overlay {
            if loaded && artists.isEmpty { ContentUnavailableView("No Artists", systemImage: "music.microphone") }
        }
        .pageTitle("Artists", subtitle: artists.isEmpty ? "" : count)
        .task(id: library.revision) {
            let found = (try? await library.artists()) ?? []
            if found != artists { artists = found }
            loaded = true
        }
    }

    private var count: String { artists.count == 1 ? "1 artist" : "\(artists.count.formatted()) artists" }

    private func play(_ artist: ArtistSummary, shuffled: Bool) {
        Task {
            guard let tracks = try? await library.tracks(in: .artist(artist.id)) else { return }
            app.play(tracks, from: nil, shuffled: shuffled)
        }
    }
}

/// A round cover from the artist's songs, their name, and how much of theirs there is.
private struct ArtistTile: View {
    let artist: ArtistSummary
    let artwork: ArtworkCache?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ArtworkView(key: artist.artworkKey, artwork: artwork, size: .medium, cornerRadius: 0)
                .clipShape(Circle())
                .elevation(hovering ? .lifted : .tile)
                .scaleEffect(hovering ? 1.02 : 1)
            Text(artist.name).font(.callout.weight(.semibold)).lineLimit(1).padding(.top, Theme.Spacing.xs)
            Text(CountFormat.songs(artist.trackCount)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A grid of album covers, sorted and filtered from the header. Clicking one opens its page.
struct AlbumsView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case artist, title, year, recentlyAdded
        var id: Self { self }
        var label: String {
            switch self {
            case .artist: "Artist"
            case .title: "Title"
            case .year: "Year"
            case .recentlyAdded: "Recently Added"
            }
        }
    }

    let app: AppState
    let library: Library
    @State private var albums: [AlbumSummary] = []
    @State private var loaded = false
    @AppStorage("albumSort") private var sort: Sort = .artist
    /// A decade (1990 for the 1990s), or 0 for every album.
    @SceneStorage("albumDecade") private var decadeChoice = 0
    private var decade: Int? { decadeChoice == 0 ? nil : decadeChoice }

    private var shown: [AlbumSummary] {
        let filtered = decade.map { d in albums.filter { $0.year.map { $0 / 10 * 10 == d } ?? false } } ?? albums
        switch sort {
        case .artist: return filtered
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year: return filtered.sorted { ($0.year ?? .min, $1.title) > ($1.year ?? .min, $0.title) }
        case .recentlyAdded: return filtered.sorted { $0.addedAt > $1.addedAt }
        }
    }

    private var decades: [Int] { Set(albums.compactMap { $0.year.map { $0 / 10 * 10 } }).sorted(by: >) }

    var body: some View {
        let shown = shown
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: Theme.Spacing.l)], spacing: 22) {
                ForEach(shown) { album in
                    AlbumLink(app: app, library: library, album: album, width: nil)
                }
            }
            .padding(Theme.Spacing.page)
        }
        .overlay {
            if loaded && albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "square.stack")
            } else if loaded && shown.isEmpty, let decade {
                ContentUnavailableView("No Albums from the \(String(decade))s", systemImage: "square.stack")
            }
        }
        .pageTitle("Albums", subtitle: albums.isEmpty ? "" : count(shown.count)) { controls }
        .task(id: library.revision) {
            let found = (try? await library.albums()) ?? []
            if found != albums { albums = found }
            loaded = true
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.s) {
            Menu {
                Picker("Years", selection: $decadeChoice) {
                    Text("All Years").tag(0)
                    Divider()
                    ForEach(decades, id: \.self) { Text("\(String($0))s").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(decade.map { "\(String($0))s" } ?? "All Years", systemImage: "line.3.horizontal.decrease")
            }
            .fixedSize()
            .help("Show albums from one decade")
            Picker("Sort By", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help("Sort albums")
        }
        .labelStyle(.titleAndIcon)
    }

    private func count(_ n: Int) -> String {
        n == 1 ? "1 album" : "\(n.formatted()) albums"
    }
}
