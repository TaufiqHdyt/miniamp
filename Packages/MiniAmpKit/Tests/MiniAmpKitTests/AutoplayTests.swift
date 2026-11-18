import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #54: what autoplay adds, and where songs chosen afterwards go.
@Suite struct AutoplayQueueTests {
    @Test func chosenSongsGoBeforeAutoplaysAndClearingTakesOnlyThose() {
        var q = PlayQueue(["a", "b"], startAt: 1)
        let autoplay = Set(q.insert(["x", "y"], next: false, before: []))
        #expect(q.order.map { q.items[$0] } == ["a", "b", "x", "y"])
        // Play Last lands after the chosen songs, before autoplay's.
        q.insert(["c"], next: false, before: autoplay)
        #expect(q.order.map { q.items[$0] } == ["a", "b", "c", "x", "y"])
        // Play Next is right after the current song either way.
        q.insert(["n"], next: true, before: autoplay)
        #expect(q.order.map { q.items[$0] } == ["a", "b", "n", "c", "x", "y"])
        q.removeUpcoming(autoplay)
        #expect(q.order.map { q.items[$0] } == ["a", "b", "n", "c"])
        #expect(q.current == "b")
    }

    @Test func anAutoplaySongPlayingStays() {
        var q = PlayQueue(["a"])
        let autoplay = Set(q.insert(["x", "y"], next: false, before: []))
        q.advance(automatic: true)
        #expect(q.current == "x")
        q.removeUpcoming(autoplay)
        #expect(q.order.map { q.items[$0] } == ["a", "x"])
        #expect(q.current == "x")
        // Nothing of autoplay's left to come: Play Last goes at the end.
        q.insert(["c"], next: false, before: autoplay)
        #expect(q.order.map { q.items[$0] } == ["a", "x", "c"])
    }
}

/// Issue #54: picks from the library and its history.
@Suite struct AutoplayPicksTests {
    struct Library {
        let db: AppDatabase
        var ids: [String: Int64] = [:]

        func url(_ title: String) -> URL { URL(fileURLWithPath: "/music/\(title).flac") }

        mutating func add(_ title: String, artist: String, genre: String? = nil, album: String? = nil,
                          durationMs: Int = 200_000, evicted: Bool = false) throws {
            let id = try db.writer.write { d in
                var track = try SchemaTests.insertTrack(title, artist: artist, album: album, genre: genre, d)
                track.durationMs = durationMs
                track.isEvicted = evicted
                try track.update(d)
                return track.id!
            }
            ids[title] = id
        }

        func play(_ title: String, at date: Date, listenedMs: Int = 200_000) throws {
            try db.writer.write { d in
                var play = Play(trackId: ids[title]!, playedAt: date, listenedMs: listenedMs)
                try play.insert(d)
            }
        }

        func picks(after seeds: [String], excluding: [String] = [], count: Int = 10, now: Date = Date(),
                   seed: UInt64 = 1) throws -> [String] {
            var rng = PlayQueueTests.SeededGenerator(state: seed)
            return try db.writer.read { d in
                try Autoplay.picks(after: seeds.map(url), excluding: (seeds + excluding).map(url), count: count, now: now,
                                   using: &rng, d)
            }.map(\.title)
        }
    }

    @Test func prefersTheSameArtistAndGenre() throws {
        var lib = Library(db: try AppDatabase.inMemory())
        try lib.add("Seed", artist: "Band", genre: "Rock")
        try lib.add("Same artist", artist: "Band", genre: "Rock")
        try lib.add("Same genre", artist: "Other", genre: "rock; Indie")
        for i in 0..<30 { try lib.add("Unrelated \(i)", artist: "Artist \(i)", genre: "Jazz") }

        // Across many draws, the related songs come first far more often than not.
        var firstTwo: [String: Int] = [:]
        for seed in 1...40 as ClosedRange<UInt64> {
            for title in try lib.picks(after: ["Seed"], count: 2, seed: seed) { firstTwo[title, default: 0] += 1 }
        }
        #expect(firstTwo["Same artist", default: 0] >= 35)
        #expect(firstTwo["Same genre", default: 0] >= 35)
        // A full batch is filled from the rest of the library.
        let batch = try lib.picks(after: ["Seed"])
        #expect(batch.count == 10)
        #expect(Set(batch).count == 10)
        #expect(!batch.contains("Seed"))
    }

