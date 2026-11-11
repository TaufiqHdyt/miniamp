import Foundation
import GRDB

/// Play history rows (see PlayHistory for when a play counts).
public enum Plays {
    /// Records a play of the library track at `url`. Returns the row's id, or nil when the file
    /// isn't in the library (opened from elsewhere), which leaves nothing to record against.
    public static func record(_ url: URL, playedAt: Date, listened: Duration, _ db: Database) throws -> Int64? {
        let path = LibraryPaths.canonical(url)
        guard let trackId = try Int64.fetchOne(db, sql: "SELECT id FROM track WHERE path = ?", arguments: [path]) else {
            return nil
        }
        var play = Play(trackId: trackId, playedAt: playedAt, listenedMs: listened.wholeMilliseconds)
        try play.insert(db)
        return play.id
    }

    /// Updates how long a recorded play was listened to, as listening goes on.
    public static func update(_ id: Int64, listened: Duration, _ db: Database) throws {
        try db.execute(sql: "UPDATE play SET listenedMs = ? WHERE id = ?", arguments: [listened.wholeMilliseconds, id])
    }

    /// The latest plays, newest first, with their tracks.
    public static func recent(limit: Int, _ db: Database) throws -> [(play: Play, info: TrackInfo)] {
        // TrackInfo reads the column after its own as a playlist item id, so that one is NULL.
        let n = Track.columnNames.count + 4
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(TrackInfo.selectColumns), NULL AS playlistItemId, play.id AS playId, play.playedAt, play.listenedMs
            FROM play
            JOIN track ON track.id = play.trackId
            LEFT JOIN artist ON artist.id = track.artistId
            LEFT JOIN album ON album.id = track.albumId
            LEFT JOIN artist AS albumArtist ON albumArtist.id = album.artistId
            ORDER BY play.playedAt DESC, play.id DESC
            LIMIT ?
            """, arguments: [limit])
        return try rows.map { row in
            let info = try TrackInfo(row: row)
            return (Play(id: row[n], trackId: info.track.id!, playedAt: row[n + 1], listenedMs: row[n + 2]), info)
        }
    }
}
