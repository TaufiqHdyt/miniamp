import Foundation
import GRDB

/// The shelves on Home, all from what's in the library and the play history.
public struct HomeShelves: Sendable, Equatable {
    public var recentlyAdded: [AlbumSummary] = []
    public var recentlyPlayed: [AlbumSummary] = []
    /// The most played songs of the last 30 days.
    public var topThisMonth: [TrackInfo] = []
    /// Albums played often, but not in the last two months.
    public var rediscover: [AlbumSummary] = []

    public init() {}

    public var isEmpty: Bool { recentlyAdded.isEmpty && recentlyPlayed.isEmpty && topThisMonth.isEmpty && rediscover.isEmpty }
}

/// What an artist's page shows.
public struct ArtistPage: Sendable, Equatable {
    public var artist: ArtistSummary
    /// Their most played songs, then the rest in album order, up to ten.
    public var topSongs: [TrackInfo]
    /// Plays of each of `topSongs`, by track id; songs never played aren't in it.
    public var plays: [Int64: Int]
    /// Albums they're the album artist of (alone or in a shared credit), newest first.
    public var albums: [AlbumSummary]
    /// Albums with a song of theirs on, owned by someone else.
    public var appearsOn: [AlbumSummary]
}

extension LibraryQueries {
    static let shelfSize = 20

    public static func home(now: Date = Date(), _ db: Database) throws -> HomeShelves {
        var shelves = HomeShelves()
        shelves.recentlyAdded = try albumSummaries(db, order: "addedAt DESC, album.id DESC", limit: shelfSize)
        let lastPlayed = "(SELECT max(play.playedAt) FROM play JOIN track AS t ON t.id = play.trackId WHERE t.albumId = album.id)"
        shelves.recentlyPlayed = try albumSummaries(db, where: "\(lastPlayed) IS NOT NULL", order: "\(lastPlayed) DESC", limit: shelfSize)

        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        shelves.topThisMonth = try TrackInfo.fetchAll(db, sql: TrackInfo.selectSQL + """

            JOIN (SELECT trackId, count(*) AS plays, max(playedAt) AS last FROM play
                  WHERE playedAt >= ? GROUP BY trackId) AS recent ON recent.trackId = track.id
            ORDER BY recent.plays DESC, recent.last DESC
            LIMIT 12
            """, arguments: [monthAgo])

        let lately = now.addingTimeInterval(-60 * 86_400)
        let history = "(SELECT count(*) FROM play JOIN track AS t ON t.id = play.trackId WHERE t.albumId = album.id)"
        shelves.rediscover = try albumSummaries(db, where: "\(history) >= 3 AND \(lastPlayed) < :lately",
                                        order: "\(history) DESC", limit: shelfSize, arguments: ["lately": lately])
        return shelves
    }

    /// Nil when the album has no songs (any more).
    public static func album(_ id: Int64, _ db: Database) throws -> AlbumSummary? {
        try albumSummaries(db, where: "album.id = :id", arguments: ["id": id]).first
    }

    /// The artist a song or album credited to `credit` belongs to first: the first name in a
    /// split credit, or the credit itself.
    public static func leadArtist(ofCredit credit: Int64, _ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT memberId FROM artistMember WHERE creditId = ? ORDER BY position LIMIT 1",
                           arguments: [credit]) ?? credit
    }

    /// Nil when the artist has no songs (any more).
    public static func artistPage(_ id: Int64, _ db: Database) throws -> ArtistPage? {
        guard let artist = try artists(db).first(where: { $0.id == id }) else { return nil }
        let credited = "SELECT creditId FROM artistCredit WHERE artistId = :id"
        let plays = "(SELECT count(*) FROM play WHERE play.trackId = track.id)"
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(TrackInfo.selectColumns), NULL AS playlistItemId, \(plays) AS plays
            FROM track
            LEFT JOIN artist ON artist.id = track.artistId
            LEFT JOIN album ON album.id = track.albumId
            LEFT JOIN artist AS albumArtist ON albumArtist.id = album.artistId
            WHERE track.artistId IN (\(credited)) OR album.artistId IN (\(credited))
            ORDER BY plays DESC, \(TrackSort.albumOrder.orderBy(inPlaylist: false))
            LIMIT 10
            """, arguments: ["id": id])
        var topSongs: [TrackInfo] = []
        var counts: [Int64: Int] = [:]
        for row in rows {
            let info = try TrackInfo(row: row)
            topSongs.append(info)
            let n: Int = row["plays"]
            if n > 0, let trackId = info.track.id { counts[trackId] = n }
        }
        let year = "ifnull(album.year, max(track.year))"
        let newest = "\(year) IS NULL, \(year) DESC, album.title COLLATE NOCASE"
        let owned = try albumSummaries(db, where: "album.artistId IN (\(credited))", order: newest, arguments: ["id": id])
        let appears = try albumSummaries(db, where: """
            (album.artistId IS NULL OR album.artistId NOT IN (\(credited)))
            AND EXISTS (SELECT 1 FROM track AS t WHERE t.albumId = album.id AND t.artistId IN (\(credited)))
            """, order: newest, arguments: ["id": id])
        return ArtistPage(artist: artist, topSongs: topSongs, plays: counts, albums: owned, appearsOn: appears)
    }
}
