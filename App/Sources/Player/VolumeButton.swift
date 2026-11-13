import AppKit
import MiniAmpKit
import SwiftUI

/// The player bar's volume: a speaker that shows the level; click it for the slider, or
/// scroll over it. It sets miniamp's own volume (`Player.appVolume`), not the device's,
/// which is in the output panel.
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
            MainActor.assumeIsolated {
                if step != 0 { player.appVolume += step }
            }
            return nil
        }
    }

    private func stopWatchingScrolling() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    private var content: some View {
        let volume = player.appVolume
        return Button { showsSlider.toggle() } label: {
            Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                  variableValue: Double(volume))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .foregroundStyle(.secondary)
        .disabled(player.isSendingDoP)
        .help(player.isSendingDoP ? Self.dopHelp : volume >= 1
              ? "Volume: 100%. Scroll or press ⌘↑ ⌘↓ to change it; ⌥⌘↓ mutes."
              : "Volume: \(percent(volume)). Scroll or press ⌘↑ ⌘↓ to change it; ⌥⌘↓ mutes. Below 100% playback isn't bit-perfect; the device's own volume is in the output menu.")
        .accessibilityLabel("Volume")
        .accessibilityValue(percent(volume))
        .popover(isPresented: $showsSlider, arrowEdge: .top) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary).imageScale(.small)
                Slider(value: Binding(get: { Double(player.appVolume) }, set: { player.appVolume = Float($0) }), in: 0...1)
                    .controlSize(.small)
                    .frame(width: 140)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).imageScale(.small)
                Text(percent(player.appVolume))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(12)
        }
    }

    private func percent(_ volume: Float) -> String { "\(Int((volume * 100).rounded()))%" }

    static let dopHelp = "Volume: the DAC's. DSD goes to it as DoP, which miniamp can't scale without turning it into noise."
}

extension Player {
    /// DSD is going to the DAC as DoP, so the app volume doesn't apply.
    var isSendingDoP: Bool { signalPath?.dsd?.isDoP == true }
}
