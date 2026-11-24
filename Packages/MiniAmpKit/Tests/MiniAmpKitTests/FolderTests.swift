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

    @Test func reattachesRestoredICloudFolderAndKeepsPlayHistory() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let relative = "Library/Mobile Documents/com~apple~CloudDocs/Music"
        let local = folder.url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let oldRoot = "/Users/another-mac/" + relative
        let ids = try await db.writer.write { d in
            var saved = LibraryFolder(path: oldRoot, bookmark: Data(), addedAt: Date())
            try saved.insert(d)
            let song = try SchemaTests.insertTrack("Song", artist: nil, album: nil, path: oldRoot + "/Song.flac", d)
            var play = Play(trackId: song.id!, playedAt: Date(), listenedMs: 45_000)
            try play.insert(d)
            return (saved.id, song.id)
        }

        let reopened = try await LibraryFolders.add(local, to: db)
        #expect(reopened.id == ids.0)
        #expect(reopened.path == LibraryPaths.canonical(local))
        let access = try await LibraryFolders.open(reopened, in: db)
        defer { access.stop() }

        try await db.writer.read { (d: Database) throws in
            #expect(try Track.fetchOne(d, key: ids.1)?.path == reopened.path + "/Song.flac")
            #expect(try Play.fetchOne(d)?.trackId == ids.1)
            #expect(try LibraryFolder.fetchCount(d) == 1)
        }
    }

    @Test func removingAFolderKeepsStatsAndReaddingItReattachesHistory() async throws {
        let db = try AppDatabase.inMemory()
        let files = try TestFolder()
        let music = files.url.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let folder = try await LibraryFolders.add(music, to: db)
        let path = folder.path + "/Song.flac"
        try await db.writer.write { d in
            let song = try SchemaTests.insertTrack("Song", artist: "Band", album: "Album", genre: "Rock", path: path, d)
            var play = Play(trackId: try #require(song.id), playedAt: Date(), listenedMs: 45_000)
            try play.insert(d)
        }

        try await LibraryFolders.remove(folder, from: db)
        try await db.writer.read { (d: Database) throws in
            #expect(try Track.fetchCount(d) == 0)
            #expect(try LibraryFolder.fetchCount(d) == 0)
            let stats = try ListeningStats.compute(year: nil, d)
            #expect(stats.plays == 1)
            #expect(stats.listened == .seconds(45))
            #expect(stats.topTracks.first?.item.track.title == "Song")
            #expect(stats.topArtists.first?.item == "Band")
            #expect(stats.topAlbums.first?.item.isInLibrary == false)
            #expect(stats.topGenres.first?.item == "Rock")
        }

        let backup = files.url.appendingPathComponent("history.miniampbackup")
        try LibraryBackup.write(db, settings: [:], appVersion: "1.2", to: backup)
        #expect(try LibraryBackup.info(of: backup).plays == 1)
        let restored = try AppDatabase.inMemory()
        try LibraryBackup.restore(from: backup, into: restored, artwork: nil)
        let restoredPlays = try await restored.writer.read { try ListeningStats.compute(year: nil, $0).plays }
        #expect(restoredPlays == 1)

        _ = try await LibraryFolders.add(music, to: db)
        try await db.writer.write { d in
            let song = try SchemaTests.insertTrack("Song", artist: "Band", album: "Album", genre: "Rock", path: path, d)
            var play = Play(trackId: try #require(song.id), playedAt: Date(), listenedMs: 35_000)
            try play.insert(d)
        }
        let merged = try LibraryBackup.mergePlayHistory(from: backup, into: db)
        #expect((merged.added, merged.updated, merged.unmatched) == (0, 0, 0))
        try await db.writer.read { (d: Database) throws in
            let stats = try ListeningStats.compute(year: nil, d)
            #expect(stats.plays == 2)
            #expect(stats.tracks == 1)
            #expect(stats.listened == .seconds(80))
            #expect(stats.topAlbums.first?.item.isInLibrary == true)
        }
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
