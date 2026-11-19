import MiniAmpKit
import SwiftUI

/// The spectrum visualizer filling the library area, on the playing song's cover like the
/// full-size lyrics, the song named in the toolbar.
struct FullVisualizerView: View {
    let app: AppState
    let url: URL
    @State private var entry: QueueEntry?

    var body: some View {
        let entry = entry?.url == url ? entry : nil
        // As much of the page as there is: the bars stretch to the height, and more of
        // them fit the width.
        SpectrumView(player: app.player)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.floatingPanel, style: .continuous))
            .elevation(.panel)
            .overlay {
                Group {
                    if app.player.isSendingDoP {
                        Text("The visualizer is off while DSD goes to the DAC as DoP")
                    } else if app.player.state == .paused {
                        Text("Paused")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.2), value: app.player.state == .paused)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A panel among panels: as far from the sidebar, Up Next, the toolbar and the player
            // bar as they are from the window's edges.
            .padding(.horizontal, Theme.Spacing.s)
            .clearsUpNext()
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.s + app.playerBarInset)
        .background { CoverWash(app: app, entry: entry) }
        .environment(\.colorScheme, .dark)
        .fullViewToolbar(close: { app.toggleVisualizer() }) {
            FullViewHeading(app: app, entry: entry ?? QueueEntry(fileName: url))
        }
        .modifier(FullViewEntry(app: app, url: url, entry: $entry))
    }
}
