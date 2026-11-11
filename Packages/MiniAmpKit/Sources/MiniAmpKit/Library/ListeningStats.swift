import Foundation
import GRDB

/// What was listened to, from the play history: for one year (the yearly recap) or all time.
///
/// A play is one listen that passed the 30-second rule (see PlayHistory); its listening time
/// is how long it actually played. Days, months, and hours are local, in `calendar`'s time zone.
public struct ListeningStats: Sendable, Equatable {
    public struct Ranked<Item: Sendable & Equatable>: Sendable, Equatable {
        public var item: Item
        public var plays: Int
        public var listened: Duration
    }

    public struct AlbumItem: Sendable, Hashable {
        public var id: Int64
        public var title: String
        public var artist: String?
        public var artworkKey: String?
    }

    /// Listening in one span of time: a month, a year, or a day.
    public struct Bucket: Sendable, Equatable, Identifiable {
        public var start: Date
        public var plays: Int
        public var listened: Duration
        public var id: Date { start }
    }

    /// Nil for all time.
    public var year: Int?
    public var plays = 0
    public var listened: Duration = .zero
    public var tracks = 0
    public var artists = 0
    public var albums = 0
    /// Artists played for the first time ever in `year`; nil for all time.
    public var newArtists: Int?
    public var topTracks: [Ranked<TrackInfo>] = []
    public var topArtists: [Ranked<String>] = []
    public var topAlbums: [Ranked<AlbumItem>] = []
    public var topGenres: [Ranked<String>] = []
    /// A year: each of its 12 months. All time: each year from the first play to the last.
    public var timeline: [Bucket] = []
    /// Listening by hour of the day, 0 to 23.
    public var byHour: [Duration] = Array(repeating: .zero, count: 24)
    /// Listening by day of the week, in `Calendar` order: index 0 is Sunday.
    public var byWeekday: [Duration] = Array(repeating: .zero, count: 7)
    /// The day with the most listening.
    public var busiestDay: Bucket?
    /// The most days in a row with at least one play.
    public var longestStreak = 0

    public var isEmpty: Bool { plays == 0 }

    /// Years with at least one play, newest first.
    public static func years(calendar: Calendar = .current, _ db: Database) throws -> [Int] {
        let dates = try Date.fetchAll(db, sql: "SELECT playedAt FROM play ORDER BY playedAt")
        var years: [Int] = []
        for date in dates {
            let year = calendar.component(.year, from: date)
            if years.last != year { years.append(year) }
        }
        return years.reversed()
    }

