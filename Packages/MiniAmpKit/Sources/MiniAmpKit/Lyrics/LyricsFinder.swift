import Foundation
import GRDB

/// Finds a track's lyrics: what comes with the file first, then LRCLIB, whose answers (found
/// or not) are kept in the library so each track is asked about once.
public struct LyricsFinder: Sendable {
    public enum Online: Sendable {
        /// Only what comes with the file.
        case off
        /// Also what LRCLIB returned before, without asking it again.
        case cachedOnly
        /// Ask LRCLIB when it hasn't been asked about this track (or said "not found" a while ago).
        case automatic
        /// Ask LRCLIB again, whatever it said before.
        case refresh
    }

    public enum Result: Sendable, Equatable {
        case found(FoundLyrics)
        /// `searchedOnline` is true when LRCLIB was asked (now or before) and had nothing.
        case notFound(searchedOnline: Bool)
    }

    public struct MissingTags: Error, CustomStringConvertible {
        public var description: String { "LRCLIB is searched by title and artist, and this file's tags don't have both." }
    }

    /// LRCLIB's "not found" is trusted for this long, then asked again (lyrics get added).
    static let notFoundExpiry: TimeInterval = 30 * 24 * 3600

    private let database: AppDatabase?
    private let client: LRCLIB?

    /// Without a database nothing is cached (files outside the library); without a client
    /// nothing is looked up.
    public init(database: AppDatabase?, client: LRCLIB?) {
        self.database = database
        self.client = client
    }

    public func find(for url: URL, online: Online) async throws -> Result {
        if let local = await LocalLyrics.find(for: url) { return .found(local) }
        guard online != .off else { return .notFound(searchedOnline: false) }

        let path = LibraryPaths.canonical(url)
        let (trackId, cached) = try await database?.writer.read { db -> (Int64?, OnlineLyrics?) in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM track WHERE path = ?", arguments: [path]) else {
                return (nil, nil)
            }
            return (id, try OnlineLyrics.fetchOne(db, key: id))
        } ?? (nil, nil)

        if let cached, online != .refresh {
            if let found = cached.found { return .found(found) }
            let fresh = Date().timeIntervalSince(cached.fetchedAt) < Self.notFoundExpiry
            if fresh || online == .cachedOnly { return .notFound(searchedOnline: true) }
        }
        guard online != .cachedOnly, let client else { return .notFound(searchedOnline: false) }

        guard let query = await Self.query(for: url) else { throw MissingTags() }
        let record = try await client.lookUp(query)
        if let trackId, let database {
            let row = OnlineLyrics(trackId: trackId, record: record, fetchedAt: Date())
            try await database.writer.write { try row.save($0) }
        }
        guard let record, let lyrics = record.lyrics else { return .notFound(searchedOnline: true) }
        return .found(FoundLyrics(lyrics: lyrics, source: .lrclib(id: record.id)))
    }

    @concurrent
    private static func query(for url: URL) async -> LRCLIB.Query? { LRCLIB.Query.for(url) }
}

/// A row of `onlineLyrics` (see Schema.v3).
struct OnlineLyrics: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "onlineLyrics"

    var trackId: Int64
    var lrclibId: Int?
    var syncedLyrics: String?
    var plainLyrics: String?
    var instrumental: Bool
    var fetchedAt: Date

    init(trackId: Int64, record: LRCLIB.Record?, fetchedAt: Date) {
        self.trackId = trackId
        lrclibId = record?.id
        syncedLyrics = record?.syncedLyrics
        plainLyrics = record?.plainLyrics
        instrumental = record?.instrumental ?? false
        self.fetchedAt = fetchedAt
    }

    var found: FoundLyrics? {
        guard let lrclibId else { return nil }
        let record = LRCLIB.Record(id: lrclibId, instrumental: instrumental, plainLyrics: plainLyrics, syncedLyrics: syncedLyrics)
        return record.lyrics.map { FoundLyrics(lyrics: $0, source: .lrclib(id: lrclibId)) }
    }
}
