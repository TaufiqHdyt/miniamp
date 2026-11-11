import Foundation

/// A client for LRCLIB (lrclib.net), a free, open database of synced lyrics.
///
/// It sends the track's title, artist, album, and duration, and nothing else.
public struct LRCLIB: Sendable {
    public struct Query: Sendable, Equatable {
        public var title: String
        public var artist: String
        public var album: String?
        public var duration: Duration

        public init(title: String, artist: String, album: String? = nil, duration: Duration) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
        }

        /// The query for a file, from its tags; nil without a title and an artist to search by.
        public static func `for`(_ url: URL) -> Query? {
            guard let tags = TagReader.read(url),
                  let title = tags.title.nonBlank, let artist = tags.artist.nonBlank ?? tags.albumArtist.nonBlank else { return nil }
            return Query(title: title, artist: artist, album: tags.album.nonBlank, duration: tags.duration)
        }
    }

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

        /// The synced lyrics if there are any, else the plain ones; nil when it has neither.
        public var lyrics: Lyrics? {
            if instrumental { return .instrumental }
            for text in [syncedLyrics, plainLyrics] {
                if let text, case let lyrics = Lyrics(lrc: text), !lyrics.isEmpty { return lyrics }
            }
            return nil
        }
    }

    public struct ServiceError: Error, CustomStringConvertible {
        public var status: Int
        public var description: String { "LRCLIB answered \(status)" }
    }

    public static let baseURL = URL(string: "https://lrclib.net/api/")!
    /// Search results whose duration is this close to the track's count as a match.
    static let durationTolerance = 3.0

    private let session: URLSession
    private let base: URL
    private let userAgent: String

    /// `userAgent` should name the app and its version, as LRCLIB asks.
    public init(userAgent: String, configuration: URLSessionConfiguration = .ephemeral, base: URL = LRCLIB.baseURL) {
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.base = base
        self.userAgent = userAgent
    }

    /// The best record for the track, or nil when LRCLIB has none.
    ///
    /// Asks for an exact match first (title, artist, album, and duration within 2 seconds);
    /// failing that, searches by title and artist and takes the closest duration, synced first.
    public func lookUp(_ query: Query) async throws -> Record? {
        let seconds = Double(query.duration.wholeMilliseconds) / 1000
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

    /// Decodes the response; nil on 404 (LRCLIB's "not found").
    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T? {
        let url = base.appendingPathComponent(path).appending(queryItems: items)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw ServiceError(status: status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
