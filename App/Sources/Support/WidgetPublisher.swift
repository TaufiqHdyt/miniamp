import AppKit
import MiniAmpKit
import Observation
import WidgetKit

/// Keeps the widget's copy of what's playing current: on a new song, play, pause, stop, and
/// seek. Nothing is written while nothing changes; the widget's progress bar runs by itself.
@MainActor
final class WidgetPublisher {
    private let app: AppState
    private var lastArtworkID: String?
    private var pending: Task<Void, Never>?

    init(app: AppState) {
        self.app = app
        PlaybackCommands.handle = { [weak app] command in
            guard let app else { return }
            let player = app.player
            switch command {
            case .togglePlayPause: try? await player.togglePlayPause()
            case .next: try? await player.next()
            case .previous: try? await player.previous()
            }
        }
        observe()
    }

    private func observe() {
        let player = app.player
        withObservationTracking {
            _ = player.state
            _ = player.seekCount
            _ = player.trackStarts
            _ = player.queue.current
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.schedule()
                self.observe()
            }
        }
        schedule()
    }

    /// A quick burst of changes (a skip is stop, start, play) becomes one write.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }

    private func publish() async {
        guard let snapshotURL = SharedContainer.snapshotURL else { return }
        let player = app.player
        var snapshot = NowPlayingSnapshot.empty
        if let url = player.queue.current {
            let entry = await QueueEntry.load([url], from: app.library)[url] ?? QueueEntry(fileName: url)
            snapshot = NowPlayingSnapshot(title: entry.title, artist: entry.artist, album: entry.album,
                                          isPlaying: player.state == .playing, position: player.exactTime.seconds,
                                          positionDate: .now, duration: player.duration.seconds,
                                          artworkID: entry.artworkKey ?? (entry.inLibrary ? nil : "file:" + url.path))
            if snapshot.artworkID != lastArtworkID {
                writeArtwork(entry)
                lastArtworkID = snapshot.artworkID
            }
        }
        do {
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: SharedContainer.widgetKind)
        } catch {
            // No app group container (see README): there's simply no widget data.
        }
    }

    private func writeArtwork(_ entry: QueueEntry) {
        guard let artworkURL = SharedContainer.artworkURL else { return }
        Task {
            var image: NSImage?
            if let key = entry.artworkKey, let artwork = app.library?.artwork {
                image = await ArtworkImages.shared.image(for: key, size: .small, in: artwork)
            } else if !entry.inLibrary {
                image = await ArtworkImages.shared.image(embeddedIn: entry.url, size: .small)
            }
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            else {
                try? FileManager.default.removeItem(at: artworkURL)
                return
            }
            try? jpeg.write(to: artworkURL, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: SharedContainer.widgetKind)
        }
    }
}
