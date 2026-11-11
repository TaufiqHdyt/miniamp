import AppKit
import MediaPlayer
import MiniAmpKit

/// Media keys, Control Center and the Lock Screen: takes their commands through
/// `MPRemoteCommandCenter` and tells them what's playing through `MPNowPlayingInfoCenter`.
///
/// The playhead is sent only when it jumps (play, pause, seek, new track). In between, the
/// system moves it along from the playback rate, so nothing is sent on every tick.
@MainActor
final class NowPlaying {
    private weak var app: AppState?
    /// Tags of the current track, once loaded.
    private var entry: QueueEntry?
    private var artwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?
    private var loadedKey: LoadKey?

    init(app: AppState) {
        self.app = app
        registerCommands()
        observe()
    }

    // MARK: - Commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        on(center.togglePlayPauseCommand) { player in try await player.togglePlayPause() }
        on(center.playCommand) { player in
            if player.state == .paused { try player.resume() }
            else if player.state == .stopped { try await player.togglePlayPause() }
        }
        on(center.pauseCommand) { player in player.pause() }
        on(center.stopCommand) { player in player.stop() }
        on(center.nextTrackCommand) { player in try await player.next() }
        on(center.previousTrackCommand) { player in try await player.previous() }
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.app?.player.seek(to: .seconds(time)) }
            return .success
        }
    }

    /// Runs `action` on the player for each `command`, showing any error in the window.
    private func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) async throws -> Void) {
        command.isEnabled = true
        // @Sendable: the handler isn't tied to the main thread, in case the system calls it elsewhere.
        command.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let app = self?.app else { return }
                let player = app.player
                app.perform { try await action(player) }
            }
            return .success
        }
    }

    // MARK: - Now playing info

    /// Calls `update` now and after each change to what it reads.
    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        guard let app else { return }
        let player = app.player
        let center = MPNowPlayingInfoCenter.default()

        guard let url = app.currentURL else {
            loadTask?.cancel()
            loadedKey = nil
            entry = nil
            artwork = nil
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        // Read for observation: re-tagging a file in the library changes the revision.
        let key = LoadKey(url: url, revision: app.library?.revision ?? 0)
        if key != loadedKey { load(key) }

        let current = entry?.url == url ? entry : nil
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current?.title ?? url.deletingPathExtension().lastPathComponent,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            // Observed so a seek or a new track resends the playhead.
            MPNowPlayingInfoPropertyElapsedPlaybackTime: { _ = player.seekCount; return player.currentTime.seconds }(),
        ]
        if let artist = current?.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = current?.album { info[MPMediaItemPropertyAlbumTitle] = album }
        let duration = player.duration > .zero ? player.duration.seconds : Double(current?.durationMs ?? 0) / 1000
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if current != nil, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info

        center.playbackState = switch player.state {
        case .playing: .playing
        case .paused: .paused
        case .preparing: .interrupted
        case .stopped: .stopped
        }
    }

    /// Reads the track's tags and cover, then updates again.
    private func load(_ key: LoadKey) {
        loadedKey = key
        loadTask?.cancel()
        let library = app?.library
        loadTask = Task { [weak self] in
            guard let found = await QueueEntry.load([key.url], from: library)[key.url], !Task.isCancelled else { return }
            let image: NSImage? = if let artworkKey = found.artworkKey, let cache = library?.artwork {
                await ArtworkImages.shared.image(for: artworkKey, size: .large, in: cache)
            } else if !found.inLibrary {
                await ArtworkImages.shared.image(embeddedIn: key.url, size: .large)
            } else {
                nil
            }
            guard let self, !Task.isCancelled else { return }
            entry = found
            artwork = image.map(Self.artwork)
            update()
        }
    }

    /// Nonisolated: the system calls the handler on a background thread.
    nonisolated private static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private struct LoadKey: Equatable {
        var url: URL
        var revision: Int
    }
}
