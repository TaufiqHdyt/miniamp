import MiniAmpKit
import SwiftUI

struct PlayerBar: View {
    let app: AppState
    @State private var current: QueueEntry?

    var body: some View {
        let player = app.player
        let sideWidth: CGFloat = 218
        HStack(spacing: Theme.Spacing.m) {
            NowPlayingSummary(entry: current, artwork: app.library?.artwork, app: app)
                .frame(minWidth: sideWidth, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                TransportButtons(app: app)
                // While the next song loads, its length, from its tags.
                SeekBar(player: player, loadingDurationMs: current?.url == app.currentURL ? current?.durationMs : nil)
            }
            .frame(minWidth: 270, idealWidth: 490, maxWidth: 560)
            // Sized first, so the two sides split what's left equally and the middle stays centred.
            .layoutPriority(1)

            HStack(spacing: Theme.Spacing.s) {
                if player.signalPath != nil || player.deviceWarning != nil {
                    SignalSummary(player: player)
                    Divider().frame(height: 18)
                }
                HStack(spacing: Theme.Spacing.xxs) {
                    Button { app.run(.queue) } label: {
                        Image(systemName: "list.bullet")
                            .playerBarIcon(active: app.showsUpNext)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel("Queue")
                    .accessibilityAddTraits(app.showsUpNext ? .isSelected : [])
                    .help("Queue (⌘2)")
                    VolumeButton(player: player)
                    if app.sleepTimer.isActive { SleepTimerButton(timer: app.sleepTimer) }
                    MoreMenu(app: app)
                }
                .fixedSize()
            }
            .frame(minWidth: sideWidth, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Re-read when the track changes, or when the library does (a retagged file).
        .task(id: CurrentKey(url: app.currentURL, revision: app.library?.revision ?? 0)) {
            guard let url = app.currentURL else {
                current = nil
                app.artworkTint = nil
                return
            }
            // Up Next has the next song's tags already: straight to them, rather than the file's
            // name for a moment while the library is read.
            if current?.url != url, let known = app.upNextEntries[url] { current = known }
            let loaded = await QueueEntry.load([url], from: app.library)[url]
            guard !Task.isCancelled else { return }
            current = loaded ?? (current?.url == url ? current : QueueEntry(fileName: url))
            guard let entry = current, entry.url == url else { return }
            let tint = await ArtworkImages.shared.tint(key: entry.artworkKey,
                                                       fileURL: entry.inLibrary ? nil : entry.url,
                                                       in: app.library?.artwork)
            if !Task.isCancelled { app.artworkTint = tint }
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
            Button { app.toggleNowPlaying() } label: {
                ArtworkView(key: entry?.artworkKey, artwork: artwork,
                            fileURL: entry?.inLibrary == false ? entry?.url : nil, size: .small, cornerRadius: Theme.Radius.small)
                    .frame(width: 52, height: 52)
                    .elevation(.hairline)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(entry == nil)
            .accessibilityLabel(app.fullView == nil ? "Show Now Playing" : "Back to the Library")
            .help("Now Playing (⌘3)")

            VStack(alignment: .leading, spacing: 3) {
                if let entry, let album = entry.albumId {
                    Button(entry.title) { app.show(.album(album, title: entry.album)) }
                        .buttonStyle(BarLinkStyle())
                        .focusable(false)
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
                            .focusable(false)
                            .font(.callout)
                            .help("Go to \(artist)")
                    } else {
                        Text(artist).font(.callout).foregroundStyle(.secondary)
                    }
                } else if entry == nil {
                    Text("Open files or jump to a song").font(.callout).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
}

/// Text that opens a page: underlined while the pointer is on it, as links in Apple Music.
struct BarLinkStyle: ButtonStyle {
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

private struct TransportButtons: View {
    static let transportColour = Color.primary

    let app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Clicks, each bouncing its arrows as in Apple Music.
    @State private var previousClicks = 0
    @State private var nextClicks = 0

    var body: some View {
        let player = app.player
        HStack(spacing: 18) {
            Toggle(isOn: Binding(get: { player.isShuffled }, set: { player.setShuffle($0) })) {
                Image(systemName: "shuffle")
                    .symbolEffect(.bounce, value: reduceMotion ? false : player.isShuffled)
            }
            .toggleStyle(.button)
            .focusable(false)
            .help(player.isShuffled ? "Shuffle is on (⌥⌘S)" : "Shuffle is off (⌥⌘S)")
            .accessibilityLabel("Shuffle")
            Button {
                if !reduceMotion { previousClicks += 1 }
                app.run(.previous)
            } label: {
                Image(systemName: "backward.fill").symbolEffect(.bounce.down, value: previousClicks)
                    .foregroundStyle(Self.transportColour)
            }
            .focusable(false)
            .accessibilityLabel("Previous Track")
            .help("Previous (\(AppAction.previous.keys(classic: app.winampShortcuts)))")
            .disabled(player.queue.isEmpty)
            Button { app.run(.playPause) } label: {
                // Pause while the next song loads too: it's about to play.
                Image(systemName: player.state == .playing || player.state == .preparing ? "pause.fill" : "play.fill")
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .foregroundStyle(Self.transportColour)
                    .font(.title2)
                    .frame(width: 24)
            }
            .focusable(false)
            .accessibilityLabel(player.state == .playing || player.state == .preparing ? "Pause" : "Play")
            .help(player.state == .playing ? "Pause (Space)" : "Play (Space)")
            .disabled(player.queue.isEmpty)
            Button {
                if !reduceMotion { nextClicks += 1 }
                app.run(.next)
            } label: {
                Image(systemName: "forward.fill").symbolEffect(.bounce.down, value: nextClicks)
                    .foregroundStyle(Self.transportColour)
            }
            .focusable(false)
            .accessibilityLabel("Next Track")
            .help("Next (\(AppAction.next.keys(classic: app.winampShortcuts)))")
            .disabled(player.queue.isEmpty)
            RepeatButton(player: player)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }
}

/// One button that cycles off → all → one, lit only while repeat is on (like the shuffle toggle).
struct RepeatButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: Player

    var body: some View {
        let mode = player.repeatMode
        Toggle(isOn: Binding(get: { mode != .off }, set: { _ in player.repeatMode = mode.next })) {
            Image(systemName: mode == .one ? "repeat.1" : "repeat")
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.bounce, value: !reduceMotion && mode != .off)
        }
        .toggleStyle(.button)
        .focusable(false)
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

/// The quality label, and any problem setting up the device.
private struct SignalSummary: View {
    let player: Player

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let path = player.signalPath {
                QualityBadge(path: path)
            }
            if let warning = player.deviceWarning {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(warning)
                    .help(warning)
            }
        }
    }
}

/// What doesn't need a button of its own: the full-size visualizer and the sleep timer.
private struct MoreMenu: View {
    let app: AppState

    var body: some View {
        Menu {
            Button("Jump to Song…") { app.run(.jump) }
            Button(app.showsFullLyrics ? "Hide Lyrics" : "Show Lyrics") { app.run(.lyrics) }
                .disabled(!AppAction.lyrics.isEnabled(in: app))
            Button(app.showsVisualizer ? "Hide Visualizer" : "Show Visualizer") { app.run(.visualizer) }
                .disabled(!AppAction.visualizer.isEnabled(in: app))
            Divider()
            Button("Audio Output…") { app.run(.output) }
            Button(app.isMuted ? "Unmute" : "Mute") { app.run(.mute) }
                .disabled(app.player.isSendingDoP)
            Menu("Sleep Timer") { SleepTimerChoices(timer: app.sleepTimer) }
            Divider()
            Button("Find a Command…") { app.run(.commands) }
            Button("Keyboard Shortcuts") { app.run(.shortcuts) }
        } label: {
            Image(systemName: "ellipsis")
                .playerBarIcon()
        }
        .menuStyle(.button)
        .focusable(false)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .help("Playback options")
        .accessibilityLabel("More")
    }
}


extension View {
    func playerBarIcon(active: Bool = false) -> some View {
        modifier(PlayerBarIcon(active: active))
    }
}

private struct PlayerBarIcon: ViewModifier {
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isEnabled ? (active ? Color.accentColor : Color.primary) : Color.secondary)
            .frame(width: 30, height: 30)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering && isEnabled ? 0.08 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
