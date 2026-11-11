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

    /// Always a file: saying so keeps Foundation from checking the disk for every track.
    public var url: URL { URL(fileURLWithPath: path, isDirectory: false) }
    public var duration: Duration { .milliseconds(durationMs) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Track {
    /// Decoded by hand: lists load every track in the library, and the Codable decoder took
    /// about 4× as long as the query itself (66 ms vs 16 ms for 10,000 tracks).
    public init(row: Row) throws {
        id = row[Columns.id]
        folderId = row[Columns.folderId]
        path = row[Columns.path]
        fileSize = row[Columns.fileSize]
        modifiedAt = row[Columns.modifiedAt]
        title = row[Columns.title]
        artistId = row[Columns.artistId]
        albumId = row[Columns.albumId]
        genre = row[Columns.genre]
        year = row[Columns.year]
        trackNumber = row[Columns.trackNumber]
        discNumber = row[Columns.discNumber]
        durationMs = row[Columns.durationMs]
        sampleRate = row[Columns.sampleRate]
        bitsPerSample = row[Columns.bitsPerSample]
        channels = row[Columns.channels]
        bitrateKbps = row[Columns.bitrateKbps]
        codec = row[Columns.codec]
        artworkKey = row[Columns.artworkKey]
        addedAt = row[Columns.addedAt]
        isEvicted = row[Columns.isEvicted]
    }

    /// Every column, in the order `init(row:at:)` reads them.
    static let columnNames = [
        "id", "folderId", "path", "fileSize", "modifiedAt", "title", "artistId", "albumId", "genre", "year",
        "trackNumber", "discNumber", "durationMs", "sampleRate", "bitsPerSample", "channels", "bitrateKbps",
        "codec", "artworkKey", "addedAt", "isEvicted",
    ]

    /// Reads `columnNames` by position from `offset`. A third faster than by name, which
    /// matters when a list loads the whole library; only for SQL that selects that exact list.
    init(row: Row, at offset: Int) {
        id = row[offset]
        folderId = row[offset + 1]
        path = row[offset + 2]
        fileSize = row[offset + 3]
        modifiedAt = row[offset + 4]
        title = row[offset + 5]
        artistId = row[offset + 6]
        albumId = row[offset + 7]
        genre = row[offset + 8]
        year = row[offset + 9]
        trackNumber = row[offset + 10]
        discNumber = row[offset + 11]
        durationMs = row[offset + 12]
        sampleRate = row[offset + 13]
        bitsPerSample = row[offset + 14]
        channels = row[offset + 15]
        bitrateKbps = row[offset + 16]
        codec = row[offset + 17]
        artworkKey = row[offset + 18]
        addedAt = row[offset + 19]
        isEvicted = row[offset + 20]
    }

    /// Typed column names (GRDB's TableRecord.Columns).
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let folderId = Column(CodingKeys.folderId)
        public static let path = Column(CodingKeys.path)
        public static let fileSize = Column(CodingKeys.fileSize)
        public static let modifiedAt = Column(CodingKeys.modifiedAt)
        public static let title = Column(CodingKeys.title)
        public static let artistId = Column(CodingKeys.artistId)
        public static let albumId = Column(CodingKeys.albumId)
        public static let genre = Column(CodingKeys.genre)
        public static let year = Column(CodingKeys.year)
        public static let trackNumber = Column(CodingKeys.trackNumber)
        public static let discNumber = Column(CodingKeys.discNumber)
        public static let durationMs = Column(CodingKeys.durationMs)
        public static let sampleRate = Column(CodingKeys.sampleRate)
        public static let bitsPerSample = Column(CodingKeys.bitsPerSample)
        public static let channels = Column(CodingKeys.channels)
        public static let bitrateKbps = Column(CodingKeys.bitrateKbps)
        public static let codec = Column(CodingKeys.codec)
        public static let artworkKey = Column(CodingKeys.artworkKey)
        public static let addedAt = Column(CodingKeys.addedAt)
        public static let isEvicted = Column(CodingKeys.isEvicted)
    }
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
    /// Set in playlist listings, where the same track can appear more than once.
    public var playlistItemId: Int64?

    /// The playlist item in a playlist listing, otherwise the track. Unique within one list.
    public var id: Int64 { playlistItemId ?? track.id ?? 0 }

    public init(row: Row) throws {
        let n = Track.columnNames.count
        track = Track(row: row, at: 0)
        artistName = row[n]
        albumTitle = row[n + 1]
        albumArtistName = row[n + 2]
        playlistItemId = row.count > n + 3 ? row[n + 3] : nil
    }

    /// The columns `init(row:)` reads, by position. Add more after these.
    static let selectColumns = Track.columnNames.map { "track.\($0)" }.joined(separator: ", ")
        + ", artist.name AS artistName, album.title AS albumTitle, albumArtist.name AS albumArtistName"

    /// Select this from `track` to fetch TrackInfo rows; add WHERE / ORDER BY after it.
    static let selectSQL = """
        SELECT \(selectColumns)
        FROM track
        LEFT JOIN artist ON artist.id = track.artistId
        LEFT JOIN album ON album.id = track.albumId
        LEFT JOIN artist AS albumArtist ON albumArtist.id = album.artistId
        """
}
