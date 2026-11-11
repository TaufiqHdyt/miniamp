import AppKit
import MiniAmpKit
import SwiftUI

/// The strip along the bottom of the window, in three parts: what's playing on the left,
/// transport and position in the middle (centred on the window), and quality, sleep timer,
/// volume and output device on the right.
struct PlayerBar: View {
    let app: AppState
    @State private var current: QueueEntry?

    var body: some View {
        let player = app.player
        HStack(spacing: 16) {
            NowPlayingSummary(entry: current, artwork: app.library?.artwork, app: app)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                TransportButtons(app: app)
                SeekBar(player: player)
            }
            .frame(minWidth: 300, idealWidth: 520, maxWidth: 560)
            // Sized first, so the two sides split what's left equally and the middle stays centred.
            .layoutPriority(1)

            HStack(spacing: 12) {
                SignalSummary(player: player)
                SleepTimerButton(timer: app.sleepTimer)
                VolumeButton(player: player)
                OutputButton(player: player)
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        // Re-read when the track changes, or when the library does (a retagged file).
        .task(id: CurrentKey(url: app.currentURL, revision: app.library?.revision ?? 0)) {
            guard let url = app.currentURL else { return current = nil }
            if current?.url != url { current = QueueEntry(fileName: url) }
            current = await QueueEntry.load([url], from: app.library)[url] ?? current
        }
    }

    private struct CurrentKey: Equatable {
        var url: URL?
        var revision: Int
    }
}

/// Cover, then title over artist, all left-aligned. The cover opens and closes Now Playing.
private struct NowPlayingSummary: View {
    let entry: QueueEntry?
    let artwork: ArtworkCache?
    let app: AppState

    var body: some View {
        HStack(spacing: 12) {
            Button { app.showsNowPlaying.toggle() } label: {
                ArtworkView(key: entry?.artworkKey, artwork: artwork,
                            fileURL: entry?.inLibrary == false ? entry?.url : nil, size: .small, cornerRadius: 4)
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            }
            .buttonStyle(.plain)
            .help(app.showsNowPlaying ? "Hide Now Playing" : "Show Now Playing")

            VStack(alignment: .leading, spacing: 3) {
                Text(entry?.title ?? "Not Playing")
                    .fontWeight(.semibold)
                    .foregroundStyle(entry == nil ? .secondary : .primary)
                if let artist = entry?.artist, !artist.isEmpty {
                    Text(artist).font(.callout).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .help(entry.map { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: "\n") } ?? "")
        }
    }
}

struct TransportButtons: View {
    let app: AppState

    var body: some View {
        let player = app.player
        HStack(spacing: 18) {
            Toggle(isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) })) {
                Image(systemName: "shuffle")
            }
            .toggleStyle(.button)
            .help("Shuffle")
            Button { app.perform { try await player.previous() } } label: { Image(systemName: "backward.fill") }
                .help("Previous")
            Button { app.perform { try await player.togglePlayPause() } } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 24)
            }
            .help(player.state == .playing ? "Pause" : "Play")
            .disabled(player.queue.isEmpty)
            Button { app.perform { try await player.next() } } label: { Image(systemName: "forward.fill") }
                .help("Next")
            RepeatButton(player: player)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }
}

/// One button that cycles off → all → one, lit only while repeat is on (like the shuffle toggle).
struct RepeatButton: View {
    let player: Player

    var body: some View {
        let mode = player.repeatMode
        Toggle(isOn: Binding(get: { mode != .off }, set: { _ in player.repeatMode = mode.next })) {
            Image(systemName: mode == .one ? "repeat.1" : "repeat")
        }
        .toggleStyle(.button)
        .help(mode.help)
        .accessibilityLabel("Repeat")
        .accessibilityValue(mode.label)
    }
}

extension PlayQueue<URL>.Repeat {
    var next: Self {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    var help: String {
        switch self {
        case .off: "Repeat is off. Click to repeat all."
        case .all: "Repeating all. Click to repeat one."
        case .one: "Repeating one. Click to turn repeat off."
        }
    }
}

/// A thin progress line, as in Apple Music. Hovering thickens it and shows the elapsed time
/// and the length on either side; click or drag anywhere on it to seek.
///
/// The only view that reads `player.position`, so a position change re-renders just this.
struct SeekBar: View {
    let player: Player
    /// Where a drag is, 0...1; nil follows the player.
    @State private var scrub: Double?
    @State private var hovering = false

    var body: some View {
        let total = player.duration.seconds
        let active = (player.state == .playing || player.state == .paused) && total > 0
        let fraction = active ? scrub ?? min(max(player.position.seconds / total, 0), 1) : 0
        let showsTimes = active && (hovering || scrub != nil)
        HStack(spacing: 8) {
            TimeLabel(seconds: active ? fraction * total : nil, alignment: .trailing)
                .opacity(showsTimes ? 1 : 0)
            GeometryReader { geometry in
                let width = geometry.size.width
                let thick = active && (hovering || scrub != nil)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(thick ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: max(width * fraction, 0))
                }
                .frame(height: thick ? 6 : 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard active, width > 0 else { return }
                        scrub = min(max(drag.location.x / width, 0), 1)
                    }
                    .onEnded { _ in
                        if let scrub, active { player.seek(to: .seconds(scrub * total)) }
                        scrub = nil
                    })
            }
            .frame(height: 12)
            TimeLabel(seconds: active ? total : nil, alignment: .leading)
                .opacity(showsTimes ? 1 : 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.15), value: showsTimes)
        .onHover { hovering = $0 }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(active ? "\(TimeFormat.minutes(Int(fraction * total))) of \(TimeFormat.minutes(Int(total)))" : "Not playing")
        .accessibilityAdjustableAction { direction in
            guard active else { return }
            let step = direction == .increment ? 10.0 : -10.0
            player.seek(to: .seconds(min(max(player.position.seconds + step, 0), total)))
        }
    }
}

/// Fixed width, so a change of digits doesn't move anything around it.
private struct TimeLabel: View {
    let seconds: Double?
    var alignment: Alignment = .center

    var body: some View {
        Text(seconds.map { TimeFormat.minutes(Int($0.rounded(.down))) } ?? "–:––")
            .monospacedDigit()
            .frame(width: 44, alignment: alignment)
    }
}

/// The quality label, and any problem setting up the device.
private struct SignalSummary: View {
    let player: Player

    var body: some View {
        if let path = player.signalPath {
            QualityBadge(path: path)
        }
        if let warning = player.deviceWarning {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(warning)
        }
    }
}

/// A speaker that shows the level; click it for the slider.
private struct VolumeButton: View {
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

extension Duration {
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}
