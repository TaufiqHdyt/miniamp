import Foundation
import GRDB
import Observation
import os

/// The music library: its folders, keeping the database in step with them, and search.
///
/// On `open()` every folder gets an incremental scan (only new and changed files are read)
/// and an FSEvents watch, so files added, edited, moved, or deleted while the app runs show
/// up without a manual rescan. Scans run one at a time, off the main actor.
@MainActor
@Observable
public final class Library {
    public let database: AppDatabase
    public private(set) var folders: [LibraryFolder] = []
    public private(set) var trackCount = 0
    /// Bumped on every committed change to the tracks or playlists, so views can refresh what they show.
    public private(set) var revision = 0
    /// The scan in progress, or nil when idle.
    public private(set) var progress: ScanProgress?
    public private(set) var lastScan: ScanProgress?
    public private(set) var lastError: String?
    /// The loudness analysis in progress (see `analyzeLoudness`), or nil when idle.
    public private(set) var loudnessProgress: LoudnessProgress?
    /// Called after each album's ReplayGain is stored, with the paths it covered.
    @ObservationIgnored public var onLoudnessMeasured: (@MainActor (Set<String>) -> Void)?

    @ObservationIgnored public let artwork: ArtworkCache?
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var access: [Int64: LibraryFolders.Access] = [:]
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var scanQueue: Task<Void, Never>?
    @ObservationIgnored private var scanID = 0
    /// Watcher changes not yet handed to a scan, by folder. A full rescan request supersedes paths.
    @ObservationIgnored private var pendingPaths: [Int64: Set<String>] = [:]
    @ObservationIgnored private var pendingFull: Set<Int64> = []
    @ObservationIgnored private var flushQueued = false
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var opened = false
    @ObservationIgnored private var loudnessTask: Task<Void, Never>?

    static let log = Logger(subsystem: "dev.miniamp", category: "library")

    public init(database: AppDatabase, artwork: ArtworkCache?) {
        self.database = database
        self.artwork = artwork
        scanner = LibraryScanner(database: database, artwork: artwork)
    }

    isolated deinit {
        loudnessTask?.cancel()
        observer?.cancel()
        scanQueue?.cancel()
        watcher?.invalidate()
        access.values.forEach { $0.stop() }
    }

    /// Reopens the saved folders, scans them for changes since last time, and starts watching.
    public func open() async {
        guard !opened else { return }
        opened = true
        observeTracks()
        do {
            let saved = try await database.writer.read { try LibraryFolder.order(Column("path")).fetchAll($0) }
            for folder in saved {
                do {
                    let opened = try await LibraryFolders.open(folder, in: database)
                    access[opened.folder.id!] = opened
                } catch {
                    report("can't open \(folder.path): \(error)")
                }
            }
            try await reloadFolders()
            folders.filter { access[$0.id!] != nil }.forEach { enqueue($0, .folder) }
        } catch {
            report("can't load library folders: \(error)")
        }
    }

    /// Adds a folder the user picked, scans it, and watches it.
    public func addFolder(_ url: URL) async throws {
        let folder = try await LibraryFolders.add(url, to: database)
        if access[folder.id!] == nil {
            access[folder.id!] = try await LibraryFolders.open(folder, in: database)
        }
        try await reloadFolders()
        enqueue(folders.first { $0.id == folder.id } ?? folder, .folder)
    }

    public func removeFolder(_ folder: LibraryFolder) async throws {
        try await LibraryFolders.remove(folder, from: database)
        access.removeValue(forKey: folder.id!)?.stop()
        try await reloadFolders()
    }

    /// Checks every folder for changes. Only new and changed files are read.
    public func rescan() {
        folders.filter { access[$0.id!] != nil }.forEach { enqueue($0, .folder) }
    }

    public func search(_ text: String, sort: TrackSort = TrackSort(.relevance), limit: Int = 200) async throws -> [TrackInfo] {
        try await database.writer.read { try LibraryQueries.search(text, sort: sort, limit: limit, $0) }
    }

    public func allTracks(limit: Int = 1000) async throws -> [TrackInfo] {
        try await database.writer.read { try LibraryQueries.allTracks(limit: limit, $0) }
    }

    public func artists() async throws -> [ArtistSummary] {
        try await database.writer.read { try LibraryQueries.artists($0) }
    }

    public func albums(artistId: Int64? = nil) async throws -> [AlbumSummary] {
        try await database.writer.read { try LibraryQueries.albums(artistId: artistId, $0) }
    }

    public func playlists() async throws -> [PlaylistSummary] {
        try await database.writer.read { try LibraryQueries.playlists($0) }
    }

    // Playlist edits (see Playlists). Each one bumps `revision` once it's committed.

