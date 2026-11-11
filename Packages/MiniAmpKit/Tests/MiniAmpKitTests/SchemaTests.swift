import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #13: the schema.
@Suite struct SchemaTests {
    let db: AppDatabase

    init() throws { db = try AppDatabase.inMemory() }

    static func insertTrack(_ title: String, artist: String?, album: String?, albumArtist: String? = nil,
                     genre: String? = nil, path: String? = nil, _ d: Database) throws -> Track {
        var folder = try LibraryFolder.fetchOne(d) ?? LibraryFolder(path: "/music", bookmark: Data(), addedAt: Date())
        if folder.id == nil { try folder.insert(d) }
        func artistID(_ name: String?) throws -> Int64? {
            guard let name else { return nil }
            if let a = try Artist.filter(Column("name") == name).fetchOne(d) { return a.id }
            var a = Artist(name: name); try a.insert(d); return a.id
        }
        let artistId = try artistID(artist)
        var albumId: Int64?
        if let album {
            let owner = try artistID(albumArtist) ?? artistId
            if let a = try Album.filter(Column("title") == album && Column("artistId") == owner).fetchOne(d) {
                albumId = a.id
            } else {
                var a = Album(title: album, artistId: owner); try a.insert(d); albumId = a.id
            }
        }
        var track = Track(folderId: folder.id!, path: path ?? "/music/\(title).flac", fileSize: 1, modifiedAt: 0,
                          title: title, artistId: artistId, albumId: albumId, genre: genre, durationMs: 1000,
                          sampleRate: 44_100, bitsPerSample: 16, channels: 2, bitrateKbps: 900, codec: "FLAC",
                          addedAt: Date())
        try track.insert(d)
        return track
    }

    @Test func albumIdentityIsTitleAndAlbumArtistEvenWithoutAnArtist() throws {
        try db.writer.write { d in
            var a = Album(title: "Untitled", artistId: nil); try a.insert(d)
            var b = Album(title: "untitled", artistId: nil)
            #expect(throws: DatabaseError.self) { try b.insert(d) }
        }
    }

    @Test func deletingATrackCascadesToHistoryAndPlaylists() throws {
        try db.writer.write { d in
            let track = try Self.insertTrack("Song", artist: nil, album: nil, d)
            var playlist = Playlist(name: "Mix", createdAt: Date(), updatedAt: Date()); try playlist.insert(d)
            var item = PlaylistItem(playlistId: playlist.id!, trackId: track.id!, position: 0); try item.insert(d)
            var play = Play(trackId: track.id!, playedAt: Date(), listenedMs: 31_000); try play.insert(d)
            _ = try Track.deleteAll(d)
            #expect(try PlaylistItem.fetchCount(d) == 0)
            #expect(try Play.fetchCount(d) == 0)
            #expect(try Playlist.fetchCount(d) == 1)
        }
    }

    @Test func searchIndexFollowsTracks() throws {
        try db.writer.write { d in
            var track = try Self.insertTrack("Song", artist: "Someone", album: "Record", d)
            #expect(try Int.fetchOne(d, sql: "SELECT count(*) FROM trackSearch WHERE trackSearch MATCH 'someone'") == 1)
            track.title = "Other"
            try track.update(d)
            #expect(try Int.fetchOne(d, sql: "SELECT count(*) FROM trackSearch WHERE trackSearch MATCH 'other'") == 1)
            _ = try Track.deleteAll(d)
            #expect(try Int.fetchOne(d, sql: "SELECT count(*) FROM trackSearch") == 0)
        }
    }
}
