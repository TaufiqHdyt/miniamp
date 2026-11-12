import MiniAmpKit
import SwiftUI

/// The menu bar mini player: the cover, what's playing, the transport, and the position,
/// in a small window under the menu bar icon.
struct MiniPlayer: View {
    let app: AppState
    @State private var current: QueueEntry?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let player = app.player
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(key: current?.artworkKey, artwork: app.library?.artwork,
                            fileURL: current?.inLibrary == false ? current?.url : nil, size: .small, cornerRadius: 6)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.title ?? "Not Playing").fontWeight(.semibold)
                        .foregroundStyle(current == nil ? .secondary : .primary)
                    if let artist = current?.artist, !artist.isEmpty { Text(artist).foregroundStyle(.secondary) }
                    if let album = current?.album, !album.isEmpty { Text(album).font(.callout).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            TransportButtons(app: app)
            SeekBar(player: player)
            AppVolumeControl(player: player, width: 200)
            HStack {
                if let path = player.signalPath { QualityBadge(path: path) }
                Spacer()
                Button("Open miniamp") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
        .background {
            if let tint = app.tint {
                LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom)
            }
        }
        // The position only moves while something shows it (see AppState.miniPlayerOpen).
        .onAppear { app.miniPlayerOpen = true }
        .onDisappear { app.miniPlayerOpen = false }
        .task(id: app.currentURL) {
            guard let url = app.currentURL else { return current = nil }
            if current?.url != url { current = QueueEntry(fileName: url) }
            current = await QueueEntry.load([url], from: app.library)[url] ?? current
        }
    }
}
