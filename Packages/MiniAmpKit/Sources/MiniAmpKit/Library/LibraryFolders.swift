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
    /// A folder inside one that's already in the library returns that one. A folder that
    /// contains library folders takes over their tracks (keeping play history), and they're removed.
    public static func add(_ url: URL, to database: AppDatabase) async throws -> LibraryFolder {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let path = LibraryPaths.canonical(url)
        let bookmark = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        return try await database.writer.write { db in
            let existing = try LibraryFolder.fetchAll(db)
            if let covering = existing.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                return covering
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

    /// Removes the folder and its tracks (and with them, their play history and playlist entries).
    public static func remove(_ folder: LibraryFolder, from database: AppDatabase) async throws {
        try await database.writer.write { db in
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
        if stale || path != folder.path {
            if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                folder.bookmark = fresh
            }
            if path != folder.path {
                log.notice("library folder moved: \(folder.path, privacy: .public) → \(path, privacy: .public)")
                folder.path = path
            }
            let updated = folder
            try await database.writer.write { db in try updated.update(db) }
        }
        return Access(folder: folder, url: url, accessing: accessing)
    }
}
