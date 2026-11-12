import AppKit
import MiniAmpKit
import SwiftUI

/// miniamp's own volume, as in Apple Music: a slider between a quiet and a loud speaker,
/// separate from the device's volume (that one is in the output panel). Click the quiet
/// speaker to mute and unmute; scroll over the control to change the level.
///
/// At 100% the samples reach the device untouched; below it they're scaled (see Player.appVolume).
struct AppVolumeControl: View {
    let player: Player
    /// The level to go back to on unmute.
    @State private var beforeMute: Float = 1
    @State private var scrollMonitor: Any?

    var body: some View {
        let volume = player.appVolume
        HStack(spacing: 6) {
            Button {
                if volume > 0 {
                    beforeMute = volume
                    player.appVolume = 0
                } else {
                    player.appVolume = beforeMute > 0 ? beforeMute : 1
                }
            } label: {
                Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(volume <= 0 ? "Unmute" : "Mute")
            .accessibilityLabel(volume <= 0 ? "Unmute" : "Mute")

            Slider(value: Binding(get: { Double(player.appVolume) }, set: { player.appVolume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 90)
                .accessibilityLabel("Volume")
                .accessibilityValue(Self.percent(volume))

            Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
        }
        .imageScale(.small)
        .foregroundStyle(.secondary)
        .help(Self.help(volume))
        .onHover { inside in inside ? watchScrolling() : stopWatchingScrolling() }
        .onDisappear { stopWatchingScrolling() }
    }

    static func percent(_ volume: Float) -> String { "\(Int((volume * 100).rounded()))%" }

    private static func help(_ volume: Float) -> String {
        volume >= 1
            ? "Volume: 100%. Scroll to change it. At 100%, playback stays bit-perfect."
            : "Volume: \(percent(volume)). Scroll to change it. Below 100% the samples are scaled; turn the device down instead (in the output menu) to stay bit-perfect."
    }

    /// While the pointer is over the control, the scroll wheel or a two-finger swipe sets the
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
}
