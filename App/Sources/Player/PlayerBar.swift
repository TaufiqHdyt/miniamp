import MiniAmpKit
import SwiftUI

/// The strip along the bottom of the window, in three parts: what's playing on the left,
/// transport and position in the middle (centred on the window), and on the right the
/// quality, Up Next, Lyrics, volume, output device, and a menu with the visualizer and sleep
/// timer (whose moon shows beside it while it runs). On macOS 26 and later it's a glass
/// panel inset from the window's edges, tinted with the cover.
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
                // While the next song loads, its length, from its tags.
                SeekBar(player: player, loadingDurationMs: current?.url == app.currentURL ? current?.durationMs : nil)
            }
            .frame(minWidth: 300, idealWidth: 520, maxWidth: 560)
            // Sized first, so the two sides split what's left equally and the middle stays centred.
            .layoutPriority(1)

            HStack(spacing: 12) {
                SignalSummary(player: player)
                PaneButton(app: app, pane: .upNext)
                PaneButton(app: app, pane: .lyrics)
                VolumeButton(player: player)
                OutputButton(player: player)
                if app.sleepTimer.isActive { SleepTimerButton(timer: app.sleepTimer) }
                MoreMenu(app: app)
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(PlayerBarBackground(tint: app.tint))
        // Re-read when the track changes, or when the library does (a retagged file).
        .task(id: CurrentKey(url: app.currentURL, revision: app.library?.revision ?? 0)) {
            guard let url = app.currentURL else {
                current = nil
                app.artworkTint = nil
                app.artworkBrightness = nil
                return
            }
            // Up Next has the next song's tags already: straight to them, rather than the file's
            // name for a moment while the library is read.
            if current?.url != url, let known = app.upNextEntries[url] { current = known }
            let loaded = await QueueEntry.load([url], from: app.library)[url]
            guard !Task.isCancelled else { return }
            current = loaded ?? (current?.url == url ? current : QueueEntry(fileName: url))
            guard let entry = current, entry.url == url else { return }
            let colours = await ArtworkImages.shared.colours(key: entry.artworkKey, fileURL: entry.inLibrary ? nil : url,
                                                             in: app.library?.artwork)
            if !Task.isCancelled {
                app.artworkTint = colours?.tint
                app.artworkBrightness = colours?.brightness
            }
        }
    }

    private struct CurrentKey: Equatable {
        var url: URL?
        var revision: Int
    }
}

/// Cover, then title over artist, all left-aligned. The cover opens and closes the inspector.
private struct NowPlayingSummary: View {
    let entry: QueueEntry?
    let artwork: ArtworkCache?
    let app: AppState

