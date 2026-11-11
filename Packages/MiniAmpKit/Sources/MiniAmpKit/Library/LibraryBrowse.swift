import Foundation
import GRDB

/// An artist with tracks in the library, either as the track artist or as an album's artist.
public struct ArtistSummary: Sendable, Hashable, Identifiable, FetchableRecord, Decodable {
    public var id: Int64
    public var name: String
    public var albumCount: Int
    public var trackCount: Int
}

public struct AlbumSummary: Sendable, Hashable, Identifiable, FetchableRecord, Decodable {
    public var id: Int64
    public var title: String
    /// The album artist.
    public var artistName: String?
    public var year: Int?
    /// The album's cover, or else the first track's that has one.
    public var artworkKey: String?
    public var trackCount: Int
    public var durationMs: Int
}

public struct PlaylistSummary: Sendable, Hashable, Identifiable, FetchableRecord, Decodable {
    public var id: Int64
    public var name: String
    public var trackCount: Int
}

/// Which tracks a list shows.
public enum TrackScope: Sendable, Hashable {
    case all
    /// Tracks by the artist, or on an album the artist owns.
    case artist(Int64)
    case album(Int64)
    case playlist(Int64)
}

/// A track list's sort order. Ties fall back to album order (album artist, album, disc, track).
public struct TrackSort: Sendable, Hashable {
    public enum Column: String, Sendable, CaseIterable {
        /// Album artist, album, disc, track. The natural order for an album or artist.
        case albumOrder
        /// A playlist's own order. Same as album order outside a playlist.
        case playlistOrder
        /// Best search matches first. Same as album order outside a search.
        case relevance
        case title, artist, album, trackNumber, duration, year, genre, quality, dateAdded
    }

    public var column: Column
    public var ascending: Bool

    public init(_ column: Column, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    public static let albumOrder = TrackSort(.albumOrder)

    /// Nulls sort last whichever way the column goes, so untagged tracks don't crowd the top.
    /// `relevance` is the ORDER BY term for search rank, when listing search results.
    func orderBy(inPlaylist: Bool, relevance: String? = nil) -> String {
        let direction = ascending ? "ASC" : "DESC"
        let primary: String
        switch column {
        case .albumOrder: return Self.albumOrder(direction) + ", track.id"
        case .relevance:
            guard let relevance else { return Self.albumOrder(direction) + ", track.id" }
            return "\(relevance) \(direction), track.id"
        case .playlistOrder:
            return inPlaylist ? "playlistItem.position \(direction)" : Self.albumOrder(direction) + ", track.id"
        case .title: primary = "track.title COLLATE NOCASE \(direction)"
        case .artist: primary = "artist.name IS NULL, artist.name COLLATE NOCASE \(direction)"
        case .album: primary = "album.title IS NULL, album.title COLLATE NOCASE \(direction)"
        case .trackNumber: primary = "ifnull(track.discNumber, 1) \(direction), track.trackNumber IS NULL, track.trackNumber \(direction)"
        case .duration: primary = "track.durationMs \(direction)"
        case .year: primary = "ifnull(track.year, album.year) IS NULL, ifnull(track.year, album.year) \(direction)"
        case .genre: primary = "track.genre IS NULL, track.genre COLLATE NOCASE \(direction)"
        case .quality: primary = "track.sampleRate \(direction), ifnull(track.bitsPerSample, 0) \(direction), track.bitrateKbps \(direction)"
        case .dateAdded: primary = "track.addedAt \(direction)"
        }
        return "\(primary), \(Self.albumOrder("ASC")), track.id"
    }

    private static func albumOrder(_ direction: String) -> String {
        """
        ifnull(albumArtist.name, artist.name) IS NULL, ifnull(albumArtist.name, artist.name) COLLATE NOCASE \(direction), \
        album.title IS NULL, album.title COLLATE NOCASE \(direction), \
        ifnull(track.discNumber, 1) \(direction), track.trackNumber IS NULL, track.trackNumber \(direction), \
        track.title COLLATE NOCASE \(direction)
        """
    }
}

extension LibraryQueries {
    /// Artists by name. Counts include tracks on albums the artist owns.
    public static func artists(_ db: Database) throws -> [ArtistSummary] {
        try ArtistSummary.fetchAll(db, sql: """
            SELECT artist.id, artist.name,
                   (SELECT count(*) FROM album WHERE album.artistId = artist.id
                      AND EXISTS (SELECT 1 FROM track WHERE track.albumId = album.id)) AS albumCount,
                   (SELECT count(*) FROM track LEFT JOIN album ON album.id = track.albumId
                      WHERE track.artistId = artist.id OR album.artistId = artist.id) AS trackCount
            FROM artist
            WHERE EXISTS (SELECT 1 FROM track WHERE track.artistId = artist.id)
               OR EXISTS (SELECT 1 FROM album JOIN track ON track.albumId = album.id WHERE album.artistId = artist.id)
            ORDER BY artist.name COLLATE NOCASE
            """)
    }

