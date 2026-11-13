import MiniAmpKit
import SwiftUI

/// Artists on the left, the selected artist's songs on the right.
struct ArtistsView: View {
    let app: AppState
    let library: Library
    @State private var artists: [ArtistSummary] = []
    @State private var loaded = false
    @SceneStorage("selectedArtist") private var selectedID: Int = 0

    var body: some View {
        HSplitView {
            List(artists, selection: Binding(get: { Int64(selectedID) }, set: { selectedID = Int($0 ?? 0) })) { artist in
                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name)
                    Text(counts(artist)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(artist.id)
            }
            .frame(minWidth: 180, idealWidth: 230, maxWidth: 360)

            if let artist = artists.first(where: { $0.id == Int64(selectedID) }) {
                TrackListView(app: app, library: library, scope: .artist(artist.id), title: artist.name)
                    .frame(minWidth: 400)
            } else {
                // Nothing until the list is read, rather than a flash of "No Artists".
                Group {
                    if loaded { ContentUnavailableView(artists.isEmpty ? "No Artists" : "Choose an Artist", systemImage: "music.microphone") }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Artists")
            }
        }
        .task(id: library.revision) {
            artists = (try? await library.artists()) ?? []
            loaded = true
        }
    }

    private func counts(_ artist: ArtistSummary) -> String {
        let songs = CountFormat.songs(artist.trackCount)
        switch artist.albumCount {
        case 0: return songs
        case 1: return "1 album, \(songs)"
        default: return "\(artist.albumCount.formatted()) albums, \(songs)"
        }
    }
}

/// A grid of album covers. Clicking one shows its songs.
struct AlbumsView: View {
    let app: AppState
    let library: Library
    @State private var albums: [AlbumSummary] = []
    @State private var loaded = false
    @State private var path: [AlbumSummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20)], spacing: 22) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumTile(album: album, artwork: library.artwork) { play(album, shuffled: false) }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play") { play(album, shuffled: false) }
                            Button("Shuffle") { play(album, shuffled: true) }
                            Divider()
                            Button("Play Next") { enqueue(album, next: true) }
                            Button("Play Last") { enqueue(album, next: false) }
                        }
                    }
                }
                .padding(20)
            }
            .overlay {
                if loaded && albums.isEmpty { ContentUnavailableView("No Albums", systemImage: "square.stack") }
            }
            .navigationTitle("Albums")
            .navigationDestination(for: AlbumSummary.self) { album in
                AlbumDetail(app: app, library: library, album: album)
            }
        }
        .task(id: library.revision) {
            albums = (try? await library.albums()) ?? []
            loaded = true
        }
    }

    private func play(_ album: AlbumSummary, shuffled: Bool) {
        Task {
            guard let tracks = try? await library.tracks(in: .album(album.id)) else { return }
            app.play(tracks, from: nil, shuffled: shuffled)
        }
    }

    private func enqueue(_ album: AlbumSummary, next: Bool) {
        Task {
            guard let tracks = try? await library.tracks(in: .album(album.id)) else { return }
            app.enqueue(tracks, next: next)
        }
    }
}

/// A cover with the album's title and artist. Hovering dims the cover a little and shows a
/// play button on it, as in Apple Music; clicking elsewhere opens the album.
private struct AlbumTile: View {
    let album: AlbumSummary
    let artwork: ArtworkCache?
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ArtworkView(key: album.artworkKey, artwork: artwork, cornerRadius: 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(hovering ? 0.18 : 0))
                }
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        Button(action: play) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Play \(album.title)")
                        .transition(.opacity)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.15), radius: hovering ? 4 : 2, y: 1)
            Text(album.title).lineLimit(1).padding(.top, 3)
            Text(album.artistName ?? "Unknown Artist").lineLimit(1).font(.callout).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct AlbumDetail: View {
    let app: AppState
    let library: Library
    let album: AlbumSummary
    @State private var tracks: [TrackInfo] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 18) {
                ArtworkView(key: album.artworkKey, artwork: library.artwork, cornerRadius: 6)
                    .frame(width: 140, height: 140)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title).font(.title.bold()).lineLimit(2)
                    Text(album.artistName ?? "Unknown Artist").font(.title3).foregroundStyle(.secondary)
                    Text(details).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button { app.play(tracks, from: nil) } label: { Label("Play", systemImage: "play.fill") }
                            .keyboardShortcut(.defaultAction)
                        Button { app.play(tracks, from: nil, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    }
                    .padding(.top, 6)
                    .disabled(tracks.isEmpty)
                }
                Spacer()
            }
            .padding(20)
            TrackListView(app: app, library: library, scope: .album(album.id), title: album.title)
        }
        .navigationTitle(album.title)
        .task(id: library.revision) {
            tracks = (try? await library.tracks(in: .album(album.id))) ?? []
        }
    }

    private var details: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append(CountFormat.songs(album.trackCount))
        parts.append(TimeFormat.minutes(album.durationMs / 1000))
        return parts.joined(separator: " · ")
    }
}
