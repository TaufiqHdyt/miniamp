import MiniAmpKit
import Observation
import SwiftUI

/// What the window, the menus, and the settings share: the player, the library, and the
/// actions that start playback from a list.
@MainActor
@Observable
final class AppState {
    let player: Player
    /// Nil if the database can't be opened; the player still works without it.
    let library: Library?
    let sleepTimer: SleepTimer

    var importingFiles = false
    var addingFolder = false
    var error: String?
    /// The toolbar search. While it has text, the window shows results instead of the sidebar's choice.
    var searchText = ""
    /// Bumped by Edit › Find to move focus to the search field.
    var searchFocusRequests = 0

    /// The now-playing inspector. Remembered across launches.
    var showsNowPlaying = UserDefaults.standard.object(forKey: "showsNowPlaying") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsNowPlaying, forKey: "showsNowPlaying") }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    /// An offloaded track that was double-clicked: it plays, with the list it was in, once it's downloaded.
    private(set) var waitingToPlay: (id: TrackInfo.ID, list: [TrackInfo])?

    init(player: Player, library: Library?) {
        self.player = player
        self.library = library
        sleepTimer = SleepTimer(player: player)
    }

    /// Runs an action and shows any error it throws.
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch is CancellationError {
            } catch let e {
                error = "\(e)"
            }
        }
    }

    /// Plays `list` from the row `id`. Offloaded tracks are left out of the queue (opening one
    /// would wait on a download mid-playback); starting at one downloads it, then plays it.
    func play(_ list: [TrackInfo], from id: TrackInfo.ID?, shuffled: Bool = false) {
        let start = id.flatMap { id in list.first { $0.id == id } }
        if let start, start.track.isEvicted {
            waitingToPlay = (start.id, list)
            library?.download([start.track])
            return
        }
        waitingToPlay = nil
        let playable = list.filter { !$0.track.isEvicted }
        guard !playable.isEmpty else { return }
        let index = start.flatMap { s in playable.firstIndex { $0.id == s.id } } ?? 0
        perform { [player] in
            // The queue keeps the shuffle setting; "Shuffle" turns it on and starts anywhere.
            if shuffled { player.setShuffle(true) }
            try await player.setQueue(playable.map(\.track.url), startAt: shuffled ? Int.random(in: playable.indices) : index)
        }
    }

    func isWaitingToPlay(_ id: TrackInfo.ID) -> Bool { waitingToPlay?.id == id }

    /// Called when the library changes: plays the track being waited on if it's now downloaded.
    func libraryChanged() {
        guard let waiting = waitingToPlay, let library else { return }
        Task {
            let urls = waiting.list.map(\.track.url)
            guard let fresh = try? await library.tracks(at: urls), waitingToPlay?.id == waiting.id else { return }
            let list = waiting.list.map { info in
                var info = info
                if let now = fresh[info.track.url] { info.track = now.track }
                return info
            }
            if let target = list.first(where: { $0.id == waiting.id }), !target.track.isEvicted {
                play(list, from: waiting.id)
            } else {
                waitingToPlay = (waiting.id, list)
            }
        }
    }

    /// The URL of what's playing (or paused, or next to play).
    var currentURL: URL? { player.queue.current }
}