    /// Albums with at least one track, by album artist then title. `artistId` limits them to
    /// albums the artist owns or appears on.
    public static func albums(artistId: Int64? = nil, _ db: Database) throws -> [AlbumSummary] {
        let filter = artistId == nil ? "" : """
            WHERE album.artistId = :artist
               OR EXISTS (SELECT 1 FROM track WHERE track.albumId = album.id AND track.artistId = :artist)
            """
        return try AlbumSummary.fetchAll(db, sql: """
            SELECT album.id, album.title, artist.name AS artistName,
                   ifnull(album.year, max(track.year)) AS year,
                   ifnull(album.artworkKey, min(track.artworkKey)) AS artworkKey,
                   count(track.id) AS trackCount, sum(track.durationMs) AS durationMs
            FROM album
            JOIN track ON track.albumId = album.id
            LEFT JOIN artist ON artist.id = album.artistId
            \(filter)
            GROUP BY album.id
            ORDER BY artist.name IS NULL, artist.name COLLATE NOCASE, album.title COLLATE NOCASE
            """, arguments: ["artist": artistId])
    }

    public static func playlists(_ db: Database) throws -> [PlaylistSummary] {
        try PlaylistSummary.fetchAll(db, sql: """
            SELECT playlist.id, playlist.name,
                   (SELECT count(*) FROM playlistItem WHERE playlistItem.playlistId = playlist.id) AS trackCount
            FROM playlist
            ORDER BY playlist.name COLLATE NOCASE
            """)
    }

    /// The tracks in `scope`, sorted. A playlist can hold a track more than once; each entry
    /// is its own row, identified by its playlist item (see `TrackInfo.id`).
    public static func tracks(in scope: TrackScope, sort: TrackSort = .albumOrder, limit: Int? = nil,
                              _ db: Database) throws -> [TrackInfo] {
        var sql = TrackInfo.selectSQL
        var arguments: StatementArguments = [:]
        var inPlaylist = false
        switch scope {
        case .all:
            break
        case .artist(let id):
            sql += "\nWHERE track.artistId = :id OR album.artistId = :id"
            arguments = ["id": id]
        case .album(let id):
            sql += "\nWHERE track.albumId = :id"
            arguments = ["id": id]
        case .playlist(let id):
            sql = sql.replacingOccurrences(of: "SELECT track.*,", with: "SELECT track.*, playlistItem.id AS playlistItemId,")
            sql += "\nJOIN playlistItem ON playlistItem.trackId = track.id\nWHERE playlistItem.playlistId = :id"
            arguments = ["id": id]
            inPlaylist = true
        }
        sql += "\nORDER BY " + sort.orderBy(inPlaylist: inPlaylist)
        if let limit {
            sql += "\nLIMIT :limit"
            _ = arguments.append(contentsOf: ["limit": limit])
        }
        return try TrackInfo.fetchAll(db, sql: sql, arguments: arguments)
    }
}
