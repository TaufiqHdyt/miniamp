import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #58: shared credits count toward each artist in them.
@Suite struct ArtistCreditsTests {
    @Test func featuringAndSlashesAlwaysSplit() {
        #expect(ArtistCredits.parts(of: "Kygo feat. Selena Gomez") == (["Kygo", "Selena Gomez"], true))
        #expect(ArtistCredits.parts(of: "A ft. B & C").names == ["A", "B", "C"])
        #expect(ArtistCredits.parts(of: "A / B").certain)
        #expect(ArtistCredits.parts(of: "A; B; A").names == ["A", "B"])
        #expect(ArtistCredits.parts(of: "Simon & Garfunkel") == (["Simon", "Garfunkel"], false))
        #expect(ArtistCredits.parts(of: "Aimer").names == ["Aimer"])
    }

    @Test func commasAndAmpersandsSplitOnlyWhenAPartIsKnown() {
        let members = ArtistCredits.members(of: [
            "Alan Walker", "Alan Walker & David Whistle", "Alan Walker, Farruko, Sabrina Carpenter",
            "Earth, Wind & Fire", "Simon & Garfunkel", "Tyler, The Creator",
            "Shawn Mendes & Camila Cabello", "Camila Cabello, Young Thug",
        ])
        #expect(members["Alan Walker & David Whistle"] == ["Alan Walker", "David Whistle"])
        #expect(members["Alan Walker, Farruko, Sabrina Carpenter"] == ["Alan Walker", "Farruko", "Sabrina Carpenter"])
        // Neither part credited elsewhere: a name, not a list.
        #expect(members["Earth, Wind & Fire"] == nil)
        #expect(members["Simon & Garfunkel"] == nil)
        #expect(members["Tyler, The Creator"] == nil)
        // Camila Cabello is in two credits, though never alone.
        #expect(members["Shawn Mendes & Camila Cabello"] == ["Shawn Mendes", "Camila Cabello"])
        #expect(members["Alan Walker"] == nil)
    }

    func library() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            try BrowseTests.track("Force", artist: "Alan Walker", album: "Different World", d)
            try BrowseTests.track("Routine", artist: "Alan Walker & David Whistle", album: "Routine", d)
            try BrowseTests.track("On My Way", artist: "Alan Walker, Farruko, Sabrina Carpenter", album: "On My Way", d)
            try BrowseTests.track("September", artist: "Earth, Wind & Fire", album: "The Best Of", d)
            try LibraryScanner.deleteOrphans(d)
        }
        return db
    }

    @Test func artistsListEachNameOnce() throws {
        let db = try library()
        let artists = try db.writer.read { try LibraryQueries.artists($0) }
        #expect(artists.map(\.name) == ["Alan Walker", "David Whistle", "Earth, Wind & Fire", "Farruko", "Sabrina Carpenter"])
        let walker = try #require(artists.first { $0.name == "Alan Walker" })
        #expect(walker.trackCount == 3)
        #expect(walker.albumCount == 3) // Routine and On My Way are his too, through their album artist
        let whistle = try #require(artists.first { $0.name == "David Whistle" })
        #expect(whistle.trackCount == 1)

        let songs = try db.writer.read { try LibraryQueries.tracks(in: .artist(walker.id), $0) }
        #expect(Set(songs.map(\.track.title)) == ["Force", "Routine", "On My Way"])
        // The song keeps its full credit.
        #expect(songs.first { $0.track.title == "Routine" }?.artistName == "Alan Walker & David Whistle")
        let albums = try db.writer.read { try LibraryQueries.albums(artistId: whistle.id, $0) }
        #expect(albums.map(\.title) == ["Routine"])
    }

    @Test func membersKeepTheirIdsAndGoWithTheirLastCredit() throws {
        let db = try library()
        let before = try db.writer.read { try LibraryQueries.artists($0) }
        try db.writer.write { try LibraryScanner.deleteOrphans($0) }
        #expect(try db.writer.read { try LibraryQueries.artists($0) } == before)

        try db.writer.write { d in
            try d.execute(sql: "DELETE FROM track WHERE title = 'Routine'")
            try LibraryScanner.deleteOrphans(d)
        }
        let names = try db.writer.read { try String.fetchAll($0, sql: "SELECT name FROM artist ORDER BY name") }
        #expect(!names.contains("David Whistle"))
        #expect(!names.contains("Alan Walker & David Whistle"))
        #expect(names.contains("Farruko"))
    }

    @Test func playsCountTowardEachArtist() throws {
        let db = try library()
        try db.writer.write { d in
            let id = try Int64.fetchOne(d, sql: "SELECT id FROM track WHERE title = 'Routine'")!
            try d.execute(sql: "INSERT INTO play (trackId, playedAt, listenedMs) VALUES (?, ?, 60000)", arguments: [id, Date()])
        }
        let stats = try db.writer.read { try ListeningStats.compute(year: nil, $0) }
        #expect(stats.artists == 2)
        #expect(Set(stats.topArtists.map(\.item)) == ["Alan Walker", "David Whistle"])
    }

    @Test func migrationSplitsExistingCredits() throws {
        let queue = try DatabaseQueue()
        var migrator = AppDatabase.migrator
        try migrator.migrate(queue, upTo: "v7")
        try queue.write { d in
            try BrowseTests.track("Force", artist: "Alan Walker", album: nil, d)
            try BrowseTests.track("Routine", artist: "Alan Walker & David Whistle", album: nil, d)
        }
        migrator = AppDatabase.migrator
        try migrator.migrate(queue)
        let artists = try queue.read { try LibraryQueries.artists($0) }
        #expect(artists.map(\.name) == ["Alan Walker", "David Whistle"])
    }
}
