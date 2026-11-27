import SwiftUI

/// Lyrics and the visualizer fill the main pane above the player bar.
struct FullPlayingView: View {
    let app: AppState
    let url: URL
    let mode: FullView

    var body: some View {
        Group {
            switch mode {
            case .lyrics: LyricsView(app: app, url: url).id(url)
            case .upNext: EmptyView()
            case .visualizer: FullVisualizerView(app: app)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func fullViewToolbar<Controls: View>(app: AppState, @ViewBuilder controls: () -> Controls) -> some View {
        let controls = controls()
        return toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { app.showFullView(nil) } label: {
                        Label("Back to Library", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.cancelAction)
                    .focusable(false)
                    .help("Back to the library (Esc)")
                }
                .withoutSharedBackground()
                ToolbarItem(placement: .principal) {
                    Picker("Now Playing Mode", selection: Binding(
                        get: { app.fullView ?? .lyrics },
                        set: { app.showFullView($0) }
                    )) {
                        Text(FullView.lyrics.label).tag(FullView.lyrics)
                        Text(FullView.visualizer.label).tag(FullView.visualizer)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .focusable(false)
                    .fixedSize()
                }
                .withoutSharedBackground()
                ToolbarItemGroup(placement: .primaryAction) { controls }
                    .withoutSharedBackground()
            }
    }
}
