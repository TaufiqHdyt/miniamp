import MiniAmpKit
import SwiftUI

/// Full-window spectrum visualizer over the playing song's colour wash.
struct FullVisualizerView: View {
    let app: AppState
    let url: URL
    @State private var entry: QueueEntry?

    var body: some View {
        let entry = entry?.url == url ? entry : nil
        // As much of the page as there is: the bars stretch to the height, and more of
        // them fit the width.
        SpectrumView(player: app.player)
            .padding(Theme.Spacing.l)
            .modifier(SpectrumPanel(tint: app.tint))
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
            .fullViewToolbar(app: app)
            .modifier(FullViewEntry(app: app, url: url, entry: $entry))
    }
}

/// Behind the bars: glass tinted with the cover, as Up Next is beside it (macOS 26 and later);
/// before that, the classic black panel.
private struct SpectrumPanel: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.floatingPanel, style: .continuous)
        if #available(macOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular.tint(tint?.opacity(Theme.Tint.inspector.top)), in: shape)
                .animation(.easeInOut(duration: 0.6), value: tint)
        } else {
            content
                .background(Color(nsColor: SpectrumNSView.background), in: shape)
                .clipShape(shape)
                .elevation(.panel)
        }
    }
}
