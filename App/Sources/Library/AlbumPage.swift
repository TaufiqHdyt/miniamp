import MiniAmpKit
import SwiftUI

/// An album: the cover large over its wash, its songs by disc, what format and how long, and
/// more by the same artist.
struct AlbumPageView: View {
    let app: AppState
    let library: Library
    let albumID: Int64
    @State private var album: AlbumSummary?
    @State private var tracks: [TrackInfo] = []
    @State private var more: [AlbumSummary] = []
    @State private var loaded = false

    var body: some View {
        UnderToolbarScrollView { toolbarHeight in
            if let album {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header(album, toolbarHeight: toolbarHeight)
                    songs(album)
                    footer(album)
                    if !more.isEmpty {
                        Shelf(title: "More by \(album.artistName ?? "This Artist")") {
                            ForEach(more) { AlbumLink(app: app, library: library, album: $0, subtitle: .year) }
                        }
                        .padding(.top, Theme.Spacing.s)
                    }
                }
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .overlay {
            if loaded && album == nil { ContentUnavailableView("This album is no longer in the library", systemImage: "square.stack") }
        }
        .navigationTitle(album?.title ?? "Album")
        .task(id: library.revision) { await load() }
    }

    private func header(_ album: AlbumSummary, toolbarHeight: CGFloat) -> some View {
        HeroHeader(kind: kind(album), title: album.title, subtitle: album.artistName ?? "Unknown Artist",
                   openSubtitle: album.artistId == nil ? nil : { app.showArtist(credit: album.artistId) },
                   details: details(album), washKey: album.artworkKey, artwork: library.artwork,
                   toolbarHeight: toolbarHeight) {
            ArtworkView(key: album.artworkKey, artwork: library.artwork, size: .medium, cornerRadius: Theme.Radius.large)
        } actions: {
            PlayShuffleButtons(play: { app.play(tracks, from: nil) }, shuffle: { app.play(tracks, from: nil, shuffled: true) })
                .disabled(tracks.isEmpty)
        }
    }

    @ViewBuilder
    private func songs(_ album: AlbumSummary) -> some View {
        let discs = Dictionary(grouping: tracks) { $0.track.discNumber ?? 1 }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(discs.keys.sorted(), id: \.self) { disc in
                if discs.count > 1 {
                    Text("Disc \(disc)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.top, disc == discs.keys.min() ? 0 : Theme.Spacing.m)
                        .padding(.bottom, Theme.Spacing.xs)
                }
                ForEach(discs[disc] ?? []) { info in
                    SongRow(app: app, info: info, showsArtist: info.artistName != album.artistName,
                            offersAlbum: false) { app.play(tracks, from: info.id) }
                    Divider().padding(.leading, 44).opacity(0.5)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.page - Theme.Spacing.s)
    }

    private func footer(_ album: AlbumSummary) -> some View {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append(CountFormat.songs(album.trackCount))
        parts.append(Duration.seconds(album.durationMs / 1000).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
        let formats = Set(tracks.map { TrackFormat.short($0.track) })
        if formats.count == 1, let format = formats.first { parts.append(format) } else if formats.count > 1 { parts.append("Mixed formats") }
        return Text(parts.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.page)
    }

    private func kind(_ album: AlbumSummary) -> String {
        switch album.trackCount {
        case ...3: "Single"
        case ...6: "EP"
        default: "Album"
        }
    }

    private func details(_ album: AlbumSummary) -> String {
        var parts: [String] = []
        if let genre = tracks.lazy.compactMap(\.track.genre).first(where: { !$0.isEmpty }) { parts.append(genre) }
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            guard let found = try await library.album(albumID) else {
                album = nil
                loaded = true
                return
            }
            tracks = try await library.tracks(in: .album(albumID))
            album = found
            loaded = true
            if let credit = found.artistId {
                let artist = try await library.leadArtist(ofCredit: credit)
                more = try await library.albums(artistId: artist).filter { $0.id != albumID }
            } else {
                more = []
            }
        } catch {
            app.error = "\(error)"
        }
    }
}

/// An album's cover and name, opening its page; Play on hover, and a menu to queue it.
struct AlbumLink: View {
    enum Subtitle { case artist, year }

    let app: AppState
    let library: Library
    let album: AlbumSummary
    var subtitle: Subtitle = .artist
    var width: CGFloat? = 160

    var body: some View {
        NavigationLink(value: LibraryDestination.album(album.id)) {
            ArtworkTile(title: album.title, subtitle: subtitleText, artworkKey: album.artworkKey,
                        artwork: library.artwork) { play(shuffled: false) }
                .frame(width: width)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play") { play(shuffled: false) }
            Button("Shuffle") { play(shuffled: true) }
            Divider()
            Button("Play Next") { enqueue(next: true) }
            Button("Play Last") { enqueue(next: false) }
            if album.artistId != nil {
                Divider()
                Button("Go to Artist") { app.showArtist(credit: album.artistId) }
            }
        }
    }

    private var subtitleText: String {
        switch subtitle {
        case .artist: album.artistName ?? "Unknown Artist"
        case .year: album.year.map(String.init) ?? CountFormat.songs(album.trackCount)
        }
    }

    private func play(shuffled: Bool) {
        Task {
            guard let tracks = try? await library.tracks(in: .album(album.id)) else { return }
            app.play(tracks, from: nil, shuffled: shuffled)
        }
    }

    private func enqueue(next: Bool) {
        Task {
            guard let tracks = try? await library.tracks(in: .album(album.id)) else { return }
            app.enqueue(tracks, next: next)
        }
    }
}
