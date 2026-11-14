import MiniAmpKit
import SwiftUI

/// The spectrum visualizer filling the library area, on the playing song's cover like the
/// full-size lyrics, the song named at the top.
struct FullVisualizerView: View {
    let app: AppState
    let url: URL
    @State private var entry: QueueEntry?

    var body: some View {
        let entry = entry?.url == url ? entry : nil
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                FullViewHeading(app: app, entry: entry ?? QueueEntry(fileName: url))
                Spacer()
                Button { app.showsVisualizer = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Back to the library (Esc)")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            SpectrumView(player: app.player)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
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
                .frame(maxHeight: 520)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .padding(.top, 28)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { CoverWash(app: app, entry: entry) }
        .environment(\.colorScheme, .dark)
        // The wash runs up under the toolbar, as in Apple Music, rather than stopping at a grey bar.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(FullViewEntry(app: app, url: url, entry: $entry))
    }
}
