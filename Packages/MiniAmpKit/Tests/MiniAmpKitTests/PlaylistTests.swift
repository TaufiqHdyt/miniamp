import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issues #26 and #27: editing playlists, and exporting them as M3U8.
@Suite struct PlaylistTests {
    let db: AppDatabase
    /// Track ids for "A", "B", "C", "D".
    let ids: [Int64]

    init() throws {
        db = try AppDatabase.inMemory()
        ids = try db.writer.write { d in
            try ["A", "B", "C", "D"].map { try SchemaTests.insertTrack($0, artist: "Band", album: nil, d).id! }
        }
    }

    func titles(_ playlist: Int64) throws -> [String] {
        try db.writer.read { try LibraryQueries.tracks(in: .playlist(playlist), sort: TrackSort(.playlistOrder), $0) }
            .map(\.track.title)
    }

    func items(_ playlist: Int64) throws -> [Int64] {
        try db.writer.read { try Playlists.itemIds(in: playlist, $0) }
    }

    func positions(_ playlist: Int64) throws -> [Int] {
        try db.writer.read {
            try Int.fetchAll($0, sql: "SELECT position FROM playlistItem WHERE playlistId = ? ORDER BY position", arguments: [playlist])
        }
    }

    @Test func createAddAndInsert() throws {
        let id = try db.writer.write { try Playlists.create(named: "  Mix ", trackIds: [ids[0], ids[1]], $0) }
        try db.writer.write { try Playlists.add([ids[2]], to: id, $0) }
        try db.writer.write { try Playlists.add([ids[3], ids[0]], to: id, at: 1, $0) }
        #expect(try titles(id) == ["A", "D", "A", "B", "C"])
        #expect(try positions(id) == [0, 1, 2, 3, 4])
        #expect(try db.writer.read { try LibraryQueries.playlists($0) }.map(\.name) == ["Mix"])
        #expect(throws: Playlists.EditError.self) { try db.writer.write { try Playlists.create(named: " ", $0) } }
    }

    @Test func removeTakesOneEntryOfATrackThatAppearsTwice() throws {
        let id = try db.writer.write { try Playlists.create(named: "Mix", trackIds: [ids[0], ids[1], ids[0]], $0) }
        let entries = try items(id)
        try db.writer.write { try Playlists.remove([entries[2]], from: id, $0) }
        #expect(try titles(id) == ["A", "B"])
        #expect(try positions(id) == [0, 1])
    }

    @Test func moveUsesDropRowsCountedBeforeTheMove() throws {
        let id = try db.writer.write { try Playlists.create(named: "Mix", trackIds: ids, $0) }
        var e = try items(id) // A B C D
        // A and B dropped before D (row 3): C A B D.
        try db.writer.write { try Playlists.move([e[0], e[1]], in: id, to: 3, $0) }
        #expect(try titles(id) == ["C", "A", "B", "D"])
        // D to the top.
        e = try items(id)
        try db.writer.write { try Playlists.move([e[3]], in: id, to: 0, $0) }
        #expect(try titles(id) == ["D", "C", "A", "B"])
        // C to the end (past the last row), and dropping onto itself changes nothing.
        e = try items(id)
        try db.writer.write { try Playlists.move([e[1]], in: id, to: 99, $0) }
        #expect(try titles(id) == ["D", "A", "B", "C"])
        e = try items(id)
        try db.writer.write { try Playlists.move([e[1]], in: id, to: 1, $0) }
        #expect(try titles(id) == ["D", "A", "B", "C"])
        #expect(try positions(id) == [0, 1, 2, 3])
    }

    @Test func renameAndDelete() throws {
        let id = try db.writer.write { try Playlists.create(named: "Old", trackIds: [ids[0]], $0) }
        try db.writer.write { try Playlists.rename(id, to: "New", $0) }
        #expect(try db.writer.read { try LibraryQueries.playlists($0) }.map(\.name) == ["New"])
        #expect(throws: Playlists.EditError.self) { try db.writer.write { try Playlists.rename(999, to: "X", $0) } }
        try db.writer.write { try Playlists.delete(id, $0) }
        #expect(try db.writer.read { try LibraryQueries.playlists($0) }.isEmpty)
        #expect(try db.writer.read { try PlaylistItem.fetchCount($0) } == 0)
        #expect(try db.writer.read { try Track.fetchCount($0) } == 4)
    }

    @Test func libraryRevisionFollowsPlaylistEdits() async throws {
        let library = await Library(database: db, artwork: nil)
        await library.open()
        #expect(await eventually { await library.trackCount == 4 })
        let before = await library.revision
        let id = try await library.createPlaylist(named: "Mix", trackIds: [ids[0]])
        #expect(await eventually { await library.revision > before })
        let afterCreate = await library.revision
        try await library.addToPlaylist(id, trackIds: [ids[1]])
        #expect(await eventually { await library.revision > afterCreate })
    }

    @Test func m3u8() throws {
        var a = try db.writer.read { try LibraryQueries.tracks(in: .all, sort: .albumOrder, $0) }
        a[0].track.path = "/Users/me/Music/Band/A.flac"
        a[0].track.durationMs = 241_400
        a[1].track.path = "/Volumes/Other/B.flac"
        a[1].artistName = nil
        a[1].track.title = "Two\nLines"
        a[2].track.durationMs = 0
        let text = M3U8.export(Array(a.prefix(3)), name: "Road Trip", savedIn: URL(fileURLWithPath: "/Users/me/Music"))
        #expect(text == """
            #EXTM3U
            #PLAYLIST:Road Trip
            #EXTINF:241,Band - A
            Band/A.flac
            #EXTINF:1,Two Lines
            /Volumes/Other/B.flac
            #EXTINF:-1,Band - C
            /music/C.flac

            """)
    }
}
