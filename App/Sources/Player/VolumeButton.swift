import AppKit
import MiniAmpKit
import SwiftUI

/// A speaker that shows the level; click it for the slider.
struct VolumeButton: View {
    let player: Player
    @State private var showsSlider = false
    @State private var scrollMonitor: Any?

    var body: some View {
        content
            .onHover { inside in inside ? watchScrolling() : stopWatchingScrolling() }
            .onDisappear { stopWatchingScrolling() }
    }

    /// While the pointer is over the speaker, the scroll wheel or a two-finger swipe sets the
    /// volume: up is louder, whichever way the system scrolls.
    private func watchScrolling() {
        guard scrollMonitor == nil else { return }
        let player = player
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            var delta = event.scrollingDeltaY
            if event.isDirectionInvertedFromDevice { delta = -delta }
            // A trackpad reports points; a mouse wheel reports lines.
            let step = Float(event.hasPreciseScrollingDeltas ? delta / 300 : delta * 0.03)
            let handled = MainActor.assumeIsolated {
                guard let volume = player.volume else { return false }
                if step != 0 { player.setVolume(min(max(volume + step, 0), 1)) }
                return true
            }
            return handled ? nil : event
        }
    }

    private func stopWatchingScrolling() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    @ViewBuilder private var content: some View {
        if let volume = player.volume {
            Button { showsSlider.toggle() } label: {
                Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: Double(volume))
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
            .foregroundStyle(.secondary)
            .help("Volume: \(percent(volume)). Scroll to change it.")
            .accessibilityLabel("Volume")
            .accessibilityValue(percent(volume))
            .popover(isPresented: $showsSlider, arrowEdge: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).imageScale(.small)
                    Slider(value: Binding(get: { Double(volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                        .controlSize(.small)
                        .frame(width: 140)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).imageScale(.small)
                    Text(percent(volume))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(12)
            }
        } else {
            Image(systemName: "speaker.slash")
                .imageScale(.large)
                .frame(width: 22)
                .foregroundStyle(.tertiary)
                .help("\(player.outputDevice?.name ?? "This device") has no volume control. Use its own knob.")
        }
    }

    private func percent(_ volume: Float) -> String { "\(Int((volume * 100).rounded()))%" }
}
