import MiniAmpKit
import SwiftUI

/// Now Playing: a full view (lyrics or the visualizer) with the playing song's cover, large, in
/// a column at its leading side, its title, artist and album under it. The player bar below
/// keeps the controls. In a narrow window (or with Up Next taking the room) the column goes,
/// and the full view has the page to itself.
struct NowPlayingLayout<Content: View>: View {
    let app: AppState
    let entry: QueueEntry?
    @ViewBuilder let content: Content
    @Environment(\.upNextRoom) private var upNextRoom
    @State private var width: CGFloat = 0

    /// The width the page needs, besides Up Next, to have room for the column beside lyrics.
    static var minimumWidth: CGFloat { 780 }

    var body: some View {
        let showsColumn = width - upNextRoom >= Self.minimumWidth
        HStack(spacing: 0) {
            if showsColumn {
                NowPlayingColumn(app: app, entry: entry)
                    .frame(width: min(max((width - upNextRoom) * 0.36, 260), 440))
                    .padding(.leading, Theme.Spacing.xl)
                    .padding(.trailing, Theme.Spacing.l)
                    .padding(.bottom, app.playerBarInset)
            }
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The cover, as big as the column (or the height) allows, the song named under it; the
/// title opens its album, the artist their page, as in the player bar.
private struct NowPlayingColumn: View {
    let app: AppState
    let entry: QueueEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            ArtworkView(key: entry?.artworkKey, artwork: app.library?.artwork,
                        fileURL: entry?.inLibrary == false ? entry?.url : nil, size: .large,
                        cornerRadius: Theme.Radius.large)
                .aspectRatio(1, contentMode: .fit)
                .elevation(.floating)
                .accessibilityLabel(entry.map { "Cover of \($0.album ?? $0.title)" } ?? "Cover")
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                link(entry?.title ?? "", help: "Go to \(entry?.album ?? "the album")",
                     action: entry?.albumId.map { album in { app.show(.album(album)) } })
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                if let artist = entry?.artist, !artist.isEmpty {
                    link(artist, secondary: true, help: "Go to \(artist)",
                         action: entry?.artistId.map { credit in { app.showArtist(credit: credit) } })
                        .font(.title3)
                        .lineLimit(1)
                }
                if let album = entry?.album, !album.isEmpty {
                    link(album, secondary: true, help: "Go to \(album)",
                         action: entry?.albumId.map { id in { app.show(.album(id)) } })
                        .font(.body)
                        .lineLimit(1)
                }
            }
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.3), value: entry?.url)
    }

    /// Text that opens a page when there is one, plain text when not (a file outside the library).
    @ViewBuilder
    private func link(_ text: String, secondary: Bool = false, help: String, action: (() -> Void)?) -> some View {
        if let action {
            Button(text, action: action)
                .buttonStyle(BarLinkStyle(secondary: secondary))
                .help(help)
        } else {
            Text(text).foregroundStyle(secondary ? .secondary : .primary)
        }
    }
}
