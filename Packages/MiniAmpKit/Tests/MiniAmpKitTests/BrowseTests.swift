import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issues #19 and #20: browsing by artist, album, and playlist, and sorting track lists.
@Suite struct BrowseTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
        try db.writer.write { d in
            // A compilation (album artist "Various") with tracks by two artists, and a solo album.
            try Self.track("B Side", artist: "Alpha", album: "Hits", albumArtist: "Various", disc: 1, number: 2, year: 2001, d)
            try Self.track("A Side", artist: "Beta", album: "Hits", albumArtist: "Various", disc: 1, number: 1, year: 2001, d)
            try Self.track("Encore", artist: "Beta", album: "Hits", albumArtist: "Various", disc: 2, number: 1, year: 2001, d)
            try Self.track("Zed", artist: "Alpha", album: "Solo", number: 1, year: 1999, durationMs: 300_000, d)
            try Self.track("Loose", artist: nil, album: nil, d)
        }
    }

    @discardableResult
    static func track(_ title: String, artist: String?, album: String?, albumArtist: String? = nil,
                      disc: Int? = nil, number: Int? = nil, year: Int? = nil, durationMs: Int = 1000,
                      sampleRate: Int = 44_100, _ d: Database) throws -> Track {
        var track = try SchemaTests.insertTrack(title, artist: artist, album: album, albumArtist: albumArtist, d)
        track.discNumber = disc
        track.trackNumber = number
        track.year = year
        track.durationMs = durationMs
        track.sampleRate = sampleRate
        try track.update(d)
        return track
    }

    func titles(_ scope: TrackScope, _ sort: TrackSort = .albumOrder) throws -> [String] {
        try db.writer.read { try LibraryQueries.tracks(in: scope, sort: sort, $0).map(\.track.title) }
    }

    func id(artist name: String) throws -> Int64 {
        try db.writer.read { try Artist.filter(Column("name") == name).fetchOne($0)!.id! }
    }

    func id(album title: String) throws -> Int64 {
        try db.writer.read { try Album.filter(Column("title") == title).fetchOne($0)!.id! }
    }

    @Test func artistsIncludeAlbumArtistsWithCounts() throws {
        let artists = try db.writer.read { try LibraryQueries.artists($0) }
        #expect(artists.map(\.name) == ["Alpha", "Beta", "Various"])
        let byName = Dictionary(uniqueKeysWithValues: artists.map { ($0.name, $0) })
        #expect(byName["Alpha"]?.trackCount == 2)
        #expect(byName["Alpha"]?.albumCount == 1) // owns Solo; only appears on Hits
        #expect(byName["Various"]?.trackCount == 3)
        #expect(byName["Various"]?.albumCount == 1)
    }

    @Test func albumsSummarizeTheirTracks() throws {
        let albums = try db.writer.read { try LibraryQueries.albums($0) }
        #expect(albums.map(\.title) == ["Solo", "Hits"])
        let hits = try #require(albums.first { $0.title == "Hits" })
        #expect(hits.artistName == "Various")
        #expect(hits.trackCount == 3)
        #expect(hits.durationMs == 3000)
        #expect(hits.year == 2001)

        // An artist's albums include ones they only appear on.
        let alphaID = try id(artist: "Alpha"), betaID = try id(artist: "Beta")
        let alpha = try db.writer.read { try LibraryQueries.albums(artistId: alphaID, $0) }
        #expect(Set(alpha.map(\.title)) == ["Hits", "Solo"])
        let beta = try db.writer.read { try LibraryQueries.albums(artistId: betaID, $0) }
        #expect(beta.map(\.title) == ["Hits"])
    }

    @Test func albumArtworkFallsBackToATracksArtwork() throws {
        try db.writer.write { d in
            try d.execute(sql: "UPDATE track SET artworkKey = 'abc' WHERE title = 'Encore'")
        }
        let hits = try db.writer.read { try LibraryQueries.albums($0) }.first { $0.title == "Hits" }
        #expect(hits?.artworkKey == "abc")
    }

    @Test func scopesSelectTheRightTracksInAlbumOrder() throws {
        #expect(try titles(.album(id(album: "Hits"))) == ["A Side", "B Side", "Encore"])
        #expect(try titles(.artist(id(artist: "Beta"))) == ["A Side", "Encore"])
        #expect(try titles(.artist(id(artist: "Various"))) == ["A Side", "B Side", "Encore"])
        // Album artist first (Alpha's Solo before Various' Hits), untagged last.
        #expect(try titles(.all) == ["Zed", "A Side", "B Side", "Encore", "Loose"])
    }

    @Test func sortsByColumnBothWaysWithNullsLast() throws {
        #expect(try titles(.all, TrackSort(.title)) == ["A Side", "B Side", "Encore", "Loose", "Zed"])
        #expect(try titles(.all, TrackSort(.title, ascending: false)) == ["Zed", "Loose", "Encore", "B Side", "A Side"])
        #expect(try titles(.all, TrackSort(.duration, ascending: false)).first == "Zed")
        #expect(try titles(.all, TrackSort(.year)) == ["Zed", "A Side", "B Side", "Encore", "Loose"])
        #expect(try titles(.all, TrackSort(.year, ascending: false)) == ["A Side", "B Side", "Encore", "Zed", "Loose"])
        // Artist ties fall back to album order; no artist goes last both ways.
        #expect(try titles(.all, TrackSort(.artist)) == ["Zed", "B Side", "A Side", "Encore", "Loose"])
        #expect(try titles(.all, TrackSort(.artist, ascending: false)).last == "Loose")
        for column in TrackSort.Column.allCases {
            for ascending in [true, false] {
                #expect(try titles(.all, TrackSort(column, ascending: ascending)).count == 5, "\(column)")
            }
        }
    }

    @Test func playlistsKeepTheirOrderAndRepeatedTracks() throws {
        let playlistID = try db.writer.write { d -> Int64 in
            var playlist = Playlist(name: "Mix", createdAt: Date(), updatedAt: Date())
            try playlist.insert(d)
            let ids = try Track.order(Column("title")).fetchAll(d).map(\.id!)
            for (position, trackId) in [ids[4], ids[0], ids[4]].enumerated() {
                var item = PlaylistItem(playlistId: playlist.id!, trackId: trackId, position: position)
                try item.insert(d)
            }
            return playlist.id!
        }
        let tracks = try db.writer.read { try LibraryQueries.tracks(in: .playlist(playlistID), sort: TrackSort(.playlistOrder), $0) }
        #expect(tracks.map(\.track.title) == ["Zed", "A Side", "Zed"])
        #expect(Set(tracks.map(\.id)).count == 3, "each playlist entry is its own row")
        #expect(try titles(.playlist(playlistID), TrackSort(.playlistOrder, ascending: false)) == ["Zed", "A Side", "Zed"])
        #expect(try titles(.playlist(playlistID), TrackSort(.title)) == ["A Side", "Zed", "Zed"])

        let playlists = try db.writer.read { try LibraryQueries.playlists($0) }
        #expect(playlists.map(\.name) == ["Mix"])
        #expect(playlists.first?.trackCount == 3)
    }

    /// List rows are read by position, so the column list must match the table exactly.
    @Test func listDecodingMatchesTheTable() throws {
        let columns = try db.writer.read { try $0.columns(in: "track").map(\.name) }
        #expect(columns == Track.columnNames, "add new track columns to Track.columnNames and init(row:at:)")

        try db.writer.write { d in
            try d.execute(sql: """
                UPDATE track SET genre = 'Jazz', bitsPerSample = 24, artworkKey = 'k', isEvicted = 1, \
                discNumber = 2, year = 2003 WHERE title = 'Encore'
                """)
        }
        let byName = try db.writer.read { try Track.order(Column("id")).fetchAll($0) }
        let listed = try db.writer.read { try LibraryQueries.tracks(in: .all, $0) }.map(\.track).sorted { $0.id! < $1.id! }
        #expect(listed == byName)
    }
}
