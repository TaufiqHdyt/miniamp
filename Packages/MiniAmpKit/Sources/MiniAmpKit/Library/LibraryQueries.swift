import Foundation
import GRDB

/// Read-only queries over the library.
public enum LibraryQueries {
    /// Turns what someone typed into an FTS5 query: every word must match the start of a word
    /// in the title, artist, album, album artist, or genre. Nil when there's nothing to search for.
    public static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Best matches first: title hits outrank artist and album hits, which outrank genre.
    public static func search(_ text: String, limit: Int = 200, _ db: Database) throws -> [TrackInfo] {
        guard let query = ftsQuery(text) else { return [] }
        return try TrackInfo.fetchAll(db, sql: TrackInfo.selectSQL + """

            JOIN trackSearch ON trackSearch.rowid = track.id
            WHERE trackSearch MATCH ?
            ORDER BY bm25(trackSearch, 4.0, 3.0, 3.0, 2.0, 1.0)
            LIMIT ?
            """, arguments: [query, limit])
    }

    /// The library in album order: album artist, album, disc, track number, then title.
    public static func allTracks(limit: Int = 1000, _ db: Database) throws -> [TrackInfo] {
        try TrackInfo.fetchAll(db, sql: TrackInfo.selectSQL + """

            ORDER BY ifnull(albumArtist.name, artist.name) COLLATE NOCASE, album.title COLLATE NOCASE,
                     track.discNumber, track.trackNumber, track.title COLLATE NOCASE
            LIMIT ?
            """, arguments: [limit])
    }

    /// Artwork keys any track or album refers to (for ArtworkCache.prune).
    public static func artworkKeys(_ db: Database) throws -> Set<String> {
        try Set(String.fetchAll(db, sql: """
            SELECT artworkKey FROM track WHERE artworkKey IS NOT NULL
            UNION SELECT artworkKey FROM album WHERE artworkKey IS NOT NULL
            """))
    }
}
