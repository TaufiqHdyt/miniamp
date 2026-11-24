import Foundation
import GRDB
import os

/// The folders the library is made of, persisted as bookmarks so the sandboxed app can reopen
/// them on the next launch without asking again.
public enum LibraryFolders {
    static let log = Logger(subsystem: "dev.miniamp", category: "library")

    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    static var creationOptions: URL.BookmarkCreationOptions { isSandboxed ? [.withSecurityScope] : [] }
    static var resolutionOptions: URL.BookmarkResolutionOptions { isSandboxed ? [.withSecurityScope, .withoutUI] : [.withoutUI] }

    /// Adds `url` (a folder the user picked) to the library and returns its record.
    ///
    /// Selecting a saved folder again renews its access. An iCloud Drive folder restored from
    /// another Mac is matched by its path within iCloud Drive. A folder that
    /// contains library folders takes over their tracks (keeping play history), and they're removed.
    public static func add(_ url: URL, to database: AppDatabase) async throws -> LibraryFolder {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let path = LibraryPaths.canonical(url)
        let bookmark = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        return try await database.writer.write { db in
            let existing = try LibraryFolder.fetchAll(db)
            if var saved = existing.first(where: { $0.path == path }) {
                saved.bookmark = bookmark
                try saved.update(db)
                return saved
            }
            if let covering = existing.first(where: { path.hasPrefix($0.path + "/") }) {
                return covering
            }
            if let relative = LibraryPaths.iCloudRelativePath(path) {
                let matches = existing.filter { LibraryPaths.iCloudRelativePath($0.path) == relative }
                if matches.count == 1, let saved = matches.first {
                    return try relocate(saved, to: path, bookmark: bookmark, db)
                }
            }
            var folder = LibraryFolder(path: path, bookmark: bookmark, addedAt: Date())
            try folder.insert(db)
            let nested = existing.filter { $0.path.hasPrefix(path + "/") }.compactMap(\.id)
            if !nested.isEmpty {
                try db.execute(sql: "UPDATE track SET folderId = ? WHERE folderId IN (\(nested.map { _ in "?" }.joined(separator: ",")))",
                               arguments: StatementArguments([folder.id] + nested.map { $0 as Int64? }))
                _ = try LibraryFolder.deleteAll(db, keys: nested)
            }
            return folder
        }
    }

    private static func relocate(_ folder: LibraryFolder, to path: String, bookmark: Data,
                                 _ db: Database) throws -> LibraryFolder {
        let prefix = folder.path + "/"
        try db.execute(sql: """
            UPDATE track SET path = ? || substr(path, length(?) + 1)
            WHERE folderId = ? AND substr(path, 1, length(?)) = ?
            """, arguments: [path + "/", prefix, folder.id, prefix, prefix])
        var relocated = folder
        relocated.path = path
        relocated.bookmark = bookmark
        try relocated.update(db)
        return relocated
    }

    /// Removes the folder and its tracks from the library, retaining their listening history.
    public static func remove(_ folder: LibraryFolder, from database: AppDatabase) async throws {
        try await database.writer.write { db in
            let columns = Track.columnNames.dropFirst().joined(separator: ", ")
            try db.execute(sql: """
                INSERT INTO archivedTrack (\(columns))
                    SELECT \(columns) FROM track
                    WHERE folderId = ? AND EXISTS (SELECT 1 FROM play WHERE play.trackId = track.id);
                INSERT INTO archivedPlay (trackId, playedAt, listenedMs)
                    SELECT archivedTrack.id, play.playedAt, play.listenedMs
                    FROM play JOIN track ON track.id = play.trackId
                    JOIN archivedTrack ON archivedTrack.path = track.path
                    WHERE track.folderId = ?;
                """, arguments: [folder.id, folder.id])
            _ = try folder.delete(db)
            try LibraryScanner.deleteOrphans(db)
        }
    }

    /// A folder whose bookmark resolved, with security-scoped access started. Call `stop()` when done.
    public struct Access: Sendable {
        public var folder: LibraryFolder
        public let url: URL
        let accessing: Bool

        public func stop() { if accessing { url.stopAccessingSecurityScopedResource() } }
    }

    /// Resolves the folder's bookmark and starts access. Refreshes a stale bookmark, and follows
    /// a folder that was moved or renamed (the next full scan then finds its tracks at the new paths).
    public static func open(_ folder: LibraryFolder, in database: AppDatabase) async throws -> Access {
        var stale = false
        let url = try URL(resolvingBookmarkData: folder.bookmark, options: resolutionOptions,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let accessing = url.startAccessingSecurityScopedResource()
        var folder = folder
        let path = LibraryPaths.canonical(url)
        do {
            if stale || path != folder.path {
                if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    folder.bookmark = fresh
                }
                if path != folder.path {
                    log.notice("library folder moved: \(folder.path, privacy: .public) → \(path, privacy: .public)")
                }
                let updated = folder
                folder = try await database.writer.write { db in
                    if path != updated.path, let relative = LibraryPaths.iCloudRelativePath(path),
                       relative == LibraryPaths.iCloudRelativePath(updated.path) {
                        return try relocate(updated, to: path, bookmark: updated.bookmark, db)
                    }
                    var relocated = updated
                    relocated.path = path
                    try relocated.update(db)
                    return relocated
                }
            }
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        return Access(folder: folder, url: url, accessing: accessing)
    }
}
