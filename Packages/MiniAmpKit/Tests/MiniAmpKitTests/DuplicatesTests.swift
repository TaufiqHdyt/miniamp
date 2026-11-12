import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #40: finding likely duplicates by tags and duration.
@Suite struct DuplicatesTests {
    /// Inserts a track with these properties; returns its id.
    @discardableResult
    func track(_ title: String, artist: String?, ms: Int, codec: String = "FLAC", rate: Int = 44_100, bits: Int? = 16,
               kbps: Int = 900, _ d: Database) throws -> Int64 {
        var t = try SchemaTests.insertTrack(title, artist: artist, album: nil, path: "/music/\(UUID().uuidString).x", d)
        t.durationMs = ms
        t.codec = codec
        t.sampleRate = rate
        t.bitsPerSample = bits
        t.bitrateKbps = kbps
        try t.update(d)
        return t.id!
    }

    @Test func groupsByTagsAndCloseLengths() throws {
        let db = try AppDatabase.inMemory()
        let ids = try db.writer.write { d -> [Int64] in
            [
                try track("It's Oh So Quiet!", artist: "Björk", ms: 218_000, d),
                try track("its oh so  quiet", artist: "BJORK", ms: 219_500, codec: "MP3", bits: nil, kbps: 320, d),
                try track("It’s Oh So Quiet", artist: "Björk", ms: 260_000, d),      // a different take
                try track("Hyperballad", artist: "Björk", ms: 300_000, d),          // alone
                try track("Intro", artist: nil, ms: 60_000, d),                     // no artist: never grouped
                try track("Intro", artist: nil, ms: 60_000, d),
            ]
        }
        let groups = try db.writer.read { try Duplicates.find($0) }
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.entries.map(\.id)) == [ids[0], ids[1]])
        #expect(group.id == "\(ids[0]),\(ids[1])")
        // The FLAC is the one to keep.
        #expect(group.entries.first?.id == ids[0])
    }

    @Test func ranksTheBetterCopyFirst() throws {
        let db = try AppDatabase.inMemory()
        let (aac, alac, hiRes, played) = try db.writer.write { d in
            (try track("Song", artist: "Band", ms: 200_000, codec: "AAC", bits: nil, kbps: 256, d),
             try track("Song", artist: "Band", ms: 200_000, codec: "ALAC", d),
             try track("Song", artist: "Band", ms: 200_100, codec: "FLAC", rate: 96_000, bits: 24, d),
             try track("Song", artist: "Band", ms: 200_000, codec: "ALAC", d))
        }
        try db.writer.write { d in
            var play = Play(trackId: played, playedAt: Date(), listenedMs: 60_000)
            try play.insert(d)
        }
        let group = try #require(try db.writer.read { try Duplicates.find($0) }.first)
        #expect(group.entries.map(\.id) == [hiRes, played, alac, aac])
        #expect(group.entries[1].plays == 1)
    }

    @Test func dismissedGroupsStayHiddenUntilTheyChange() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            try track("Song", artist: "Band", ms: 200_000, d)
            try track("Song", artist: "Band", ms: 200_000, d)
        }
        let group = try #require(try db.writer.read { try Duplicates.find($0) }.first)
        try db.writer.write { try Duplicates.dismiss(group, $0) }
        #expect(try db.writer.read { try Duplicates.find($0) }.isEmpty)
        // A third copy turns up: the group is new, so it's back.
        try db.writer.write { d in try track("Song", artist: "Band", ms: 200_500, d) }
        #expect(try db.writer.read { try Duplicates.find($0) }.first?.entries.count == 3)
    }

    @Test func normalizes() {
        #expect(Duplicates.normalized("  Björk – It's Oh So   Quiet! ") == "bjork its oh so quiet")
        #expect(Duplicates.normalized("ＡＢＣ") == "abc")
        #expect(Duplicates.normalized("夜に駆ける") == "夜に駆ける")
    }
}
