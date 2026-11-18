import Foundation
import GRDB

/// Finds a track's lyrics: what comes with the file first, then the online providers in the
/// order given, the first that has them winning. Each provider's answer (found or not) is
/// kept in the library, so a track is asked about once by each.
public struct LyricsFinder: Sendable {
    public enum Online: Sendable {
        /// Only what comes with the file.
        case off
        /// Also what the providers returned before, without asking them again.
        case cachedOnly
        /// Ask each provider that hasn't been asked about this track (or said "not found" a while ago).
        case automatic
        /// Ask every provider again, whatever it said before.
        case refresh
    }

    public enum Result: Sendable, Equatable {
        case found(FoundLyrics)
        /// `searchedOnline` is true when every provider was asked (now or before) and had nothing.
        case notFound(searchedOnline: Bool)
    }

    public struct MissingTags: Error, CustomStringConvertible {
        public var description: String { "Lyrics are searched for by title and artist, and this file's tags don't have both." }
    }

    /// A provider's "not found" is trusted for this long, then asked again (lyrics get added).
    static let notFoundExpiry: TimeInterval = 30 * 24 * 3600

    private let database: AppDatabase?
    private let providers: [any LyricsProvider]

    /// Without a database nothing is cached (files outside the library); without providers
    /// nothing is looked up. `providers` is the default order.
    public init(database: AppDatabase?, providers: [any LyricsProvider]) {
        self.database = database
        self.providers = providers
    }

    /// Every provider miniamp knows, in the default order.
    public static func standardProviders(userAgent: String) -> [any LyricsProvider] {
        [LRCLIB(userAgent: userAgent), NetEase(userAgent: userAgent), LyricsOvh(userAgent: userAgent)]
    }

    /// `using` picks and orders the providers to try; nil tries them all, in the default order.
    public func find(for url: URL, online: Online, using order: [LyricsProviderID]? = nil) async throws -> Result {
        if let local = await LocalLyrics.find(for: url) { return .found(local) }
        guard online != .off else { return .notFound(searchedOnline: false) }
        let chosen = order.map { ids in ids.compactMap { id in providers.first { $0.provider == id } } } ?? providers
        guard !chosen.isEmpty else { return .notFound(searchedOnline: false) }

        let path = LibraryPaths.canonical(url)
        let (trackId, cached) = try await database?.writer.read { db -> (Int64?, [String: LyricsLookup]) in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM track WHERE path = ?", arguments: [path]) else {
                return (nil, [:])
            }
            let rows = try LyricsLookup.filter(Column("trackId") == id).fetchAll(db)
            return (id, Dictionary(rows.map { ($0.provider, $0) }) { a, _ in a })
        } ?? (nil, [:])

        var query: LyricsQuery?
        var readTags = false
        var everyoneAsked = true
        var firstError: (any Error)?
        for provider in chosen {
            let id = provider.provider
            if let row = cached[id.rawValue], online != .refresh {
                if let found = row.found { return .found(found) }
                let fresh = Date().timeIntervalSince(row.fetchedAt) < Self.notFoundExpiry
                if fresh || online == .cachedOnly { continue }
            }
            guard online != .cachedOnly else {
                everyoneAsked = false
                continue
            }
            if !readTags {
                query = await Self.query(for: url)
                readTags = true
            }
            guard let query else { throw MissingTags() }
            let record: OnlineLyricsRecord?
            do {
                record = try await provider.lookUp(query)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch {
                // Down or refusing; the next provider may still have them.
                firstError = firstError ?? error
                everyoneAsked = false
                continue
            }
            if let trackId, let database {
                let row = LyricsLookup(trackId: trackId, provider: id, record: record, fetchedAt: Date())
                try await database.writer.write { try row.save($0) }
            }
            if let record, let lyrics = record.lyrics {
                return .found(FoundLyrics(lyrics: lyrics, source: .online(id, id: record.id)))
            }
        }
        if let firstError { throw firstError }
        return .notFound(searchedOnline: everyoneAsked)
    }

    @concurrent
    private static func query(for url: URL) async -> LyricsQuery? { LyricsQuery.for(url) }
}

/// A row of `lyricsLookup` (see Schema.v7): what one provider said about one track.
struct LyricsLookup: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lyricsLookup"

    var trackId: Int64
    var provider: String
    var recordId: String?
    var syncedLyrics: String?
    var plainLyrics: String?
    var instrumental: Bool
    var fetchedAt: Date

    init(trackId: Int64, provider: LyricsProviderID, record: OnlineLyricsRecord?, fetchedAt: Date) {
        self.trackId = trackId
        self.provider = provider.rawValue
        recordId = record?.id
        syncedLyrics = record?.syncedLyrics
        plainLyrics = record?.plainLyrics
        instrumental = record?.instrumental ?? false
        self.fetchedAt = fetchedAt
    }

    var found: FoundLyrics? {
        guard let recordId, let provider = LyricsProviderID(rawValue: provider) else { return nil }
        let record = OnlineLyricsRecord(provider: provider, id: recordId, syncedLyrics: syncedLyrics,
                                        plainLyrics: plainLyrics, instrumental: instrumental)
        return record.lyrics.map { FoundLyrics(lyrics: $0, source: .online(provider, id: recordId)) }
    }
}
