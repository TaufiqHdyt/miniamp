import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #38: listening stats and the yearly recap.
@Suite struct ListeningStatsTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func library() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            let a = try SchemaTests.insertTrack("A", artist: "Old Band", album: "First", genre: "Rock", d)
            let b = try SchemaTests.insertTrack("B", artist: "Old Band", album: "First", genre: "rock", d)
            let c = try SchemaTests.insertTrack("C", artist: "New Band", album: "Second", genre: "Jazz", d)
            let plays: [(Track, Date, Int)] = [
                (a, date(2025, 6, 1), 200_000),
                (a, date(2026, 1, 1, 0), 100_000),   // just after midnight on New Year's Day, local
                (a, date(2026, 1, 2, 8), 100_000),
                (b, date(2026, 1, 3, 8), 50_000),
                (c, date(2026, 3, 10, 22), 300_000),
                (c, date(2026, 3, 10, 23), 300_000),
                (a, date(2026, 3, 10, 21), 40_000),
            ]
            for (track, at, ms) in plays {
                var play = Play(trackId: track.id!, playedAt: at, listenedMs: ms)
                try play.insert(d)
            }
        }
        return db
    }

    @Test func yearlyRecap() throws {
        let db = try library()
        let stats = try db.writer.read { try ListeningStats.compute(year: 2026, calendar: calendar, $0) }
        #expect(stats.plays == 6)
        #expect(stats.listened == .milliseconds(890_000))
        #expect(stats.tracks == 3)
        #expect(stats.artists == 2)
        #expect(stats.albums == 2)
        #expect(stats.newArtists == 1) // Old Band was first played in 2025
        #expect(stats.topTracks.map(\.item.track.title) == ["A", "C", "B"])
        #expect(stats.topTracks.map(\.plays) == [3, 2, 1])
        #expect(stats.topTracks.first?.item.artistName == "Old Band")
        // New Band has fewer plays but more listening; plays rank first.
        #expect(stats.topArtists.map(\.item) == ["Old Band", "New Band"])
        #expect(stats.topArtists.map(\.listened) == [.milliseconds(290_000), .milliseconds(600_000)])
        #expect(stats.topAlbums.map(\.item.title) == ["First", "Second"])
        #expect(stats.topAlbums.first?.item.artist == "Old Band")
        // Genres are grouped regardless of case.
        #expect(stats.topGenres.map(\.plays) == [4, 2])
        #expect(stats.topGenres.first?.item.lowercased() == "rock")

        #expect(stats.timeline.count == 12)
        #expect(stats.timeline.map(\.plays) == [3, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(stats.timeline[0].start == date(2026, 1, 1, 0))
        #expect(stats.byHour[0] == .milliseconds(100_000))
        #expect(stats.byHour[8] == .milliseconds(150_000))
        #expect(stats.byHour[22] == .milliseconds(300_000))
        // 10 March 2026 is a Tuesday: index 2, Sunday being 0.
        #expect(stats.byWeekday[2] == .milliseconds(640_000))
        #expect(stats.busiestDay?.start == date(2026, 3, 10, 0))
        #expect(stats.busiestDay?.plays == 3)
        #expect(stats.longestStreak == 3) // 1, 2, and 3 January
    }

    @Test func allTime() throws {
        let db = try library()
        let stats = try db.writer.read { try ListeningStats.compute(year: nil, calendar: calendar, $0) }
        #expect(stats.plays == 7)
        #expect(stats.newArtists == nil)
        #expect(stats.timeline.map { calendar.component(.year, from: $0.start) } == [2025, 2026])
        #expect(stats.timeline.map(\.plays) == [1, 6])
        #expect(try db.writer.read { try ListeningStats.years(calendar: calendar, $0) } == [2026, 2025])
    }

    @Test func aYearWithNoPlays() throws {
        let db = try library()
        let stats = try db.writer.read { try ListeningStats.compute(year: 2020, calendar: calendar, $0) }
        #expect(stats.isEmpty)
        #expect(stats.timeline.count == 12)
        #expect(stats.topTracks.isEmpty)
        #expect(stats.busiestDay == nil)
    }
}
