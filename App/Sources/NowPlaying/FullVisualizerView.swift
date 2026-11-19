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
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
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
            .padding(.horizontal, 32)
            .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.l + app.playerBarInset)
        .background { CoverWash(app: app, entry: entry) }
        .environment(\.colorScheme, .dark)
        .fullViewToolbar(close: { app.showsVisualizer = false }) {
            FullViewHeading(app: app, entry: entry ?? QueueEntry(fileName: url))
        }
        .modifier(FullViewEntry(app: app, url: url, entry: $entry))
    }
}
