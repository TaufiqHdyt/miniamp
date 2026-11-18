import Foundation

/// Plain (unsynced) lyrics from Lyrics.ovh (api.lyrics.ovh), a free API with no key. A last
/// resort: there are no times to follow.
///
/// It sends the track's artist and title, and nothing else.
public struct LyricsOvh: LyricsProvider {
    public static let baseURL = URL(string: "https://api.lyrics.ovh/v1/")!

    public var provider: LyricsProviderID { .lyricsOvh }
    private let http: LyricsHTTP
    private let base: URL

    public init(userAgent: String, configuration: URLSessionConfiguration = .ephemeral, base: URL = LyricsOvh.baseURL) {
        http = LyricsHTTP(provider: .lyricsOvh, userAgent: userAgent, configuration: configuration)
        self.base = base
    }

    struct Response: Decodable { var lyrics: String? }

    public func lookUp(_ query: LyricsQuery) async throws -> OnlineLyricsRecord? {
        // Slashes in a name ("AC/DC") are part of it, not of the path.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let artist = query.artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let title = query.title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: artist + "/" + title, relativeTo: base) else { return nil }
        let response: Response? = try await http.get(url)
        guard let text = response?.lyrics.map(Self.cleaned).nonBlank else { return nil }
        let record = OnlineLyricsRecord(provider: .lyricsOvh, id: "\(query.artist)/\(query.title)", plainLyrics: text)
        return record.lyrics == nil ? nil : record
    }

    /// Unix line ends, and without the "Paroles de la chanson … par …" heading it sometimes
    /// puts first.
    static func cleaned(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.hasPrefix("Paroles de la chanson") == true { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
