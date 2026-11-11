import MiniAmpKit
import SwiftUI
import UniformTypeIdentifiers

/// Test bench: the library (M3) beside queue playback, seeking, output device, hog mode, and
/// device volume (M2). The real interface arrives in M4.
struct ContentView: View {
    let library: Library?
    @State private var player = Player()
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        HSplitView {
            if let library {
                LibraryPanel(library: library, player: player, error: $error)
                    .padding(20)
            }
            playerPanel
        }
        .frame(minWidth: library == nil ? 620 : 1040, minHeight: 560)
        .task {
            await library?.open()
            #if DEBUG
            // Debug hook for automated checks: `miniamp -libraryFolder /path/in/container`.
            if let path = UserDefaults.standard.string(forKey: "libraryFolder") {
                do { try await library?.addFolder(URL(fileURLWithPath: path, isDirectory: true)) } catch let e { error = "\(e)" }
            }
            #endif
        }
    }

    private var playerPanel: some View {
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

            QueueList(player: player, library: library, error: $error)
            Divider()
            OutputControls(player: player)
        }
        .padding(20)
        .frame(minWidth: 600)
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
    let library: Library?
    @Binding var error: String?
    @State private var entries: [URL: QueueEntry] = [:]

    var body: some View {
        List {
            ForEach(Array(player.queue.order.enumerated()), id: \.offset) { position, item in
                let isCurrent = position == player.queue.position
                let url = player.queue.items[item]
                let entry = entries[url] ?? QueueEntry(fileName: url)
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .opacity(isCurrent ? 1 : 0)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .lineLimit(1)
                        if let subtitle = entry.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(entry.format)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .monospaced()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { run($error) { try await player.jump(toItem: item) } }
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 140)
        // Re-read when the queue changes, or when the library does (a retagged file).
        .task(id: QueueKey(items: player.queue.items, revision: library?.revision ?? 0)) {
            entries = await QueueEntry.load(player.queue.items, from: library)
        }
    }

    private struct QueueKey: Equatable {
        var items: [URL]
        var revision: Int
    }
}

/// What the queue shows for a file: its tags from the library, or read from the file itself
/// when it isn't in the library (opened with Open…), or its name until either is known.
private struct QueueEntry {
    var title: String
    var subtitle: String?
    var format: String

    init(fileName url: URL) {
        title = url.deletingPathExtension().lastPathComponent
        format = url.pathExtension.uppercased()
    }

    init(_ info: TrackInfo) {
        title = info.track.title
        subtitle = Self.subtitle(artist: info.artistName, album: info.albumTitle)
        format = Self.format(codec: info.track.codec, sampleRate: info.track.sampleRate, bits: info.track.bitsPerSample)
    }

    init(_ tags: TrackTags, url: URL) {
        self.init(fileName: url)
        if let title = tags.title, !title.isEmpty { self.title = title }
        subtitle = Self.subtitle(artist: tags.artist, album: tags.album)
        format = Self.format(codec: tags.codec.isEmpty ? format : tags.codec, sampleRate: tags.sampleRate, bits: tags.bitsPerSample)
    }

    static func subtitle(artist: String?, album: String?) -> String? {
        let parts = [artist, album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    static func format(codec: String, sampleRate: Int, bits: Int?) -> String {
        guard sampleRate > 0 else { return codec }
        return "\(codec) \(FormatSelection.formatRate(Double(sampleRate)))\(bits.map { "/\($0)" } ?? "")"
    }

    static func load(_ urls: [URL], from library: Library?) async -> [URL: QueueEntry] {
        var entries: [URL: QueueEntry] = [:]
        if let library, let found = try? await library.tracks(at: urls) {
            for (url, info) in found { entries[url] = QueueEntry(info) }
        }
        let rest = urls.filter { entries[$0] == nil }
        guard !rest.isEmpty, !Task.isCancelled else { return entries }
        // Not in the library: read the tags off the main actor.
        let read = await Task.detached(priority: .userInitiated) {
            rest.compactMap { url in TagReader.read(url).map { (url, $0) } }
        }.value
        for (url, tags) in read { entries[url] = QueueEntry(tags, url: url) }
        return entries
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
