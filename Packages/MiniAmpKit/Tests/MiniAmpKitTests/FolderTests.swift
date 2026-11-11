import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #14: library folders and their bookmarks.
@Suite struct FolderTests {
    @Test func bookmarkReopensTheFolderAtItsCanonicalPath() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let record = try await LibraryFolders.add(folder.url, to: db)
        #expect(record.path == folder.path)
        #expect(record.path.hasPrefix("/private/"))
        #expect(!record.bookmark.isEmpty)
        let access = try await LibraryFolders.open(record, in: db)
        defer { access.stop() }
        #expect(LibraryPaths.canonical(access.url) == folder.path)
    }

    @Test func nestedFoldersMerge() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        try folder.mp3("child/a.mp3", title: "A")
        let child = try await LibraryFolders.add(folder.url.appendingPathComponent("child"), to: db)
        _ = try await LibraryScanner(database: db, artwork: nil).scan(child)

        // Inside an existing folder: that folder.
        let inner = try await LibraryFolders.add(folder.url.appendingPathComponent("child"), to: db)
        #expect(inner.id == child.id)

        // A parent: takes over the child's tracks.
        let parent = try await LibraryFolders.add(folder.url, to: db)
        let state = try await db.writer.read { (try LibraryFolder.fetchAll($0).map(\.id), try Track.fetchAll($0).map(\.folderId)) }
        #expect(state.0 == [parent.id])
        #expect(state.1 == [parent.id!])
    }
}