    @discardableResult
    public func createPlaylist(named name: String, trackIds: [Int64] = []) async throws -> Int64 {
        try await database.writer.write { try Playlists.create(named: name, trackIds: trackIds, $0) }
    }

    public func renamePlaylist(_ id: Int64, to name: String) async throws {
        try await database.writer.write { try Playlists.rename(id, to: name, $0) }
    }

    public func deletePlaylist(_ id: Int64) async throws {
        try await database.writer.write { try Playlists.delete(id, $0) }
    }

    public func addToPlaylist(_ id: Int64, trackIds: [Int64], at index: Int? = nil) async throws {
        try await database.writer.write { try Playlists.add(trackIds, to: id, at: index, $0) }
    }

    public func removeFromPlaylist(_ id: Int64, itemIds: [Int64]) async throws {
        try await database.writer.write { try Playlists.remove(itemIds, from: id, $0) }
    }

    public func movePlaylistItems(_ itemIds: [Int64], in id: Int64, to index: Int) async throws {
        try await database.writer.write { try Playlists.move(itemIds, in: id, to: index, $0) }
    }

    public func tracks(in scope: TrackScope, sort: TrackSort = .albumOrder) async throws -> [TrackInfo] {
        try await database.writer.read { try LibraryQueries.tracks(in: scope, sort: sort, $0) }
    }

