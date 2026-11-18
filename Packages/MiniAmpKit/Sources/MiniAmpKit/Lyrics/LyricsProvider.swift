import Foundation

/// What an online lyrics provider is asked: the track's title, artist, album, and duration,
/// and nothing else.
public struct LyricsQuery: Sendable, Equatable {
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
    public static func `for`(_ url: URL) -> LyricsQuery? {
        guard let tags = TagReader.read(url),
              let title = tags.title.nonBlank, let artist = tags.artist.nonBlank ?? tags.albumArtist.nonBlank else { return nil }
        return LyricsQuery(title: title, artist: artist, album: tags.album.nonBlank, duration: tags.duration)
    }

    var seconds: Double { Double(duration.wholeMilliseconds) / 1000 }
}

/// The online lyrics providers miniamp knows, in their default order.
public enum LyricsProviderID: String, Sendable, Codable, CaseIterable, Identifiable {
    case lrclib
    case netease
    case lyricsOvh

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .lrclib: "LRCLIB"
        case .netease: "NetEase Cloud Music"
        case .lyricsOvh: "Lyrics.ovh"
        }
    }

    /// Where the query goes.
    public var host: String {
        switch self {
        case .lrclib: "lrclib.net"
        case .netease: "music.163.com"
        case .lyricsOvh: "api.lyrics.ovh"
        }
    }

    /// Only LRCLIB is asked until another is turned on: each one is sent what's playing.
    public var isOnByDefault: Bool { self == .lrclib }
}

/// What a provider found for a track.
public struct OnlineLyricsRecord: Sendable, Equatable {
    public var provider: LyricsProviderID
    /// The provider's own id for what it found.
    public var id: String
    public var syncedLyrics: String?
    public var plainLyrics: String?
    public var instrumental: Bool

    public init(provider: LyricsProviderID, id: String, syncedLyrics: String? = nil, plainLyrics: String? = nil,
                instrumental: Bool = false) {
        self.provider = provider
        self.id = id
        self.syncedLyrics = syncedLyrics
        self.plainLyrics = plainLyrics
        self.instrumental = instrumental
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

/// An online source of lyrics, asked by `LyricsFinder` when a track has none of its own.
public protocol LyricsProvider: Sendable {
    var provider: LyricsProviderID { get }
    /// The best match for the track, or nil when the provider has none.
    func lookUp(_ query: LyricsQuery) async throws -> OnlineLyricsRecord?
}

/// A provider answered with an HTTP error.
public struct LyricsServiceError: Error, CustomStringConvertible {
    public var provider: LyricsProviderID
    public var status: Int
    public var description: String { "\(provider.name) answered \(status)" }
}

/// The HTTP side shared by the providers: an ephemeral session with no cache, and the
/// app's User-Agent on every request.
struct LyricsHTTP: Sendable {
    let provider: LyricsProviderID
    private let session: URLSession
    private let userAgent: String

    init(provider: LyricsProviderID, userAgent: String, configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.provider = provider
        self.userAgent = userAgent
    }

    /// Decodes the response; nil on 404 (the usual "not found").
    func get<T: Decodable>(_ url: URL) async throws -> T? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw LyricsServiceError(provider: provider, status: status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension String {
    /// For loose comparison of titles and artists: lowercased, without diacritics or width
    /// differences, and with runs of whitespace as one space.
    var lyricsMatchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
