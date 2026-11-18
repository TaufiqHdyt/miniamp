import Foundation

/// Lyrics from NetEase Cloud Music (music.163.com), through the public API its web player
/// uses. Mostly synced, with a large catalogue of Asian and Western music.
///
/// It sends the track's title and artist as a search, and nothing else.
public struct NetEase: LyricsProvider {
    public static let baseURL = URL(string: "https://music.163.com/api/")!
    /// Search results whose duration is this close to the track's count as a match.
    static let durationTolerance = 3.0
    /// How many matching songs are tried for lyrics before giving up.
    static let candidates = 3

    public var provider: LyricsProviderID { .netease }
    private let http: LyricsHTTP
    private let base: URL

    public init(userAgent: String, configuration: URLSessionConfiguration = .ephemeral, base: URL = NetEase.baseURL) {
        http = LyricsHTTP(provider: .netease, userAgent: userAgent, configuration: configuration)
        self.base = base
    }

    struct SearchResponse: Decodable {
        struct Result: Decodable { var songs: [Song]? }
        var result: Result?
    }

    struct Song: Decodable {
        struct Artist: Decodable { var name: String }
        var id: Int
        var name: String
        /// Milliseconds.
        var duration: Int?
        var artists: [Artist]?
    }

    struct LyricResponse: Decodable {
        struct Text: Decodable { var lyric: String? }
        var lrc: Text?
    }

    public func lookUp(_ query: LyricsQuery) async throws -> OnlineLyricsRecord? {
        let search = base.appendingPathComponent("search/get").appending(queryItems: [
            URLQueryItem(name: "s", value: "\(query.title) \(query.artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ])
        let response: SearchResponse? = try await http.get(search)
        for song in Self.matches(response?.result?.songs ?? [], for: query).prefix(Self.candidates) {
            let url = base.appendingPathComponent("song/lyric").appending(queryItems: [
                URLQueryItem(name: "id", value: String(song.id)),
                URLQueryItem(name: "lv", value: "1"),
            ])
            let lyric: LyricResponse? = try await http.get(url)
            guard let text = lyric?.lrc?.lyric.nonBlank else { continue }
            if text.contains("纯音乐，请欣赏") {
                return OnlineLyricsRecord(provider: .netease, id: String(song.id), instrumental: true)
            }
            let record = OnlineLyricsRecord(provider: .netease, id: String(song.id), syncedLyrics: Self.withoutCredits(text))
            if record.lyrics != nil { return record }
        }
        return nil
    }

    /// The search results by the track's artist, within a few seconds of its length: an exact
    /// title first, then the closest length.
    static func matches(_ songs: [Song], for query: LyricsQuery) -> [Song] {
        let seconds = query.seconds
        let title = query.title.lyricsMatchKey
        let artist = query.artist.lyricsMatchKey
        return songs
            .filter { song in
                guard let duration = song.duration, abs(Double(duration) / 1000 - seconds) <= durationTolerance else { return false }
                return (song.artists ?? []).contains { candidate in
                    let name = candidate.name.lyricsMatchKey
                    return !name.isEmpty && (artist.contains(name) || name.contains(artist))
                }
            }
            .sorted { a, b in
                let rank = { (s: Song) in (s.name.lyricsMatchKey == title ? 0 : 1, abs(Double(s.duration ?? 0) / 1000 - seconds)) }
                return rank(a) < rank(b)
            }
    }

    /// NetEase opens most lyrics with credit lines ("作词 : …", "Producer : …"); they aren't sung.
    static func withoutCredits(_ lrc: String) -> String {
        lrc.components(separatedBy: .newlines)
            .filter { line in
                let text = line.replacing(/^(\[[^\]]*\])+/, with: "").trimmingCharacters(in: .whitespaces)
                return text.firstMatch(of: creditLine) == nil
            }
            .joined(separator: "\n")
    }

    nonisolated(unsafe) private static let creditLine =
        /^(作词|作曲|编曲|制作人|制作|监制|混音|母带|和声|录音|出品|发行|企划|统筹|吉他|贝斯|鼓|键盘|弦乐|词|曲|lyricist|lyrics by|composer|composed by|producer|produced by|arranger|arranged by|mixing|mixed by|mastering|mastered by|written by)\s*[:：]/
            .ignoresCase()
}
