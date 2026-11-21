import MiniAmpKit
import SwiftUI

/// The visualizer mode in Now Playing.
struct FullVisualizerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("visualizerType") private var type: VisualizerType = .spectrum
    let app: AppState

    var body: some View {
        VisualizerView(type: type, tap: app.player.visualizerTap,
                       isPlaying: app.player.state == .playing, isSendingDoP: app.player.isSendingDoP)
            .accessibilityElement()
            .accessibilityLabel("\(type.title) visualizer")
            .accessibilityAddTraits(.isImage)
            .padding(Theme.Spacing.l)
            .modifier(VisualizerPanel(tint: app.tint))
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
            .fullViewToolbar(app: app) {
                Picker("Visualization Type", selection: $type) {
                    ForEach(VisualizerType.allCases, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Choose a visualization type")
            }
    }
}

/// Behind the visualization: glass tinted with the cover, as Up Next is beside it (macOS 26 and later);
/// before that, the classic black panel.
private struct VisualizerPanel: ViewModifier {
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
                .background(Color(nsColor: SpectrumRenderer.background), in: shape)
                .clipShape(shape)
                .elevation(.panel)
        }
    }
}
