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
            .background(Color(nsColor: SpectrumRenderer.background))
            .environment(\.colorScheme, .dark)
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
