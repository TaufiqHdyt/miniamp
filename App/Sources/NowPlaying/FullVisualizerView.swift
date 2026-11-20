import MiniAmpKit
import SwiftUI

/// The spectrum visualizer mode in Now Playing.
struct FullVisualizerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: AppState

    var body: some View {
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: app.player.state == .paused)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fullViewToolbar(app: app)
    }
}

/// Behind the bars: glass tinted with the cover, as Up Next is beside it (macOS 26 and later);
/// before that, the classic black panel.
private struct SpectrumPanel: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.floatingPanel, style: .continuous)
        if #available(macOS 26, *) {
            content
                .clipShape(shape)
                .glassBackground(in: shape, tint: tint?.opacity(Theme.Tint.inspector.top))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: tint)
        } else {
            content
                .background(Color(nsColor: SpectrumNSView.background), in: shape)
                .clipShape(shape)
                .elevation(.panel)
        }
    }
}
