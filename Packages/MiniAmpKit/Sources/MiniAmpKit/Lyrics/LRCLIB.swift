import Foundation

/// A client for LRCLIB (lrclib.net), a free, open database of synced lyrics.
///
/// It sends the track's title, artist, album, and duration, and nothing else.
public struct LRCLIB: LyricsProvider {
    public typealias Query = LyricsQuery

    public struct Record: Sendable, Equatable, Codable {
        public var id: Int
        public var trackName: String?
        public var artistName: String?
        public var albumName: String?
        /// Seconds.
        public var duration: Double?
        public var instrumental: Bool
        public var plainLyrics: String?
        public var syncedLyrics: String?

        public init(id: Int, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil,
                    duration: Double? = nil, instrumental: Bool = false, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
            self.id = id
            self.trackName = trackName
            self.artistName = artistName
            self.albumName = albumName
            self.duration = duration
            self.instrumental = instrumental
            self.plainLyrics = plainLyrics
            self.syncedLyrics = syncedLyrics
        }

        var online: OnlineLyricsRecord {
            OnlineLyricsRecord(provider: .lrclib, id: String(id), syncedLyrics: syncedLyrics, plainLyrics: plainLyrics,
                               instrumental: instrumental)
        }

        /// The synced lyrics if there are any, else the plain ones; nil when it has neither.
        public var lyrics: Lyrics? { online.lyrics }
    }

    public static let baseURL = URL(string: "https://lrclib.net/api/")!
    /// Search results whose duration is this close to the track's count as a match.
    static let durationTolerance = 3.0

    public var provider: LyricsProviderID { .lrclib }
    private let http: LyricsHTTP
    private let base: URL

    /// `userAgent` should name the app and its version, as LRCLIB asks.
    public init(userAgent: String, configuration: URLSessionConfiguration = .ephemeral, base: URL = LRCLIB.baseURL) {
        http = LyricsHTTP(provider: .lrclib, userAgent: userAgent, configuration: configuration)
        self.base = base
    }

    public func lookUp(_ query: LyricsQuery) async throws -> OnlineLyricsRecord? {
        try await record(for: query)?.online
    }

    /// The best record for the track, or nil when LRCLIB has none.
    ///
    /// Asks for an exact match first (title, artist, album, and duration within 2 seconds);
    /// failing that, searches by title and artist and takes the closest duration, synced first.
    public func record(for query: LyricsQuery) async throws -> Record? {
        let seconds = query.seconds
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        if let album = query.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        items.append(URLQueryItem(name: "duration", value: String(Int(seconds.rounded()))))
        if let record: Record = try await get("get", items), record.lyrics != nil { return record }

        let found: [Record] = try await get("search", Array(items.prefix(2))) ?? []
        return found
            .filter { $0.lyrics != nil && abs(($0.duration ?? .infinity) - seconds) <= Self.durationTolerance }
            .min { a, b in
                // Synced beats plain; then the closer duration.
                let rank = { (r: Record) in (r.syncedLyrics.nonBlank == nil ? 1 : 0, abs((r.duration ?? 0) - seconds)) }
                return rank(a) < rank(b)
            }
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T? {
        try await http.get(base.appendingPathComponent(path).appending(queryItems: items))
    }
}
