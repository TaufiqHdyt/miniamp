import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #29: a play counts after 30 seconds of listening; paused and skipped time doesn't.
@Suite struct PlayHistoryTests {
    @Test func listeningTimeCountsOnlyWhileRunning() {
        let t0 = SuspendingClock.now
        var time = ListeningTime()
        time.set(running: true, at: t0)
        time.set(running: true, at: t0 + .seconds(5)) // already running: no restart
        #expect(time.total(at: t0 + .seconds(10)) == .seconds(10))
        time.set(running: false, at: t0 + .seconds(12))
        // Paused for a minute.
        #expect(time.total(at: t0 + .seconds(72)) == .seconds(12))
        time.set(running: true, at: t0 + .seconds(72))
        #expect(time.total(at: t0 + .seconds(90)) == .seconds(30))
        #expect(time.isRunning)
    }

    @Test func thresholdIs30SecondsOrMostOfAShortTrack() {
        #expect(PlayHistory.threshold(for: .seconds(240)) == .seconds(30))
        #expect(PlayHistory.threshold(for: .seconds(20)) == .seconds(18))
        // Unknown length: the full threshold.
        #expect(PlayHistory.threshold(for: .zero) == .seconds(30))
    }

    @Test func recordsLibraryTracksOnly() throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let url = folder.url.appendingPathComponent("a.flac")
        try db.writer.write { d in
            try SchemaTests.insertTrack("A", artist: "Band", album: nil, path: folder.canonical("a.flac"), d)
        }
        try folder.flac("a.flac")
        let at = Date(timeIntervalSince1970: 1_000_000)
        let id = try #require(try db.writer.write { try Plays.record(url, playedAt: at, listened: .seconds(30), $0) })
        try db.writer.write { try Plays.update(id, listened: .milliseconds(95_500), $0) }
        #expect(try db.writer.write { try Plays.record(URL(fileURLWithPath: "/elsewhere.flac"), playedAt: at, listened: .seconds(30), $0) } == nil)

        let recent = try db.writer.read { try Plays.recent(limit: 10, $0) }
        #expect(recent.count == 1)
        #expect(recent.first?.info.track.title == "A")
        #expect(recent.first?.info.playlistItemId == nil)
        #expect(recent.first?.play.listenedMs == 95_500)
        #expect(recent.first?.play.playedAt == at)
    }
}