    /// Library tracks for these files, by URL (files outside the library are left out).
    public func tracks(at urls: [URL]) async throws -> [URL: TrackInfo] {
        try await database.writer.read { db in
            var found: [URL: TrackInfo] = [:]
            let byPath = Dictionary(urls.map { (LibraryPaths.canonical($0), $0) }, uniquingKeysWith: { a, _ in a })
            let paths = Array(byPath.keys)
            for start in stride(from: 0, to: paths.count, by: 500) {
                let chunk = Array(paths[start..<min(start + 500, paths.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                for info in try TrackInfo.fetchAll(db, sql: TrackInfo.selectSQL + " WHERE track.path IN (\(placeholders))",
                                                   arguments: StatementArguments(chunk)) {
                    if let url = byPath[info.track.path] { found[url] = info }
                }
            }
            return found
        }
    }

    /// Writes `changes` into each track's file, then rescans those files so the library shows
    /// the new tags. Files in `openFiles` (paths, as the library spells them) are being read
    /// for playback and get a replaced copy instead of an in-place edit (see TagWriter).
    /// Offloaded tracks are skipped: their data isn't on this Mac.
    public func editTags(of tracks: [Track], _ changes: TagChanges, openFiles: Set<String> = []) async throws {
        let local = tracks.filter { !$0.isEvicted }
        guard !changes.isEmpty, !local.isEmpty else { return }
        var written: [Track] = []
        defer {
            for (folderId, edited) in Dictionary(grouping: written, by: \.folderId) {
                if let folder = folders.first(where: { $0.id == folderId }), access[folderId] != nil {
                    enqueue(folder, .paths(Set(edited.map(\.path))))
                }
            }
        }
        for track in local {
            try await Self.write(changes, to: track.url, replacingFile: openFiles.contains(track.path))
            written.append(track)
        }
    }

    @concurrent
    private nonisolated static func write(_ changes: TagChanges, to url: URL, replacingFile: Bool) async throws {
        try TagWriter.write(changes, to: url, replacingFile: replacingFile)
    }

    /// Measures ReplayGain for these tracks, or for every track that has none from its tags or
    /// an earlier analysis. The rest of their albums are measured with them, for the album gain.
    /// Runs in the background; does nothing while an analysis is already running.
    public func analyzeLoudness(trackIds: [Int64]? = nil) {
        guard loudnessTask == nil else { return }
        loudnessProgress = LoudnessProgress()
        loudnessTask = Task { [database] in
            defer {
                loudnessProgress = nil
                loudnessTask = nil
            }
            do {
                let groups = try await database.writer.read { db in
                    try LoudnessScanner.groups(for: trackIds ?? ReplayGains.unmeasuredTrackIds(db), db)
                }
                loudnessProgress?.tracksTotal = groups.reduce(0) { $0 + $1.count }
                let start = ContinuousClock.now
                try await withThrowingTaskGroup(of: ([Track], [ReplayGain?]).self) { group in
                    var pending = groups.makeIterator()
                    func addNext() -> Bool {
                        guard let tracks = pending.next() else { return false }
                        group.addTask { (tracks, await Self.measure(tracks)) }
                        return true
                    }
                    for _ in 0..<max(ProcessInfo.processInfo.activeProcessorCount, 1) where !addNext() { break }
                    while let (tracks, gains) = try await group.next() {
                        try Task.checkCancellation()
                        try await database.writer.write { db in
                            for (track, gain) in zip(tracks, gains) {
                                if let gain, let id = track.id { try ReplayGains.store(gain, source: .scan, trackId: id, db) }
                            }
                        }
                        loudnessProgress?.tracksDone += tracks.count
                        loudnessProgress?.failed += gains.filter { $0 == nil }.count
                        onLoudnessMeasured?(Set(tracks.map(\.path)))
                        _ = addNext()
                    }
                }
                let p = loudnessProgress ?? LoudnessProgress()
                Self.log.info("measured \(p.tracksDone) tracks in \(groups.count) groups (\(p.failed) failed) in \((ContinuousClock.now - start).formatted(), privacy: .public)")
            } catch is CancellationError {
            } catch {
                report("loudness analysis failed: \(error)")
            }
        }
    }

    public func cancelLoudnessAnalysis() {
        loudnessTask?.cancel()
    }

    /// Waits for a running loudness analysis (tests and the command-line tool).
    public func waitForLoudnessAnalysis() async {
        await loudnessTask?.value
    }

    @concurrent
    private nonisolated static func measure(_ tracks: [Track]) async -> [ReplayGain?] {
        LoudnessScanner.measure(tracks)
    }

    /// Starts downloading offloaded tracks. Once a file is local, the watcher sees it and its tags are read.
    public func download(_ tracks: [Track]) {
        for track in tracks where track.isEvicted { CloudFiles.startDownloading(track.url) }
    }

    /// Waits for every queued scan to finish (tests and the command-line tool).
    public func waitForScans() async {
        while let queue = scanQueue {
            await queue.value
            if queue == scanQueue { return }
        }
    }

    // MARK: Internals

    private func reloadFolders() async throws {
        folders = try await database.writer.read { try LibraryFolder.order(Column("path")).fetchAll($0) }
        let roots = folders.filter { access[$0.id!] != nil }.map(\.path)
        guard roots != watcher?.roots ?? [] else { return }
        watcher?.invalidate()
        watcher = roots.isEmpty ? nil : FolderWatcher(roots: roots) { [weak self] batch in
            Task { @MainActor in self?.filesChanged(batch) }
        }
    }

    /// FSEvents can deliver a big change (an album copied in) as many small callbacks. They're
    /// merged here and handed to one scan per folder once the scans ahead of it finish.
    private func filesChanged(_ batch: FolderWatcher.Batch) {
        for folder in folders where access[folder.id!] != nil {
            let id = folder.id!
            if batch.rescan.contains(folder.path) {
                pendingFull.insert(id)
                pendingPaths[id] = nil
            } else if !pendingFull.contains(id) {
                let paths = batch.paths.filter { $0 == folder.path || $0.hasPrefix(folder.path + "/") }
                if !paths.isEmpty { pendingPaths[id, default: []].formUnion(paths) }
            }
        }
        guard !flushQueued, !pendingPaths.isEmpty || !pendingFull.isEmpty else { return }
        flushQueued = true
        let previous = scanQueue
        scanQueue = Task {
            await previous?.value
            flushQueued = false
            let full = pendingFull, paths = pendingPaths
            pendingFull = []
            pendingPaths = [:]
            for folder in folders {
                if full.contains(folder.id!) { enqueue(folder, .folder) }
                else if let changed = paths[folder.id!] { enqueue(folder, .paths(changed)) }
            }
        }
    }

    /// Runs scans one after another, so two never write the same rows at once.
    private func enqueue(_ folder: LibraryFolder, _ scope: LibraryScanner.Scope) {
        let previous = scanQueue
        scanQueue = Task { [scanner] in
            await previous?.value
            scanID += 1
            let id = scanID
            do {
                let result = try await scanner.scan(folder, scope: scope) { p in
                    Task { @MainActor in
                        if self.scanID == id, p.phase != .finished { self.progress = p }
                    }
                }
                lastScan = result
            } catch is CancellationError {
            } catch {
                report("scan of \(folder.path) failed: \(error)")
            }
            scanID += 1 // late progress updates from this scan are now ignored
            progress = nil
        }
    }

    /// Any committed change to the tracks or the playlists bumps `revision`. (Reading the
    /// playlist tables puts them in the observed region; their counts aren't used.)
    private func observeTracks() {
        let counts = ValueObservation.tracking { db in
            let tracks = try Track.fetchCount(db)
            _ = try Playlist.fetchCount(db) + PlaylistItem.fetchCount(db)
            return tracks
        }.values(in: database.writer)
        observer = Task { [weak self] in
            do {
                for try await count in counts {
                    guard let self else { return }
                    self.trackCount = count
                    self.revision += 1
                }
            } catch {
                self?.report("library observation stopped: \(error)")
            }
        }
    }

    private func report(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
        lastError = message
    }
}
