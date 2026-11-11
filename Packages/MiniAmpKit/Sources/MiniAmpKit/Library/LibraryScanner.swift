import Foundation
import GRDB
import os
import Synchronization

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: Sendable { case listing, reading, finished }

    public var phase: Phase = .listing
    /// Audio files in the scanned scope.
    public var filesFound = 0
    /// New or changed files whose tags need reading.
    public var filesToRead = 0
    public var filesRead = 0
    public var added = 0
    public var updated = 0
    /// Files that disappeared from one path and showed up at another; they keep their history.
    public var moved = 0
    public var removed = 0
    /// Files TagLib couldn't open. They're retried on the next scan.
    public var unreadable = 0
    /// Files in scope whose data is only in the cloud (see CloudFiles). They're listed by file
    /// name until they're downloaded, then their tags are read.
    public var offloaded = 0

    public var changedAnything: Bool { added + updated + moved + removed > 0 }
}

public enum ScanError: Error, CustomStringConvertible, Sendable {
    case folderUnavailable(String)

    public var description: String {
        switch self {
        case .folderUnavailable(let path): "\(path) isn't available (unmounted, moved, or no permission)"
        }
    }
}

/// Brings the database in line with what's on disk, reading tags only for new and changed files.
///
/// A file counts as changed when its size or modification date differ from what the database
/// has. Tags are read in parallel off the caller's thread and written in batches, each in one
/// transaction, so readers (the UI) see the library fill in and never wait on a long write.
public final class LibraryScanner: Sendable {
    public static let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "wav", "aiff", "aif"]
    static let batchSize = 256
    static let log = Logger(subsystem: "dev.miniamp", category: "scanner")

    public enum Scope: Sendable, Equatable {
        /// Everything under the folder; tracks for files that are gone are removed.
        case folder
        /// Only these paths (files or directories, existing or not), as reported by FolderWatcher.
        case paths(Set<String>)
    }

    let database: AppDatabase
    let artwork: ArtworkCache?
    /// Whether a file's data is only in the cloud. Replaceable for tests.
    let isEvicted: @Sendable (String) -> Bool

    public convenience init(database: AppDatabase, artwork: ArtworkCache?) {
        self.init(database: database, artwork: artwork, isEvicted: CloudFiles.isEvicted)
    }

    init(database: AppDatabase, artwork: ArtworkCache?, isEvicted: @escaping @Sendable (String) -> Bool) {
        self.database = database
        self.artwork = artwork
        self.isEvicted = isEvicted
    }

    @concurrent
    public func scan(_ folder: LibraryFolder, scope: Scope = .folder,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanProgress {
        guard let folderId = folder.id else { preconditionFailure("scan of an unsaved folder") }
        let root = LibraryPaths.normalized(folder.path)
        guard Self.isDirectory(root) else { throw ScanError.folderUnavailable(root) }

        var p = ScanProgress()
        progress?(p)

        // What's on disk, and what the database has, within the scope.
        var onDisk: [String: FileStat] = [:]
        var known: [String: KnownTrack] = [:]
        switch scope {
        case .folder:
            for stat in try Self.list(root, isEvicted: isEvicted) { onDisk[stat.path] = stat }
            known = try await database.writer.read { db in
                try Self.knownTracks(db, sql: "folderId = ?", [folderId])
            }
        case .paths(let paths):
            let inFolder = paths.map(LibraryPaths.normalized).filter { $0 == root || $0.hasPrefix(root + "/") }
                .filter { !Self.isHiddenOrIgnored($0, under: root) }
            for path in inFolder {
                if Self.isDirectory(path) {
                    for stat in try Self.list(path, isEvicted: isEvicted) { onDisk[stat.path] = stat }
                } else if let stat = Self.stat(path, isEvicted: isEvicted) {
                    onDisk[path] = stat
                }
            }
            known = try await database.writer.read { db in
                var known: [String: KnownTrack] = [:]
                for path in inFolder {
                    // The path itself, or anything under it if it was (or is) a directory.
                    let under = try Self.knownTracks(db, sql: "folderId = ? AND (path = ? OR (path > ? AND path < ?))",
                                                     [folderId, path, path + "/", path + "0"])
                    known.merge(under) { a, _ in a }
                }
                return known
            }
        }
        try Task.checkCancellation()

        // Local files are read when new or changed, or when they've just been downloaded.
        // Offloaded ones only need a placeholder (new) or the offloaded mark (known).
        var toRead: [FileStat] = []
        var offloaded: [FileStat] = []
        for file in onDisk.values {
            let track = known[file.path]
            let changed = track.map { $0.size != file.size || $0.modified != file.modified } ?? true
            if file.isEvicted {
                p.offloaded += 1
                if changed || track?.isEvicted == false { offloaded.append(file) }
            } else if changed || track?.isEvicted == true {
                toRead.append(file)
            }
        }
        toRead.sort { $0.path < $1.path }
        // Known tracks whose files are gone: removed at the end unless a new file turns out to be one of them, moved.
        let missing = known.filter { onDisk[$0.key] == nil }
        var movedIDs = Set<Int64>()
        var moveCandidates: [MoveKey: [Int64]] = [:]
        var offloadedMoveCandidates: [OffloadedMoveKey: [Int64]] = [:]
        for track in missing.values {
            moveCandidates[track.moveKey, default: []].append(track.id)
            offloadedMoveCandidates[track.offloadedMoveKey, default: []].append(track.id)
        }

        if !offloaded.isEmpty {
            var changes: [Change] = []
            for file in offloaded {
                if let track = known[file.path] {
                    changes.append(.offloaded(track.id, file))
                    p.updated += 1
                } else if let id = offloadedMoveCandidates[OffloadedMoveKey(file)]?.popLast() {
                    movedIDs.insert(id)
                    changes.append(.offloaded(id, file))
                    p.moved += 1
                } else {
                    changes.append(.offloaded(nil, file))
                    p.added += 1
                }
            }
            let offloadedChanges = changes
            try await database.writer.write { db in
                for change in offloadedChanges { try Self.apply(change, folderId: folderId, db) }
            }
        }

        p.phase = .reading
        p.filesFound = onDisk.count
        p.filesToRead = toRead.count
        progress?(p)

        let folderArt = FolderArtMemo()
        for start in stride(from: 0, to: toRead.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(toRead[start..<min(start + Self.batchSize, toRead.count)])
            let scanned = await read(batch, folderArt: folderArt)

            var changes: [Change] = []
            for file in scanned {
                guard let tags = file.tags else {
                    p.unreadable += 1
                    continue
                }
                if let existing = known[file.stat.path] {
                    changes.append(.update(existing.id, file, tags))
                    p.updated += 1
                } else if let id = moveCandidates[MoveKey(file.stat, tags)]?.popLast(), !movedIDs.contains(id) {
                    movedIDs.insert(id)
                    changes.append(.update(id, file, tags))
                    p.moved += 1
                } else {
                    changes.append(.insert(file, tags))
                    p.added += 1
                }
            }
            let batchChanges = changes
            try await database.writer.write { db in
                for change in batchChanges { try Self.apply(change, folderId: folderId, db) }
            }
            p.filesRead += batch.count
            progress?(p)
        }

        let removedIDs = missing.values.map(\.id).filter { !movedIDs.contains($0) }
        p.removed = removedIDs.count
        let isFullScan = scope == .folder
        let cleanUp = p.changedAnything
        try await database.writer.write { db in
            if !removedIDs.isEmpty {
                try Track.deleteAll(db, keys: removedIDs)
            }
            if cleanUp { try Self.deleteOrphans(db) }
            if isFullScan {
                try db.execute(sql: "UPDATE libraryFolder SET lastScannedAt = ? WHERE id = ?", arguments: [Date(), folderId])
            }
        }

        p.phase = .finished
        progress?(p)
        Self.log.info("""
            scanned \(root, privacy: .public)\(isFullScan ? "" : " (changed paths)", privacy: .public): \
            \(p.filesFound) files, \(p.added) added, \(p.updated) updated, \(p.moved) moved, \
            \(p.removed) removed, \(p.unreadable) unreadable, \(p.offloaded) offloaded
            """)
        return p
    }

    // MARK: Reading

    private struct Scanned: Sendable {
        var stat: FileStat
        var tags: TrackTags?
        var artworkKey: String?
    }

    /// Reads tags for `files` in parallel, one task per core.
    private func read(_ files: [FileStat], folderArt: FolderArtMemo) async -> [Scanned] {
        let width = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let artwork = artwork
        return await withTaskGroup(of: Scanned.self) { group in
            var results: [Scanned] = []
            results.reserveCapacity(files.count)
            var next = files.makeIterator()
            func add(_ file: FileStat) {
                group.addTask { Self.read(file, artwork: artwork, folderArt: folderArt) }
            }
            for _ in 0..<width { if let file = next.next() { add(file) } }
            for await result in group {
                results.append(result)
                if let file = next.next() { add(file) }
            }
            return results
        }
    }

    /// Per-scan artwork bookkeeping, so each image is thumbnailed once even though an album's
    /// tracks are read in parallel and all carry the same cover.
    private final class FolderArtMemo: Sendable {
        /// Thumbnail keys of folder cover images, by directory.
        let keys = Mutex<[String: String?]>([:])
        /// Image keys already stored (or being stored by another task) during this scan.
        let stored = Mutex<Set<String>>([])

        func store(_ data: Data, in cache: ArtworkCache) -> String? {
            let key = ArtworkCache.key(for: data)
            let claimed = stored.withLock { $0.insert(key).inserted }
            // Another task has it; the thumbnail lands under the same key.
            guard claimed else { return key }
            let result = cache.store(data)
            if result == nil { _ = stored.withLock { $0.remove(key) } }
            return result
        }
    }

    private static func read(_ file: FileStat, artwork: ArtworkCache?, folderArt: FolderArtMemo) -> Scanned {
        // A file offloaded since it was listed fails to read (and is retried) rather than downloading.
        CloudFiles.withoutDownloading { readLocal(file, artwork: artwork, folderArt: folderArt) }
    }

    private static func readLocal(_ file: FileStat, artwork: ArtworkCache?, folderArt: FolderArtMemo) -> Scanned {
        let url = URL(fileURLWithPath: file.path, isDirectory: false)
        guard var tags = TagReader.read(url, includeArtwork: artwork != nil) else { return Scanned(stat: file) }
        var key: String?
        if let artwork {
            if let data = tags.artwork { key = folderArt.store(data, in: artwork) }
            tags.artwork = nil
            if key == nil {
                let directory = url.deletingLastPathComponent()
                if let cached = folderArt.keys.withLock({ $0[directory.path] }) {
                    key = cached
                } else {
                    let found = ArtworkCache.folderImage(in: directory)
                        .flatMap { try? Data(contentsOf: $0) }
                        .flatMap { folderArt.store($0, in: artwork) }
                    folderArt.keys.withLock { $0[directory.path] = .some(found) }
                    key = found
                }
            }
        }
        return Scanned(stat: file, tags: tags, artworkKey: key)
    }

    // MARK: Writing

    private enum Change: Sendable {
        case insert(Scanned, TrackTags)
        case update(Int64, Scanned, TrackTags)
        /// An offloaded file: marks a known track (keeping its tags), or adds a placeholder.
        case offloaded(Int64?, FileStat)
    }

    private static func apply(_ change: Change, folderId: Int64, _ db: Database) throws {
        switch change {
        case .insert(let file, let tags):
            var track = try makeTrack(file, tags, folderId: folderId, db)
            try track.insert(db)
        case .update(let id, let file, let tags):
            guard let old = try Track.fetchOne(db, key: id) else { return }
            var track = try makeTrack(file, tags, folderId: folderId, db)
            track.id = id
            track.addedAt = old.addedAt
            if track != old { try track.update(db) }
        case .offloaded(let id?, let file):
            try db.execute(sql: "UPDATE track SET path = ?, fileSize = ?, modifiedAt = ?, isEvicted = 1 WHERE id = ?",
                           arguments: [file.path, file.size, file.modified, id])
        case .offloaded(nil, let file):
            let url = URL(fileURLWithPath: file.path, isDirectory: false)
            var track = Track(folderId: folderId, path: file.path, fileSize: file.size, modifiedAt: file.modified,
                              title: url.deletingPathExtension().lastPathComponent, durationMs: 0, sampleRate: 0,
                              channels: 0, bitrateKbps: 0, codec: url.pathExtension.uppercased(),
                              addedAt: Date(), isEvicted: true)
            try track.insert(db)
        }
    }

    private static func makeTrack(_ file: Scanned, _ tags: TrackTags, folderId: Int64, _ db: Database) throws -> Track {
        let url = URL(fileURLWithPath: file.stat.path, isDirectory: false)
        let artistId = try artist(named: tags.artist, db)
        let albumArtistId = try tags.albumArtist.nonBlank != nil ? artist(named: tags.albumArtist, db) : artistId
        let albumId = try album(titled: tags.album, artistId: albumArtistId, year: tags.year,
                                artworkKey: file.artworkKey, db)
        return Track(
            folderId: folderId,
            path: file.stat.path,
            fileSize: file.stat.size,
            modifiedAt: file.stat.modified,
            title: tags.title.nonBlank ?? url.deletingPathExtension().lastPathComponent,
            artistId: artistId,
            albumId: albumId,
            genre: tags.genre.nonBlank,
            year: tags.year,
            trackNumber: tags.trackNumber,
            discNumber: tags.discNumber,
            durationMs: tags.duration.wholeMilliseconds,
            sampleRate: tags.sampleRate,
            bitsPerSample: tags.bitsPerSample,
            channels: tags.channels,
            bitrateKbps: tags.bitrateKbps,
            codec: tags.codec.isEmpty ? url.pathExtension.uppercased() : tags.codec,
            artworkKey: file.artworkKey,
            addedAt: Date())
    }

    private static func artist(named name: String?, _ db: Database) throws -> Int64? {
        guard let name = name.nonBlank else { return nil }
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM artist WHERE name = ?", arguments: [name]) { return id }
        var artist = Artist(name: name)
        try artist.insert(db)
        return artist.id
    }

    private static func album(titled title: String?, artistId: Int64?, year: Int?, artworkKey: String?,
                              _ db: Database) throws -> Int64? {
        guard let title = title.nonBlank else { return nil }
        if var album = try Album.fetchOne(db, sql: "SELECT * FROM album WHERE title = ? AND ifnull(artistId, 0) = ?",
                                          arguments: [title, artistId ?? 0]) {
            // Fill in what earlier tracks of the album didn't have.
            if (album.year == nil && year != nil) || (album.artworkKey == nil && artworkKey != nil) {
                album.year = album.year ?? year
                album.artworkKey = album.artworkKey ?? artworkKey
                try album.update(db)
            }
            return album.id
        }
        var album = Album(title: title, artistId: artistId, year: year, artworkKey: artworkKey)
        try album.insert(db)
        return album.id
    }

    /// Albums with no tracks, then artists with neither tracks nor albums.
    static func deleteOrphans(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM album WHERE id NOT IN (SELECT albumId FROM track WHERE albumId IS NOT NULL);
            DELETE FROM artist
            WHERE id NOT IN (SELECT artistId FROM track WHERE artistId IS NOT NULL)
              AND id NOT IN (SELECT artistId FROM album WHERE artistId IS NOT NULL);
            """)
    }

    // MARK: Files

    struct FileStat: Sendable, Hashable {
        var path: String
        var size: Int64
        var modified: Double
        var isEvicted = false
    }

    private struct KnownTrack: Sendable {
        var id: Int64
        var size: Int64
        var modified: Double
        var durationMs: Int
        var isEvicted: Bool
        var moveKey: MoveKey { MoveKey(size: size, durationMs: durationMs) }
        var offloadedMoveKey: OffloadedMoveKey { OffloadedMoveKey(size: size, modified: modified) }
    }

    /// Identifies an offloaded file that moved, whose duration can't be read: a move keeps
    /// both the size and the modification date.
    private struct OffloadedMoveKey: Hashable {
        var size: Int64
        var modified: Double

        init(size: Int64, modified: Double) {
            self.size = size
            self.modified = modified
        }

        init(_ stat: FileStat) { self.init(size: stat.size, modified: stat.modified) }
    }

    /// Identifies a file that moved: the content is the same, so size and duration match.
    private struct MoveKey: Hashable {
        var size: Int64
        var durationMs: Int

        init(size: Int64, durationMs: Int) {
            self.size = size
            self.durationMs = durationMs
        }

        init(_ stat: FileStat, _ tags: TrackTags) {
            self.init(size: stat.size, durationMs: tags.duration.wholeMilliseconds)
        }
    }

    private static func knownTracks(_ db: Database, sql condition: String, _ arguments: StatementArguments) throws -> [String: KnownTrack] {
        var known: [String: KnownTrack] = [:]
        let rows = try Row.fetchCursor(db, sql: "SELECT id, path, fileSize, modifiedAt, durationMs, isEvicted FROM track WHERE \(condition)",
                                       arguments: arguments)
        while let row = try rows.next() {
            known[row["path"]] = KnownTrack(id: row["id"], size: row["fileSize"], modified: row["modifiedAt"],
                                            durationMs: row["durationMs"], isEvicted: row["isEvicted"])
        }
        return known
    }

    private static let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

    /// Every audio file under `directory`, skipping hidden files and package contents.
    static func list(_ directory: String, isEvicted: (String) -> Bool) throws -> [FileStat] {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw ScanError.folderUnavailable(directory) }
        var files: [FileStat] = []
        // Build paths from the root string so they keep its exact spelling (FSEvents compares against it).
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        let rootComponents = root.standardizedFileURL.pathComponents.count
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true
            else { continue }
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootComponents).joined(separator: "/")
            let path = LibraryPaths.normalized(base + relative)
            files.append(FileStat(path: path, size: Int64(values.fileSize ?? 0),
                                  modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                  isEvicted: isEvicted(path)))
        }
        return files
    }

    static func stat(_ path: String, isEvicted: (String) -> Bool) -> FileStat? {
        let path = LibraryPaths.normalized(path)
        let url = URL(fileURLWithPath: path)
        guard audioExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
              values.isRegularFile == true
        else { return nil }
        return FileStat(path: path, size: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        isEvicted: isEvicted(path))
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// True for paths a folder scan skips: anything with a hidden component below the root.
    static func isHiddenOrIgnored(_ path: String, under root: String) -> Bool {
        guard path.count > root.count else { return false }
        return path.dropFirst(root.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

extension Optional where Wrapped == String {
    /// The trimmed string, or nil if it's missing or blank.
    var nonBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension Duration {
    var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}
