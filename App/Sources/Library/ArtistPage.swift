import MiniAmpKit
import SwiftUI

/// An artist: a mosaic of their covers, their most played songs, their albums, and the albums
/// they appear on.
struct ArtistPageView: View {
    let app: AppState
    let library: Library
    let artistID: Int64
    @State private var page: ArtistPage?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if let page {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl - 4) {
                    header(page)
                    if !page.topSongs.isEmpty { topSongs(page) }
                    if !page.albums.isEmpty {
                        Shelf(title: "Albums") {
                            ForEach(page.albums) { AlbumLink(app: app, library: library, album: $0, subtitle: .year) }
                        }
                    }
                    if !page.appearsOn.isEmpty {
                        Shelf(title: "Appears On") {
                            ForEach(page.appearsOn) { AlbumLink(app: app, library: library, album: $0) }
                        }
                    }
                }
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .overlay {
            if loaded && page == nil { ContentUnavailableView("This artist is no longer in the library", systemImage: "music.microphone") }
        }
        .navigationTitle(page?.artist.name ?? "Artist")
        .task(id: library.revision) {
            do {
                page = try await library.artistPage(artistID)
            } catch {
                app.error = "\(error)"
            }
            loaded = true
        }
    }

    private func header(_ page: ArtistPage) -> some View {
        let covers = (page.albums + page.appearsOn).compactMap(\.artworkKey)
        let keys = Array(NSOrderedSet(array: covers).array.compactMap { $0 as? String }.prefix(4))
        return HeroHeader(kind: "Artist", title: page.artist.name, details: details(page.artist),
                          washKey: keys.first ?? page.artist.artworkKey, artwork: library.artwork) {
            CoverMosaic(keys: keys.isEmpty ? page.artist.artworkKey.map { [$0] } ?? [] : keys, artwork: library.artwork)
        } actions: {
            PlayShuffleButtons(play: { playAll(shuffled: false) }, shuffle: { playAll(shuffled: true) })
        }
    }

    private func topSongs(_ page: ArtistPage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.plays.isEmpty ? "Songs" : "Top Songs").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink(value: LibraryDestination.artistSongs(artistID, page.artist.name)) { Text("See All") }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, Theme.Spacing.page)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.Spacing.l)], spacing: 0) {
                ForEach(page.topSongs) { info in
                    SongRow(app: app, info: info, leading: .cover, showsAlbum: true, plays: page.plays[info.track.id ?? 0],
                            offersArtist: false) { app.play(page.topSongs, from: info.id) }
                }
            }
            .padding(.horizontal, Theme.Spacing.page - Theme.Spacing.s)
        }
    }

    private func details(_ artist: ArtistSummary) -> String {
        let songs = CountFormat.songs(artist.trackCount)
        switch artist.albumCount {
        case 0: return songs
        case 1: return "1 album · \(songs)"
        default: return "\(artist.albumCount.formatted()) albums · \(songs)"
        }
    }

    private func playAll(shuffled: Bool) {
        Task {
            guard let tracks = try? await library.tracks(in: .artist(artistID)) else { return }
            app.play(tracks, from: nil, shuffled: shuffled)
        }
    }
}
