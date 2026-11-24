import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #44: backing up and restoring the library and settings.
@Suite struct BackupTests {
    @Test func roundTrips() throws {
        let folder = try TestFolder()
        let live = try AppDatabase.at(folder.url.appendingPathComponent("library.sqlite").path)
        let artwork = try ArtworkCache(directory: folder.url.appendingPathComponent("artwork"))
        let keptKey = try #require(artwork.store(TestImage.png(width: 20, height: 20)))
        try live.writer.write { d in
            var a = try SchemaTests.insertTrack("Kept cover", artist: "Band", album: "Record", d)
            a.artworkKey = keptKey
            a.modifiedAt = 456
            try a.update(d)
            var b = try SchemaTests.insertTrack("Lost cover", artist: "Band", album: "Record", d)
            b.artworkKey = "missing"
            b.modifiedAt = 123
            try b.update(d)
            var play = Play(trackId: a.id!, playedAt: Date(), listenedMs: 40_000)
            try play.insert(d)
        }
        _ = try live.writer.write { try Playlists.create(named: "Mix", trackIds: [1, 2, 1], $0) }

        let backup = folder.url.appendingPathComponent("Mine.\(LibraryBackup.fileExtension)")
        let settings: [String: Any] = ["dspMode": true, "replayGainPreamp": -3.5, "inspectorPane": "lyrics"]
        try LibraryBackup.write(live, settings: settings, appVersion: "1.2", to: backup)

        let info = try LibraryBackup.info(of: backup)
        #expect(info.appVersion == "1.2")
        #expect((info.tracks, info.playlists, info.plays) == (2, 1, 1))
        #expect(abs(info.createdAt.timeIntervalSinceNow) < 60)

        // Things change after the backup...
        try live.writer.write { d in
            try d.execute(sql: "DELETE FROM playlist")
            _ = try SchemaTests.insertTrack("Added later", artist: nil, album: nil, d)
        }
        // ...and restoring puts them back.
        let restored = try LibraryBackup.restore(from: backup, into: live, artwork: artwork)
        #expect(restored["dspMode"] as? Bool == true)
        #expect(restored["replayGainPreamp"] as? Double == -3.5)
        #expect(restored["inspectorPane"] as? String == "lyrics")
        try live.writer.read { (d: Database) throws in
            #expect(try String.fetchAll(d, sql: "SELECT title FROM track ORDER BY id") == ["Kept cover", "Lost cover"])
            #expect(try Int.fetchOne(d, sql: "SELECT count(*) FROM playlistItem") == 3)
            #expect(try Int.fetchOne(d, sql: "SELECT count(*) FROM play") == 1)
            #expect(try !d.tableExists("backupInfo"))
            #expect(try !d.tableExists("backupSettings"))
            // Only the track whose thumbnail is gone is read again.
            #expect(try Double.fetchAll(d, sql: "SELECT modifiedAt FROM track ORDER BY id") == [456, 0])
        }
        // The search index came across too.
        #expect(try live.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM trackSearch WHERE trackSearch MATCH 'lost'") } == 1)
    }

    @Test func mergesPlayHistoryAcrossDifferentPathsWithoutDuplicatingPlays() throws {
        let folder = try TestFolder()
        let source = try AppDatabase.inMemory()
        let destination = try AppDatabase.inMemory()
        let playedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let later = playedAt.addingTimeInterval(60)
        try source.writer.write { db in
            let song = try SchemaTests.insertTrack("Song", artist: "Band", album: "Album", db)
            let missing = try SchemaTests.insertTrack("Missing", artist: nil, album: nil, db)
            for (track, date) in [(song, playedAt), (song, later), (missing, later)] {
                var play = Play(trackId: try #require(track.id), playedAt: date, listenedMs: 45_000)
                try play.insert(db)
            }
        }
        try destination.writer.write { db in
            _ = try SchemaTests.insertTrack("Local song", artist: nil, album: nil, db)
            let song = try SchemaTests.insertTrack("Song", artist: "Band", album: "Album",
                                                   path: "/another/mac/Song.flac", db)
            var play = Play(trackId: try #require(song.id), playedAt: playedAt, listenedMs: 30_000)
            try play.insert(db)
        }

        let backup = folder.url.appendingPathComponent("merge.miniampbackup")
        try LibraryBackup.write(source, settings: [:], appVersion: "1.2", to: backup)
        let result = try LibraryBackup.mergePlayHistory(from: backup, into: destination)
        #expect((result.added, result.updated, result.unmatched) == (1, 1, 1))
        let repeated = try LibraryBackup.mergePlayHistory(from: backup, into: destination)
        #expect((repeated.added, repeated.updated, repeated.unmatched) == (0, 0, 1))

        try destination.writer.read { db in
            let stats = try ListeningStats.compute(year: nil, db)
            #expect(stats.plays == 2)
            #expect(stats.listened == .seconds(90))
            #expect(stats.topTracks.first?.item.track.path == "/another/mac/Song.flac")
        }
    }

    @Test func mergesICloudPlaysBeforeLocalTagsAreAvailable() throws {
        let folder = try TestFolder()
        let source = try AppDatabase.inMemory()
        let destination = try AppDatabase.inMemory()
        let relative = "/Library/Mobile Documents/com~apple~CloudDocs/Music/Song.flac"
        try source.writer.write { db in
            let song = try SchemaTests.insertTrack("Tagged song", artist: "Band", album: "Album",
                                                   path: "/Users/source" + relative, db)
            var play = Play(trackId: try #require(song.id), playedAt: Date(), listenedMs: 45_000)
            try play.insert(db)
        }
        try destination.writer.write { db in
            var placeholder = try SchemaTests.insertTrack("Song", artist: nil, album: nil,
                                                          path: "/Users/destination" + relative, db)
            placeholder.isEvicted = true
            placeholder.durationMs = 0
            try placeholder.update(db)
        }

        let backup = folder.url.appendingPathComponent("icloud.miniampbackup")
        try LibraryBackup.write(source, settings: [:], appVersion: "1.2", to: backup)
        let result = try LibraryBackup.mergePlayHistory(from: backup, into: destination)
        #expect((result.added, result.updated, result.unmatched) == (1, 0, 0))
    }

    @Test func refusesOtherFiles() throws {
        let folder = try TestFolder()
        let live = try AppDatabase.inMemory()
        let text = try folder.write(Data("hello".utf8), to: "notes.miniampbackup")
        #expect(throws: LibraryBackup.NotABackup.self) { try LibraryBackup.info(of: text) }
        // A plain library database isn't a backup either.
        let plain = folder.url.appendingPathComponent("library.sqlite")
        _ = try AppDatabase.at(plain.path)
        #expect(throws: LibraryBackup.NotABackup.self) { try LibraryBackup.restore(from: plain, into: live, artwork: nil) }
    }

    @Test func refusesBackupsFromANewerSchema() throws {
        let folder = try TestFolder()
        let live = try AppDatabase.at(folder.url.appendingPathComponent("library.sqlite").path)
        let backup = folder.url.appendingPathComponent("b.miniampbackup")
        try LibraryBackup.write(live, settings: [:], appVersion: "9", to: backup)
        let queue = try DatabaseQueue(path: backup.path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99')") }
        try queue.close()
        #expect(throws: LibraryBackup.NewerBackup.self) { try LibraryBackup.restore(from: backup, into: live, artwork: nil) }
    }
}
