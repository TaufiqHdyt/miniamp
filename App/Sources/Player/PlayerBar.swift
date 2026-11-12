import MiniAmpKit
import SwiftUI

/// The strip along the bottom of the window, in three parts: what's playing on the left,
/// transport and position in the middle (centred on the window), and quality, Now Playing,
/// sleep timer, volume and output device on the right.
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
                NowPlayingToggle(app: app)
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

/// Opens and closes the Now Playing inspector (the cover, Up Next, and lyrics).
private struct NowPlayingToggle: View {
    @Bindable var app: AppState

    var body: some View {
        Toggle(isOn: $app.showsNowPlaying) {
            Label("Now Playing", systemImage: "music.note.list")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .imageScale(.large)
        .help(app.showsNowPlaying ? "Hide the cover and what plays next (⌥⌘I)" : "Show the cover and what plays next (⌥⌘I)")
    }
}

/// The quality label, and any problem setting up the device.
private struct SignalSummary: View {
    let player: Player

    var body: some View {
        if let path = player.signalPath {
            QualityBadge(path: path, iconOnly: true)
        }
        if let warning = player.deviceWarning {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(warning)
        }
    }
}