    var body: some View {
        HStack(spacing: 12) {
            Button { app.toggleUpNext() } label: {
                ArtworkView(key: entry?.artworkKey, artwork: artwork,
                            fileURL: entry?.inLibrary == false ? entry?.url : nil, size: .small, cornerRadius: Theme.Radius.small)
                    .frame(width: 52, height: 52)
                    .elevation(.hairline)
            }
            .buttonStyle(.plain)
            .help(app.showsNowPlaying ? "Hide Up Next" : "Show Up Next")

            VStack(alignment: .leading, spacing: 3) {
                if let entry, let album = entry.albumId {
                    Button(entry.title) { app.show(.album(album)) }
                        .buttonStyle(BarLinkStyle())
                        .fontWeight(.semibold)
                        .help("Go to \(entry.album ?? "the album")")
                } else {
                    Text(entry?.title ?? "Not Playing")
                        .fontWeight(.semibold)
                        .foregroundStyle(entry == nil ? .secondary : .primary)
                }
                if let artist = entry?.artist, !artist.isEmpty {
                    if let credit = entry?.artistId {
                        Button(artist) { app.showArtist(credit: credit) }
                            .buttonStyle(BarLinkStyle(secondary: true))
                            .font(.callout)
                            .help("Go to \(artist)")
                    } else {
                        Text(artist).font(.callout).foregroundStyle(.secondary)
                    }
                } else if entry == nil {
                    Text("Double-click a song to play it").font(.callout).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
}

/// Text that opens a page: underlined while the pointer is on it, as links in Apple Music.
private struct BarLinkStyle: ButtonStyle {
    var secondary = false

    func makeBody(configuration: Configuration) -> some View {
        BarLink(label: configuration.label, secondary: secondary, pressed: configuration.isPressed)
    }

    private struct BarLink<Label: View>: View {
        let label: Label
        let secondary: Bool
        let pressed: Bool
        @State private var hovering = false

        var body: some View {
            label
                .foregroundStyle(secondary ? .secondary : .primary)
                .underline(hovering)
                .opacity(pressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}

struct TransportButtons: View {
    /// Previous, play and next in the text's own colour: borderless buttons draw their symbols
    /// in a dimmed, vibrant tone on the glass, which read as disabled beside the song's title.
    /// (Shuffle and repeat keep theirs: dim is how they say they're off.)
    static let transportColour = Color.primary

    let app: AppState
    /// Clicks, each bouncing its arrows as in Apple Music.
    @State private var previousClicks = 0
    @State private var nextClicks = 0

    var body: some View {
        let player = app.player
        HStack(spacing: 18) {
            Toggle(isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) })) {
                Image(systemName: "shuffle")
                    .symbolEffect(.bounce, value: player.isShuffled)
            }
            .toggleStyle(.button)
            .help(player.isShuffled ? "Shuffle is on (⌥⌘S)" : "Shuffle is off (⌥⌘S)")
            .accessibilityLabel("Shuffle")
            Button {
                previousClicks += 1
                app.perform { try await player.previous() }
            } label: {
                Image(systemName: "backward.fill").symbolEffect(.bounce.down, value: previousClicks)
                    .foregroundStyle(Self.transportColour)
            }
            .help("Previous (⌘←)")
            .disabled(player.queue.isEmpty)
            Button { app.perform { try await player.togglePlayPause() } } label: {
                // Pause while the next song loads too: it's about to play.
                Image(systemName: player.state == .playing || player.state == .preparing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Self.transportColour)
                    .font(.title2)
                    .frame(width: 24)
            }
            .help(player.state == .playing ? "Pause (Space)" : "Play (Space)")
            .disabled(player.queue.isEmpty)
            Button {
                nextClicks += 1
                app.perform { try await player.next() }
            } label: {
                Image(systemName: "forward.fill").symbolEffect(.bounce.down, value: nextClicks)
                    .foregroundStyle(Self.transportColour)
            }
            .help("Next (⌘→)")
            .disabled(player.queue.isEmpty)
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
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: mode != .off)
        }
        .toggleStyle(.button)
        .help("\(mode.help) (⌥⌘R)")
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

/// Up Next (the inspector) or Lyrics (filling the library area, as the visualizer does), lit
/// while showing; again closes it.
private struct PaneButton: View {
    enum Pane { case upNext, lyrics }

    let app: AppState
    let pane: Pane

    var body: some View {
        let (name, symbol, key) = switch pane {
        case .upNext: ("Up Next", "list.bullet", "⌥⌘I")
        case .lyrics: ("Lyrics", "quote.bubble", "⌥⌘L")
        }
        let showing = pane == .upNext ? app.showsNowPlaying : app.showsFullLyrics
        Toggle(isOn: Binding(get: { showing }, set: { _ in pane == .upNext ? app.toggleUpNext() : app.toggleFullLyrics() })) {
            Label(name, systemImage: symbol)
                .symbolEffect(.bounce, value: showing)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .imageScale(.large)
        // Lyrics are the playing song's.
        .disabled(pane == .lyrics && !showing && app.currentURL == nil)
        .help("\(showing ? "Hide" : "Show") \(name) (\(key))")
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

/// What doesn't need a button of its own: the full-size visualizer and the sleep timer.
private struct MoreMenu: View {
    let app: AppState

    var body: some View {
        Menu {
            Toggle("Visualizer", isOn: Binding(get: { app.showsVisualizer }, set: { _ in app.toggleVisualizer() }))
                .disabled(!app.showsVisualizer && app.currentURL == nil)
            Menu("Sleep Timer") { SleepTimerChoices(timer: app.sleepTimer) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .imageScale(.large)
        .fixedSize()
        .help("Visualizer (⇧⌥⌘V) and sleep timer")
        .accessibilityLabel("More")
    }
}

/// The bar's background: on macOS 26 and later a glass panel inset from the window's edges,
/// tinted with the cover; before that, the bar material across the window with the tint
/// fading from the left.
private struct PlayerBarBackground: ViewModifier {
    let tint: Color?
    private let shape = RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.tint(tint?.opacity(Theme.Tint.playerBar.leading)), in: shape)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.s)
                .animation(.easeInOut(duration: 0.6), value: tint)
        } else {
            content.background {
                ZStack {
                    Rectangle().fill(.bar)
                    if let tint {
                        LinearGradient(colors: [tint.opacity(Theme.Tint.playerBar.leading), tint.opacity(Theme.Tint.playerBar.trailing)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                }
                .animation(.easeInOut(duration: 0.6), value: tint)
            }
        }
    }
}
