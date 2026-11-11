import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #18: full-text search.
@Suite struct SearchTests {
    let db: AppDatabase

    init() throws { db = try AppDatabase.inMemory() }

    func insertTrack(_ title: String, artist: String?, album: String?, albumArtist: String? = nil,
                     genre: String? = nil, _ d: Database) throws -> Track {
        try SchemaTests.insertTrack(title, artist: artist, album: album, albumArtist: albumArtist, genre: genre, d)
    }

    func search(_ text: String) throws -> [String] {
        try db.writer.read { try LibraryQueries.search(text, $0).map(\.track.title) }
    }

    @Test func searchMatchesPrefixesAcrossFieldsIgnoringDiacritics() throws {
        try db.writer.write { d in
            _ = try insertTrack("Jóga", artist: "Björk", album: "Homogenic", genre: "Electronic", d)
            _ = try insertTrack("Hunter", artist: "Björk", album: "Homogenic", d)
            _ = try insertTrack("Teardrop", artist: "Massive Attack", album: "Mezzanine", d)
        }
        #expect(try Set(search("bjork")) == ["Jóga", "Hunter"])
        #expect(try search("joga") == ["Jóga"])
        #expect(try Set(search("hom")) == ["Jóga", "Hunter"])
        #expect(try search("massive tear") == ["Teardrop"])
        #expect(try search("electro") == ["Jóga"])
        #expect(try search("bjork tear").isEmpty)
        #expect(try search("  \"  ").isEmpty)
    }

    @Test func titleMatchesRankAboveAlbumMatches() throws {
        try db.writer.write { d in
            _ = try insertTrack("Something Else", artist: "X", album: "Blue", d)
            _ = try insertTrack("Blue", artist: "Y", album: "Other", d)
        }
        #expect(try search("blue").first == "Blue")
    }

    @Test func indexFollowsUpdatesDeletesAndRenames() throws {
        let track = try db.writer.write { try insertTrack("Old Title", artist: "Someone", album: "Record", $0) }
        try db.writer.write { d in
            var t = track; t.title = "New Title"; try t.update(d)
        }
        #expect(try search("old").isEmpty)
        #expect(try search("new") == ["New Title"])

        try db.writer.write { try $0.execute(sql: "UPDATE artist SET name = 'Renamed'") }
        #expect(try search("someone").isEmpty)
        #expect(try search("renamed") == ["New Title"])

        try db.writer.write { try $0.execute(sql: "UPDATE album SET title = 'Disc'") }
        #expect(try search("record").isEmpty)
        #expect(try search("disc") == ["New Title"])

        try db.writer.write { _ = try Track.deleteAll($0) }
        #expect(try search("new").isEmpty)
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM trackSearch") } == 0)
    }

    @Test func ftsQueryQuotesEachWordAsAPrefix() {
        #expect(LibraryQueries.ftsQuery("AC/DC  back\"in") == "\"AC/DC\"* \"backin\"*")
        #expect(LibraryQueries.ftsQuery(" - ") == nil)
    }
}
