import Foundation
import GRDB

/// Per-track lyrics timing corrections (see Schema.v4).
public enum LyricsTiming {
    /// The correction for the library track at `url`; zero when there's none or it isn't in the library.
    public static func offset(for url: URL, _ db: Database) throws -> Duration {
        let ms = try Int.fetchOne(db, sql: """
            SELECT offsetMs FROM lyricsTiming JOIN track ON track.id = lyricsTiming.trackId WHERE track.path = ?
            """, arguments: [LibraryPaths.canonical(url)])
        return .milliseconds(ms ?? 0)
    }

    /// Saves the correction (zero removes it). Returns false when the file isn't in the library,
    /// so there's nowhere to keep it.
    @discardableResult
    public static func setOffset(_ offset: Duration, for url: URL, _ db: Database) throws -> Bool {
        guard let trackId = try Int64.fetchOne(db, sql: "SELECT id FROM track WHERE path = ?",
                                               arguments: [LibraryPaths.canonical(url)]) else { return false }
        if offset == .zero {
            try db.execute(sql: "DELETE FROM lyricsTiming WHERE trackId = ?", arguments: [trackId])
        } else {
            try db.execute(sql: "INSERT OR REPLACE INTO lyricsTiming (trackId, offsetMs) VALUES (?, ?)",
                           arguments: [trackId, offset.wholeMilliseconds])
        }
        return true
    }
}