    @Test func leavesOutQueuedRecentEvictedAndCapsEachArtist() throws {
        var lib = Library(db: try AppDatabase.inMemory())
        let now = Date()
        try lib.add("Seed", artist: "Band", genre: "Pop")
        for i in 0..<6 { try lib.add("Band \(i)", artist: "Band", genre: "Pop") }
        try lib.add("Queued", artist: "Band", genre: "Pop")
        try lib.add("Just played", artist: "Band", genre: "Pop")
        try lib.add("In the cloud", artist: "Band", genre: "Pop", evicted: true)
        try lib.add("Other", artist: "Other", genre: "Folk")
        try lib.play("Just played", at: now.addingTimeInterval(-3600))

        let picks = try lib.picks(after: ["Seed"], excluding: ["Queued"], now: now)
        #expect(!picks.contains("Queued"))
        #expect(!picks.contains("Just played"))
        #expect(!picks.contains("In the cloud"))
        // Two from the band at most, then whatever else there is.
        #expect(picks.filter { $0.hasPrefix("Band") }.count == 2)
        #expect(picks.contains("Other"))
    }

    @Test func songsPlayedTogetherBeforeAndSongsCutShort() throws {
        var lib = Library(db: try AppDatabase.inMemory())
        let now = Date()
        try lib.add("Seed", artist: "A")
        try lib.add("Companion", artist: "B")
        try lib.add("Kept", artist: "A")
        try lib.add("Skipped", artist: "A")
        for i in 0..<20 { try lib.add("Filler \(i)", artist: "F\(i)") }
        // A week ago, Companion played twice alongside Seed; Kept was heard out, Skipped abandoned early.
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        try lib.play("Seed", at: weekAgo)
        try lib.play("Companion", at: weekAgo.addingTimeInterval(240))
        try lib.play("Seed", at: weekAgo.addingTimeInterval(3 * 86_400))
        try lib.play("Companion", at: weekAgo.addingTimeInterval(3 * 86_400 + 200))
        try lib.play("Kept", at: weekAgo.addingTimeInterval(-86_400))
        try lib.play("Skipped", at: weekAgo.addingTimeInterval(-2 * 86_400), listenedMs: 31_000)
        // Since then, plenty of other listening, so none of them is among the latest plays.
        try lib.add("Recent", artist: "R")
        for i in 0..<Autoplay.recentPlays { try lib.play("Recent", at: now.addingTimeInterval(-86_400 + Double(i) * 60)) }

        var first: [String: Int] = [:]
        for seed in 1...60 as ClosedRange<UInt64> {
            for title in try lib.picks(after: ["Seed"], count: 1, now: now, seed: seed) { first[title, default: 0] += 1 }
        }
        // Played together and by the same artist both count; cut short counts against.
        #expect(first["Companion", default: 0] > first["Skipped", default: 0])
        #expect(first["Kept", default: 0] > first["Skipped", default: 0] * 2)
        #expect(first.keys.allSatisfy { !$0.hasPrefix("Filler") })
    }

    @Test func withNothingToGoOnItStillPicks() throws {
        var lib = Library(db: try AppDatabase.inMemory())
        for i in 0..<5 { try lib.add("Song \(i)", artist: "Artist \(i)") }
        // The seed isn't in the library (a file opened from elsewhere).
        let picks = try lib.picks(after: ["Elsewhere"], count: 3)
        #expect(picks.count == 3)
        #expect(try lib.picks(after: ["Song 0"], excluding: ["Song 1", "Song 2", "Song 3", "Song 4"]).isEmpty)
    }
}
