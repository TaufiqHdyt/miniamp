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
