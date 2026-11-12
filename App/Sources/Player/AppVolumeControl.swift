import AppKit
import MiniAmpKit
import SwiftUI

/// miniamp's own volume, as in Apple Music: a thin line between a small and a large speaker,
/// with no knob. Hovering thickens it; click or drag anywhere on it to set the level, or
/// scroll over it. It's separate from the device's volume, which is in the output panel.
/// Clicking the small speaker mutes and unmutes.
///
/// At 100% the samples reach the device untouched; below it they're scaled (see Player.appVolume).
struct AppVolumeControl: View {
    let player: Player
    var width: CGFloat = 92
    /// The level to go back to on unmute.
    @State private var beforeMute: Float = 1
    @State private var scrollMonitor: Any?
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let volume = player.appVolume
        let active = hovering || dragging
        HStack(spacing: 7) {
            Image(systemName: volume <= 0 ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: 14, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { toggleMute() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(volume <= 0 ? "Unmute" : "Mute")
                .accessibilityAction { toggleMute() }
            GeometryReader { geometry in
                let length = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: max(length * CGFloat(volume), 0))
                }
                .frame(height: active ? 6 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard length > 0 else { return }
                        dragging = true
                        player.appVolume = Float(min(max(drag.location.x / length, 0), 1))
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(width: width, height: 12)
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue(Self.percent(volume))
            .accessibilityAdjustableAction { direction in
                player.appVolume += direction == .increment ? 0.05 : -0.05
            }
            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 20, alignment: .leading)
                .accessibilityHidden(true)
        }
        .imageScale(.small)
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .animation(.easeOut(duration: 0.15), value: active)
        .help(Self.help(volume))
        .onHover { inside in
            hovering = inside
            inside ? watchScrolling() : stopWatchingScrolling()
        }
        .onDisappear { stopWatchingScrolling() }
    }

    private func toggleMute() {
        if player.appVolume > 0 {
            beforeMute = player.appVolume
            player.appVolume = 0
        } else {
            player.appVolume = beforeMute > 0 ? beforeMute : 1
        }
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
        .help(volume >= 1
              ? "Volume: 100%. Scroll to change it."
              : "Volume: \(percent(volume)). Scroll to change it. Below 100% playback isn't bit-perfect; the device's own volume is in the output menu.")
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
}
