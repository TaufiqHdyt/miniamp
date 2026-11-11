import Foundation
import GRDB

public struct LibraryFolder: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "libraryFolder"
    public var id: Int64?
    public var path: String
    public var bookmark: Data
    public var addedAt: Date
    public var lastScannedAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Artist: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Album: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var title: String
    /// The album artist.
    public var artistId: Int64?
    public var year: Int?
    public var artworkKey: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Track: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var folderId: Int64
    public var path: String
    public var fileSize: Int64
    public var modifiedAt: Double
    public var title: String
    public var artistId: Int64?
    public var albumId: Int64?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var durationMs: Int
    public var sampleRate: Int
    public var bitsPerSample: Int?
    public var channels: Int
    public var bitrateKbps: Int
    public var codec: String
    public var artworkKey: String?
    public var addedAt: Date
    /// The file's data is only in the cloud (see CloudFiles). If its tags were never read, the
    /// title is the file name and the audio properties are zero.
    public var isEvicted = false

    public var url: URL { URL(fileURLWithPath: path) }
    public var duration: Duration { .milliseconds(durationMs) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Playlist: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PlaylistItem: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var playlistId: Int64
    public var trackId: Int64
    public var position: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Play: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var trackId: Int64
    public var playedAt: Date
    public var listenedMs: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A track with its artist and album names, for lists and search results.
public struct TrackInfo: Sendable, Hashable, Identifiable, FetchableRecord {
    public var track: Track
    public var artistName: String?
    public var albumTitle: String?
    public var albumArtistName: String?

    public var id: Int64 { track.id ?? 0 }

    public init(row: Row) throws {
        track = try Track(row: row)
        artistName = row["artistName"]
        albumTitle = row["albumTitle"]
        albumArtistName = row["albumArtistName"]
    }

    /// Select this from `track` to fetch TrackInfo rows; add WHERE / ORDER BY after it.
    static let selectSQL = """
        SELECT track.*, artist.name AS artistName, album.title AS albumTitle, albumArtist.name AS albumArtistName
        FROM track
        LEFT JOIN artist ON artist.id = track.artistId
        LEFT JOIN album ON album.id = track.albumId
        LEFT JOIN artist AS albumArtist ON albumArtist.id = album.artistId
        """
}