    public static func compute(year: Int?, limit: Int = 10, calendar: Calendar = .current,
                               _ db: Database) throws -> ListeningStats {
        let (start, end): (Date, Date)
        if let year, let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let next = calendar.date(byAdding: .year, value: 1, to: first) {
            (start, end) = (first, next)
        } else {
            (start, end) = (.distantPast, .distantFuture)
        }
        let range: StatementArguments = [start, end]
        let inRange = "play.playedAt >= ? AND play.playedAt < ?"
        var stats = ListeningStats(year: year)

        if let row = try Row.fetchOne(db, sql: """
            SELECT count(*), ifnull(sum(play.listenedMs), 0), count(DISTINCT play.trackId),
                   count(DISTINCT track.artistId), count(DISTINCT track.albumId)
            FROM play JOIN track ON track.id = play.trackId
            WHERE \(inRange)
            """, arguments: range) {
            stats.plays = row[0]
            stats.listened = .milliseconds(row[1] as Int64)
            stats.tracks = row[2]
            stats.artists = row[3]
            stats.albums = row[4]
        }
        guard stats.plays > 0 else {
            stats.timeline = timeline(year: year, events: [], calendar: calendar)
            return stats
        }

        if year != nil {
            stats.newArtists = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (
                    SELECT min(play.playedAt) AS first
                    FROM play JOIN track ON track.id = play.trackId
                    WHERE track.artistId IS NOT NULL
                    GROUP BY track.artistId)
                WHERE first >= ? AND first < ?
                """, arguments: range)
        }

        let ranking = "ORDER BY count(*) DESC, sum(play.listenedMs) DESC LIMIT \(limit)"
        let n = Track.columnNames.count + 4
        stats.topTracks = try Row.fetchAll(db, sql: """
            SELECT \(TrackInfo.selectColumns), NULL AS playlistItemId, count(*), sum(play.listenedMs)
            FROM play
            JOIN track ON track.id = play.trackId
            LEFT JOIN artist ON artist.id = track.artistId
            LEFT JOIN album ON album.id = track.albumId
            LEFT JOIN artist AS albumArtist ON albumArtist.id = album.artistId
            WHERE \(inRange)
            GROUP BY track.id \(ranking)
            """, arguments: range).map { row in
            Ranked(item: try TrackInfo(row: row), plays: row[n], listened: .milliseconds(row[n + 1] as Int64))
        }
        stats.topArtists = try Row.fetchAll(db, sql: """
            SELECT artist.name, count(*), sum(play.listenedMs)
            FROM play JOIN track ON track.id = play.trackId JOIN artist ON artist.id = track.artistId
            WHERE \(inRange)
            GROUP BY artist.id \(ranking)
            """, arguments: range).map { Ranked(item: $0[0], plays: $0[1], listened: .milliseconds($0[2] as Int64)) }
        stats.topAlbums = try Row.fetchAll(db, sql: """
            SELECT album.id, album.title, albumArtist.name, album.artworkKey, count(*), sum(play.listenedMs)
            FROM play
            JOIN track ON track.id = play.trackId
            JOIN album ON album.id = track.albumId
            LEFT JOIN artist AS albumArtist ON albumArtist.id = album.artistId
            WHERE \(inRange)
            GROUP BY album.id \(ranking)
            """, arguments: range).map {
            Ranked(item: AlbumItem(id: $0[0], title: $0[1], artist: $0[2], artworkKey: $0[3]),
                   plays: $0[4], listened: .milliseconds($0[5] as Int64))
        }
        stats.topGenres = try Row.fetchAll(db, sql: """
            SELECT min(track.genre), count(*), sum(play.listenedMs)
            FROM play JOIN track ON track.id = play.trackId
            WHERE \(inRange) AND trim(ifnull(track.genre, '')) != ''
            GROUP BY track.genre COLLATE NOCASE \(ranking)
            """, arguments: range).map { Ranked(item: $0[0], plays: $0[1], listened: .milliseconds($0[2] as Int64)) }

        // Spans of time, bucketed here rather than in SQL so they're in the calendar's time zone.
        let events = try Row.fetchAll(db, sql: "SELECT playedAt, listenedMs FROM play WHERE \(inRange) ORDER BY playedAt",
                                      arguments: range).map { (date: $0[0] as Date, listened: Duration.milliseconds($0[1] as Int64)) }
        stats.timeline = timeline(year: year, events: events, calendar: calendar)
        var days: [Date: Bucket] = [:]
        for event in events {
            stats.byHour[calendar.component(.hour, from: event.date)] += event.listened
            stats.byWeekday[calendar.component(.weekday, from: event.date) - 1] += event.listened
            let day = calendar.startOfDay(for: event.date)
            days[day, default: Bucket(start: day, plays: 0, listened: .zero)].plays += 1
            days[day]!.listened += event.listened
        }
        stats.busiestDay = days.values.max { ($0.listened, $1.start) < ($1.listened, $0.start) }
        stats.longestStreak = longestRun(of: days.keys.sorted(), calendar: calendar)
        return stats
    }

    private static func timeline(year: Int?, events: [(date: Date, listened: Duration)], calendar: Calendar) -> [Bucket] {
        let unit: Calendar.Component = year == nil ? .year : .month
        var starts: [Date] = []
        if let year {
            starts = (1...12).compactMap { calendar.date(from: DateComponents(year: year, month: $0, day: 1)) }
        } else if let first = events.first?.date, let last = events.last?.date {
            let years = calendar.component(.year, from: first)...calendar.component(.year, from: last)
            starts = years.compactMap { calendar.date(from: DateComponents(year: $0, month: 1, day: 1)) }
        }
        var buckets = starts.map { Bucket(start: $0, plays: 0, listened: .zero) }
        for event in events {
            guard let start = calendar.dateInterval(of: unit, for: event.date)?.start,
                  let index = starts.firstIndex(of: start) else { continue }
            buckets[index].plays += 1
            buckets[index].listened += event.listened
        }
        return buckets
    }

    /// The longest run of consecutive days in `days` (sorted starts of days).
    private static func longestRun(of days: [Date], calendar: Calendar) -> Int {
        var best = 0, run = 0
        var previous: Date?
        for day in days {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous), calendar.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }
}
