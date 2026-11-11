import MiniAmpKit
import SwiftUI
import UniformTypeIdentifiers

/// M2 test bench: queue playback, seeking, output device, hog mode, and device volume.
/// The real interface arrives in M4.
struct ContentView: View {
    @State private var player = Player()
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TransportBar(player: player, importing: $importing, error: $error)
            SeekBar(player: player)

            if let path = player.signalPath {
                SignalPathView(path: path)
            } else {
                Text("Open FLAC, MP3, ALAC, or AAC files. Select several to queue them.")
                    .foregroundStyle(.secondary)
            }
            if let warning = player.deviceWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }

            QueueList(player: player, error: $error)
            Divider()
            OutputControls(player: player)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): run($error) { try await player.setQueue(urls) }
            case .failure(let e): error = e.localizedDescription
            }
        }
        .task { autoplayIfRequested() }
    }

    /// Debug hook for automated checks: `miniamp -autoplay /path/in/container/file.flac [-hog YES]`.
    private func autoplayIfRequested() {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "autoplay") {
            player.hogMode = UserDefaults.standard.bool(forKey: "hog")
            run($error) { try await player.setQueue([URL(fileURLWithPath: path)]) }
        }
        #endif
    }
}

/// Runs a player action and shows any error it throws.
@MainActor
private func run(_ error: Binding<String?>, _ action: @escaping @MainActor () async throws -> Void) {
    error.wrappedValue = nil
    Task {
        do { try await action() } catch let e { error.wrappedValue = "\(e)" }
    }
}

private struct TransportBar: View {
    let player: Player
    @Binding var importing: Bool
    @Binding var error: String?

    var body: some View {
        HStack(spacing: 10) {
            Button("Open…") { importing = true }
                .keyboardShortcut("o")
            Divider().frame(height: 18)
            Button { run($error) { try await player.previous() } } label: { Image(systemName: "backward.fill") }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { run($error) { try await player.togglePlayPause() } } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { run($error) { try await player.next() } } label: { Image(systemName: "forward.fill") }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button { player.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(player.state == .stopped)
            Divider().frame(height: 18)
            Toggle(isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) })) {
                Image(systemName: "shuffle")
            }
            .toggleStyle(.button)
            RepeatButton(player: player)
            Spacer()
            Text(stateLabel).foregroundStyle(.secondary)
        }
    }

    private var stateLabel: String {
        switch player.state {
        case .stopped: "Stopped"
        case .preparing: "Preparing device…"
        case .playing: "Playing"
        case .paused: "Paused"
        }
    }
}

/// One button that cycles off → all → one, lit only while repeat is on (like the shuffle toggle).
private struct RepeatButton: View {
    let player: Player

    var body: some View {
        let mode = player.repeatMode
        Toggle(isOn: Binding(get: { mode != .off }, set: { _ in player.repeatMode = mode.next })) {
            Image(systemName: mode == .one ? "repeat.1" : "repeat")
        }
        .toggleStyle(.button)
        .help(help(mode))
        .accessibilityLabel("Repeat")
        .accessibilityValue(mode == .off ? "Off" : mode == .all ? "All" : "One")
    }

    private func help(_ mode: PlayQueue<URL>.Repeat) -> String {
        switch mode {
        case .off: "Repeat is off. Click to repeat all."
        case .all: "Repeating all. Click to repeat one."
        case .one: "Repeating one. Click to turn repeat off."
        }
    }
}

private extension PlayQueue<URL>.Repeat {
    var next: Self {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

private struct SeekBar: View {
    let player: Player
    /// Slider value while dragging; nil follows the player.
    @State private var scrub: Double?

    var body: some View {
        let total = max(player.duration.seconds, 0.001)
        HStack {
            Text(format(scrub ?? player.position.seconds)).monospacedDigit()
            Slider(value: Binding(get: { scrub ?? player.position.seconds }, set: { scrub = $0 }),
                   in: 0...total) { editing in
                if !editing, let scrub {
                    player.seek(to: .seconds(scrub))
                    self.scrub = nil
                }
            }
            .disabled(player.state != .playing && player.state != .paused)
            Text(format(player.duration.seconds)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct QueueList: View {
    let player: Player
    @Binding var error: String?

    var body: some View {
        List {
            ForEach(Array(player.queue.order.enumerated()), id: \.offset) { position, item in
                let isCurrent = position == player.queue.position
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .opacity(isCurrent ? 1 : 0)
                        .foregroundStyle(.tint)
                    Text(player.queue.items[item].deletingPathExtension().lastPathComponent)
                        .fontWeight(isCurrent ? .semibold : .regular)
                    Spacer()
                    Text(player.queue.items[item].pathExtension.uppercased())
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { run($error) { try await player.jump(toItem: item) } }
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 140)
    }
}

private struct OutputControls: View {
    @Bindable var player: Player

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Output").foregroundStyle(.secondary)
                Picker("Output", selection: $player.preferredDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(player.availableDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            GridRow {
                Text("Exclusive").foregroundStyle(.secondary)
                Toggle("Hog mode (other apps can't use the device while playing)", isOn: $player.hogMode)
            }
            GridRow {
                Text("Volume").foregroundStyle(.secondary)
                if let volume = player.volume {
                    HStack {
                        Slider(value: Binding(get: { Double(volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                            .frame(maxWidth: 280)
                        Text("\(Int((volume * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                } else {
                    Text("This device has no volume control. Use its own knob.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SignalPathView: View {
    let path: SignalPath

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("File").foregroundStyle(.secondary)
                Text(path.fileDescription).monospaced()
            }
            GridRow {
                Text("Device").foregroundStyle(.secondary)
                Text(path.deviceDescription).monospaced()
            }
            GridRow {
                Text("Format").foregroundStyle(.secondary)
                Text(path.devicePhysicalFormat).monospaced()
            }
            GridRow {
                Text("Path").foregroundStyle(.secondary)
                if path.isResampled {
                    Label("Resampled \(FormatSelection.formatRate(path.fileSampleRate)) → \(FormatSelection.formatRate(path.deviceSampleRate))",
                          systemImage: "waveform.badge.exclamationmark")
                        .foregroundStyle(.orange)
                } else {
                    Label("Native rate, no conversion", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

private extension Duration {
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }
}
