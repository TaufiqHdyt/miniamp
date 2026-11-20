import AppKit
import MiniAmpKit
import SwiftUI

/// A page opened over a sidebar item: an album or an artist, by id, or all an artist's songs.
enum LibraryDestination: Hashable {
    case album(Int64)
    case artist(Int64)
    case artistSongs(Int64, String)
}

extension AppState {
    /// The page of the artist a song or album is credited to: the first named, in a shared credit.
    func showArtist(credit: Int64?) {
        guard let credit, let library else { return }
        Task {
            guard let id = try? await library.leadArtist(ofCredit: credit) else { return }
            show(.artist(id))
        }
    }

    func showAlbum(of info: TrackInfo) {
        if let id = info.track.albumId { show(.album(id)) }
    }
}

/// The pages a NavigationStack in the library can open.
struct LibraryDestinationView: View {
    let app: AppState
    let library: Library
    let destination: LibraryDestination

    var body: some View {
        switch destination {
        case .album(let id): AlbumPageView(app: app, library: library, albumID: id)
        case .artist(let id): ArtistPageView(app: app, library: library, artistID: id)
        case .artistSongs(let id, let name): TrackListView(app: app, library: library, scope: .artist(id), title: name)
        }
    }
}

/// What a song's context menu offers outside the songs table: queueing, Get Info, playlists,
/// its album and artist, and the Finder.
struct TrackMenuItems: View {
    let app: AppState
    let tracks: [TrackInfo]
    /// Off on the album's own page.
    var offersAlbum = true
    /// Off on the artist's own page.
    var offersArtist = true

    var body: some View {
        let local = tracks.filter { !$0.track.isEvicted }
        Button("Play Next") { app.enqueue(tracks, next: true) }.disabled(local.isEmpty)
        Button("Play Last") { app.enqueue(tracks, next: false) }.disabled(local.isEmpty)
        Divider()
        Button("Get Info…") { app.editTags(of: local) }.disabled(local.isEmpty)
        Menu("Add to Playlist") {
            Button("New Playlist from Selection") { app.newPlaylist(with: tracks) }
            if !app.playlists.isEmpty { Divider() }
            ForEach(app.playlists) { playlist in
                Button(playlist.name) { app.add(tracks, toPlaylist: playlist.id) }
            }
        }
        if tracks.count == 1, let info = tracks.first {
            Divider()
            if offersAlbum, info.track.albumId != nil {
                Button("Go to Album") { app.showAlbum(of: info) }
            }
            if offersArtist, info.track.artistId != nil {
                Button("Go to Artist") { app.showArtist(credit: info.track.artistId) }
            }
        }
        Divider()
        if tracks.contains(where: \.track.isEvicted) {
            Button("Download from iCloud") { app.library?.download(tracks.map(\.track)) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(tracks.map(\.track.url)) }
    }
}

/// A song in a short list on a page (an album's songs, an artist's top songs): its number or
/// cover, title, and length, bars while it plays. Double-click plays the list from it.
struct SongRow: View {
    enum Leading { case number, cover }

    let app: AppState
    let info: TrackInfo
    var leading: Leading = .number
    /// The artist, under the title: where it isn't the page's own.
    var showsArtist = false
    /// The album, beside the artist.
    var showsAlbum = false
    var plays: Int? = nil
    /// Whether the menu has Go to Album and Go to Artist: not on that album's or artist's page.
    var offersAlbum = true
    var offersArtist = true
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        let isCurrent = app.currentURL == info.track.url
        HStack(spacing: Theme.Spacing.m) {
            Group {
                switch leading {
                case .number:
                    ZStack {
                        if isCurrent {
                            PlayingBars(isPlaying: app.player.state == .playing)
                        } else if hovering {
                            Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(info.track.trackNumber.map(String.init) ?? "")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 24, alignment: .trailing)
                case .cover:
                    ArtworkView(key: info.track.artworkKey, artwork: app.library?.artwork, size: .small, cornerRadius: Theme.Radius.small)
                        .frame(width: 36, height: 36)
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: Theme.Radius.small).fill(.black.opacity(0.4))
                                PlayingBars(isPlaying: app.player.state == .playing)
                            }
                        }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.track.title)
                    .fontWeight(isCurrent ? .semibold : .medium)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                if let line = secondLine {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: Theme.Spacing.s)
            if let plays {
                Text(plays == 1 ? "1 play" : "\(plays.formatted()) plays")
                    .font(.callout).foregroundStyle(.tertiary).monospacedDigit()
            }
            if info.track.isEvicted {
                Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).help("In iCloud only")
            }
            Text(TimeFormat.minutes(info.track.durationMs / 1000))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, leading == .cover ? 4 : 7)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play", play)
        .contextMenu { TrackMenuItems(app: app, tracks: [info], offersAlbum: offersAlbum, offersArtist: offersArtist) }
    }

    private var secondLine: String? {
        var parts: [String] = []
        if showsArtist, let artist = info.artistName { parts.append(artist) }
        if showsAlbum, let album = info.albumTitle { parts.append(album) }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}
