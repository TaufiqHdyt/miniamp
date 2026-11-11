import AppKit
import MiniAmpKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

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

    /// What the inspector shows under the cover. Remembered across launches.
    var inspectorPane = InspectorPane(rawValue: UserDefaults.standard.string(forKey: "inspectorPane") ?? "") ?? .upNext {
        didSet { UserDefaults.standard.set(inspectorPane.rawValue, forKey: "inspectorPane") }
    }

    /// Ask LRCLIB for lyrics when a song has none of its own. Off until turned on: it sends
    /// what's playing (title, artist, album, duration) to lrclib.net.
    var looksUpLyricsOnline = UserDefaults.standard.bool(forKey: "looksUpLyricsOnline") {
        didSet { UserDefaults.standard.set(looksUpLyricsOnline, forKey: "looksUpLyricsOnline") }
    }

    @ObservationIgnored let lyricsFinder: LyricsFinder

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    /// An offloaded track that was double-clicked: it plays, with the list it was in, once it's downloaded.
    private(set) var waitingToPlay: (id: TrackInfo.ID, list: [TrackInfo])?
    /// The library's playlists, by name; kept current by the window (see `reloadPlaylists`).
    private(set) var playlists: [PlaylistSummary] = []
    /// A sidebar item to show, asked for by something outside the sidebar (a new playlist).
    var sidebarRequest: SidebarItem?
    /// The playlist whose name is being edited in the sidebar.
    var renamingPlaylist: Int64?
    /// The tracks in the Get Info sheet.
    var editingTags: TagEditTarget?
    /// Media keys and Control Center.
    @ObservationIgnored private var systemNowPlaying: SystemNowPlaying?
    @ObservationIgnored private var playHistory: PlayHistory?

    init(player: Player, library: Library?) {
        self.player = player
        self.library = library
        sleepTimer = SleepTimer(player: player)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        lyricsFinder = LyricsFinder(database: library?.database, client: LRCLIB(userAgent: "miniamp/\(version)"))
        systemNowPlaying = SystemNowPlaying(app: self)
        if let library {
            playHistory = PlayHistory(player: player, database: library.database)
            // A primary-key read, on the main actor as each track starts (gapless needs it
            // before the boundary, with no time to wait).
            let database = library.database
            player.replayGainLookup = { url in
                try? database.writer.read { try ReplayGains.lookup(path: LibraryPaths.normalized(url.path), $0) }
            }
            library.onLoudnessMeasured = { [weak player] paths in
                guard let player, let current = player.queue.current,
                      paths.contains(LibraryPaths.normalized(current.path)) else { return }
                player.reloadReplayGain()
            }
        }
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

    var waitingToPlayID: TrackInfo.ID? { waitingToPlay?.id }

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

    // MARK: Playlists

    func reloadPlaylists() async {
        guard let library else { return }
        do { playlists = try await library.playlists() } catch { self.error = "\(error)" }
    }

    /// Creates a playlist (holding `tracks`, if any), shows it, and starts editing its name.
    func newPlaylist(with tracks: [TrackInfo] = []) {
        guard let library else { return }
        let taken = Set(playlists.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "Untitled Playlist" : "Untitled Playlist \($0)" }.first { !taken.contains($0) }!
        perform { [self] in
            let id = try await library.createPlaylist(named: name, trackIds: tracks.compactMap(\.track.id))
            await reloadPlaylists()
            sidebarRequest = .playlist(id)
            renamingPlaylist = id
        }
    }

    func add(_ tracks: [TrackInfo], toPlaylist id: Int64) {
        guard let library else { return }
        perform { try await library.addToPlaylist(id, trackIds: tracks.compactMap(\.track.id)) }
    }

    /// Asks where to save, then writes the playlist there as M3U8.
    func exportPlaylist(_ playlist: PlaylistSummary) {
        guard let library else { return }
        let panel = NSSavePanel()
        panel.title = "Export Playlist"
        panel.nameFieldStringValue = playlist.name.replacingOccurrences(of: "/", with: "-") + ".m3u8"
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .m3uPlaylist]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let tracks = try await library.tracks(in: .playlist(playlist.id), sort: TrackSort(.playlistOrder))
            let text = M3U8.export(tracks, name: playlist.name, savedIn: url.deletingLastPathComponent())
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    // MARK: Lyrics

    func showLyrics() {
        showsNowPlaying = true
        inspectorPane = .lyrics
    }

    // MARK: Equalizer

    /// The window that was in front when the Equalizer opened (Settings, say). When the
    /// Equalizer closes it gets the focus back; left to itself, AppKit raises the main window.
    @ObservationIgnored private weak var windowBeforeEqualizer: NSWindow?
    @ObservationIgnored private var closeObserver: (any NSObjectProtocol)?

    func showEqualizer(_ openWindow: OpenWindowAction) {
        if let front = NSApp.keyWindow, !Self.isEqualizer(front) { windowBeforeEqualizer = front }
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: nil
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.windowWillClose(window) }
            }
        }
        openWindow(id: "equalizer")
    }

    /// SwiftUI names the window after the scene's id ("equalizer-…"); the title is a fallback.
    private static func isEqualizer(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("equalizer") == true || window.title == "Equalizer"
    }

    /// Runs before the window goes: the earlier window, put just under the Equalizer and made
    /// key, is in front once it's gone, so AppKit has nothing to choose and nothing flickers.
    private func windowWillClose(_ window: NSWindow) {
        if window === windowBeforeEqualizer {
            windowBeforeEqualizer = nil // closed meanwhile: it stays closed
            return
        }
        guard Self.isEqualizer(window), let previous = windowBeforeEqualizer, previous.isVisible else { return }
        windowBeforeEqualizer = nil
        previous.order(.below, relativeTo: window.windowNumber)
        previous.makeKey()
    }

    // MARK: Loudness

    /// Measures ReplayGain for these tracks and the rest of their albums.
    func analyzeLoudness(of tracks: [TrackInfo]) {
        library?.analyzeLoudness(trackIds: tracks.filter { !$0.track.isEvicted }.compactMap(\.track.id))
    }

    // MARK: Tags

    func editTags(of tracks: [TrackInfo]) {
        let local = tracks.filter { !$0.track.isEvicted }
        guard !local.isEmpty else { return }
        editingTags = TagEditTarget(tracks: local)
    }

    /// Saves the Get Info sheet's changes. The file playing now, and the one queued after it
    /// (opened early for gapless playback), are replaced rather than edited in place.
    func saveTags(_ changes: TagChanges, of tracks: [TrackInfo]) {
        guard let library else { return }
        var open: Set<String> = []
        if let current = currentURL { open.insert(LibraryPaths.normalized(current.path)) }
        if let next = player.queue.upcoming(automatic: true) {
            open.insert(LibraryPaths.normalized(player.queue.item(atPosition: next).path))
        }
        perform { try await library.editTags(of: tracks.map(\.track), changes, openFiles: open) }
    }
}

enum InspectorPane: String {
    case upNext, lyrics
}

/// The tracks a Get Info sheet edits.
struct TagEditTarget: Identifiable {
    let id = UUID()
    let tracks: [TrackInfo]
}
