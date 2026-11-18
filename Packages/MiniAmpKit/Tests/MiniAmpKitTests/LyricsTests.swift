import Foundation
import GRDB
import Synchronization
import Testing
@testable import MiniAmpKit

/// Issue #34: the LRC parser, including enhanced LRC's word times.
@Suite struct LRCParserTests {
    @Test func parsesTimedLinesAndHeaders() {
        let lyrics = Lyrics(lrc: """
            \u{FEFF}[ar:Someone]
            [ti: A Song ]
            [length: 03:20]
            [00:12.50] First line
            [00:15.2]Second
            [01:02.345]Third
            [00:20:50]Hundredths after a colon
            no time here, dropped
            [00:30.00]
            [00:31.00]After a break
            """)
        #expect(lyrics.isSynced)
        #expect(lyrics.metadata == ["ar": "Someone", "ti": "A Song", "length": "03:20"])
        #expect(lyrics.lines.map(\.text) == ["First line", "Second", "Hundredths after a colon", "", "After a break", "Third"])
        #expect(lyrics.lines.map(\.time) == [.milliseconds(12_500), .milliseconds(15_200), .milliseconds(20_500),
                                              .seconds(30), .seconds(31), .milliseconds(62_345)])
        #expect(lyrics.lines.map(\.id) == Array(0..<6))
        #expect(!lyrics.hasWordTiming)
    }

    @Test func repeatsLinesWithSeveralTimes() {
        let lyrics = Lyrics(lrc: "[00:10.00][00:30.00]Chorus\r\n[00:20.00]Verse\r\n")
        #expect(lyrics.lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
        #expect(lyrics.lines.map(\.time) == [.seconds(10), .seconds(20), .seconds(30)])
    }

    @Test func appliesTheOffset() {
        // A positive offset shows lyrics sooner.
        let sooner = Lyrics(lrc: "[offset:+500]\n[00:01.00]a\n[00:00.20]b <00:00.30>c")
        #expect(sooner.lines.map(\.time) == [.zero, .milliseconds(500)])
        #expect(sooner.lines[0].words.map(\.time) == [.zero, .zero])
        #expect(sooner.metadata["offset"] == nil)
        let later = Lyrics(lrc: "[offset:-250]\n[00:01.00]a")
        #expect(later.lines.first?.time == .milliseconds(1250))
    }

    @Test func plainTextHasNoTimes() {
        let lyrics = Lyrics(lrc: "\n\n[Chorus]\nLa la la\n\nSecond verse\n\n")
        #expect(!lyrics.isSynced)
        #expect(lyrics.lines.map(\.text) == ["[Chorus]", "La la la", "", "Second verse"])
        #expect(lyrics.lines.allSatisfy { $0.time == nil })
        #expect(lyrics.position(at: .seconds(5)) == LyricsPosition())
        #expect(lyrics.nextChange(after: .zero) == nil)
    }

    @Test func emptyTextIsNoLyrics() {
        #expect(Lyrics(lrc: "").isEmpty)
        #expect(Lyrics(lrc: "[ar:Someone]\n[00:01.00]\n").isEmpty)
        #expect(!Lyrics.instrumental.isEmpty)
    }

    @Test func parsesWordTimes() throws {
        let lyrics = Lyrics(lrc: """
            [00:01.00] <00:01.00>Hello <00:01.50>big <00:02.00>world<00:02.80>
            [00:03.00]Lead-in <00:03.40>then <00:03.90>words
            [00:05.00]<00:05.00>Not<a time> <00:05.50>fine
            """)
        #expect(lyrics.hasWordTiming)
        let first = lyrics.lines[0]
        #expect(first.text == "Hello big world")
        #expect(first.words.map(\.text) == ["Hello ", "big ", "world"])
        #expect(first.words.map(\.time) == [.seconds(1), .milliseconds(1500), .seconds(2)])
        // Text before the first word time starts with the line.
        let second = lyrics.lines[1]
        #expect(second.text == "Lead-in then words")
        #expect(second.words.map(\.text) == ["Lead-in ", "then ", "words"])
        #expect(second.words.map(\.time) == [.seconds(3), .milliseconds(3400), .milliseconds(3900)])
        // A "<" that isn't a time stays in the text.
        #expect(lyrics.lines[2].text == "Not<a time> fine")
        #expect(lyrics.lines[2].words.count == 2)
    }

    @Test func parsesTimeFormats() {
        #expect(Lyrics.time("01:02") == .seconds(62))
        #expect(Lyrics.time("1:02.5") == .milliseconds(62_500))
        #expect(Lyrics.time("01:02.05") == .milliseconds(62_050))
        #expect(Lyrics.time("01:02.005") == .milliseconds(62_005))
        #expect(Lyrics.time("01:02:05") == .milliseconds(62_050))
        #expect(Lyrics.time("75:00.00") == .seconds(4500))
        for bad in ["ar:Someone", "1:2:3:4", "01:023", "-1:00", "aa:bb", "01:02.1234", "01:02.x"] {
            #expect(Lyrics.time(Substring(bad)) == nil, "\(bad)")
        }
    }
}

/// Issue #36: following playback through synced lyrics.
@Suite struct LyricsPositionTests {
    let lyrics = Lyrics(lrc: """
        [00:01.00]One
        [00:02.00]<00:02.00>Two <00:02.40>words
        [00:04.00]Three
        """)

    @Test func findsTheLineAndWord() {
        #expect(lyrics.position(at: .zero) == LyricsPosition())
        #expect(lyrics.position(at: .seconds(1)) == LyricsPosition(line: 0))
        #expect(lyrics.position(at: .milliseconds(2100)) == LyricsPosition(line: 1, word: 0))
        #expect(lyrics.position(at: .milliseconds(2400)) == LyricsPosition(line: 1, word: 1))
        #expect(lyrics.position(at: .seconds(100)) == LyricsPosition(line: 2))
    }

    @Test func knowsTheNextChange() {
        #expect(lyrics.nextChange(after: .zero) == .seconds(1))
        #expect(lyrics.nextChange(after: .milliseconds(1500)) == .seconds(2))
        #expect(lyrics.nextChange(after: .milliseconds(2100)) == .milliseconds(2400))
        #expect(lyrics.nextChange(after: .milliseconds(2500)) == .seconds(4))
        #expect(lyrics.nextChange(after: .seconds(4)) == nil)
    }

    /// A clock that runs from `base` while `running`, set by the test.
    @MainActor final class FakeClock {
        var base: Duration = .zero
        var started = ContinuousClock.now
        var running = true
        var now: Duration { running ? base + (ContinuousClock.now - started) : base }
        func jump(to time: Duration) { base = time; started = .now }
    }

    @MainActor
    @Test func followerWakesForEachLineAndResyncsOnSeek() async throws {
        let quick = Lyrics(lrc: "[00:00.10]a\n[00:00.20]b\n[00:00.30]c\n[00:30.00]much later")
        let clock = FakeClock()
        let follower = LyricsFollower { (clock.now, clock.running) }
        follower.lyrics = quick
        #expect(follower.position.line == nil)
        #expect(await waitFor { follower.position.line == 2 })

        // A seek back before the first line, then a resync, shows nothing sung.
        clock.jump(to: .milliseconds(50))
        follower.resync()
        #expect(follower.position.line == nil)
        #expect(await waitFor { follower.position.line == 0 })

        // Paused past a line: it shows that line, and doesn't move on.
        clock.running = false
        clock.jump(to: .milliseconds(250))
        follower.resync()
        #expect(follower.position.line == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(follower.position.line == 1)

        follower.lyrics = nil
        #expect(follower.position == LyricsPosition())
    }

    @MainActor
    @Test func offsetShiftsTheLyrics() async throws {
        let clock = FakeClock()
        clock.running = false
        clock.jump(to: .milliseconds(150))
        let follower = LyricsFollower { (clock.now, clock.running) }
        follower.lyrics = Lyrics(lrc: "[00:00.10]a\n[00:00.20]b\n[00:00.30]c")
        #expect(follower.position.line == 0)
        // Sooner: at 0.15 s the lyrics are at 0.25 s.
        follower.offset = .milliseconds(100)
        #expect(follower.position.line == 1)
        #expect(follower.lyricsTime == .milliseconds(250))
        // Later.
        follower.offset = .milliseconds(-100)
        #expect(follower.position.line == nil)
        // Playing from a line seeks to where it's due in playback time.
        #expect(follower.playbackTime(for: .milliseconds(200)) == .milliseconds(300))
        follower.offset = .seconds(1)
        #expect(follower.playbackTime(for: .milliseconds(200)) == .zero)

        // While playing, it still wakes for each (shifted) line.
        follower.offset = .milliseconds(100)
        clock.jump(to: .zero)
        clock.running = true
        follower.resync()
        // At 0 s of playback the lyrics are at 0.1 s: line a has just started.
        #expect(follower.position.line == 0)
        #expect(await waitFor { follower.position.line == 2 })
    }

    /// Polls on the main actor (where the follower lives) for up to 2 seconds.
    @MainActor
    func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Issue #35: lyrics that come with the file.
@Suite struct LocalLyricsTests {
    @Test func readsASidecarLRC() async throws {
        let folder = try TestFolder()
        let song = try folder.flac("Song.flac")
        try folder.write(Data("[00:01.00]From the sidecar".utf8), to: "Song.lrc")
        let found = try #require(await LocalLyrics.find(for: song))
        #expect(found.source == .sidecar(folder.url.appendingPathComponent("Song.lrc")))
        #expect(found.lyrics.lines.map(\.text) == ["From the sidecar"])
        #expect(await LocalLyrics.find(for: try folder.flac("Other.flac")) == nil)
    }

    @Test func readsEmbeddedLyricsInEachFormat() async throws {
        let folder = try TestFolder()
        let flac = try folder.flac("a.flac")
        let mp3 = try folder.mp3("b.mp3", title: "B")
        for url in [flac, mp3] {
            try TagWriter.write(TagChanges(lyrics: "[00:02.00]Embedded\n[00:04.00]Ünïcode"), to: url)
            let found = try #require(await LocalLyrics.find(for: url))
            #expect(found.source == .embedded)
            #expect(found.lyrics.lines.map(\.text) == ["Embedded", "Ünïcode"])
            #expect(found.lyrics.isSynced)
            // Clearing them leaves nothing.
            try TagWriter.write(TagChanges(lyrics: ""), to: url)
            #expect(await LocalLyrics.find(for: url) == nil)
        }
        #expect(TagReader.read(mp3)?.title == "B")
    }

    @Test func readsID3SyncedAndUnsyncedFrames() async throws {
        let folder = try TestFolder()
        let audio = try Data(contentsOf: TestAudio.mp3Fixture)

        // SYLT: Latin-1, English, millisecond times, lyrics; an empty description.
        var sylt = Data([0]) + Data("eng".utf8) + Data([2, 1, 0])
        for (text, ms) in [("Synced one", UInt32(1500)), ("Synced two", UInt32(62_000))] {
            sylt += Data(text.utf8) + Data([0])
            withUnsafeBytes(of: ms.bigEndian) { sylt += $0 }
        }
        let synced = try folder.write(ID3.tag([], raw: [("SYLT", sylt)]) + audio, to: "synced.mp3")
        let fromSYLT = try #require(await LocalLyrics.find(for: synced))
        #expect(fromSYLT.lyrics.lines.map(\.text) == ["Synced one", "Synced two"])
        #expect(fromSYLT.lyrics.lines.map(\.time) == [.milliseconds(1500), .seconds(62)])

        // USLT with a description: UTF-16, English.
        var uslt = Data([1]) + Data("eng".utf8)
        uslt += Data([0xFF, 0xFE]) + "desc".data(using: .utf16LittleEndian)! + Data([0, 0])
        uslt += Data([0xFF, 0xFE]) + "Plain words\nSecond line".data(using: .utf16LittleEndian)!
        let plain = try folder.write(ID3.tag([], raw: [("USLT", uslt)]) + audio, to: "plain.mp3")
        let fromUSLT = try #require(await LocalLyrics.find(for: plain))
        #expect(fromUSLT.lyrics.lines.map(\.text) == ["Plain words", "Second line"])
        #expect(!fromUSLT.lyrics.isSynced)
    }

    @Test func syncedLyricsWinOverPlain() async throws {
        let folder = try TestFolder()
        let song = try folder.flac("Song.flac")
        try folder.write(Data("Plain sidecar".utf8), to: "Song.lrc")
        try TagWriter.write(TagChanges(lyrics: "[00:01.00]Synced tags"), to: song)
        #expect(try #require(await LocalLyrics.find(for: song)).source == .embedded)
        // A synced sidecar beats synced tags.
        try folder.write(Data("[00:01.00]Synced sidecar".utf8), to: "Song.lrc")
        #expect(try #require(await LocalLyrics.find(for: song)).lyrics.lines.first?.text == "Synced sidecar")
        // Plain tags lose to a plain sidecar.
        try TagWriter.write(TagChanges(lyrics: "Plain tags"), to: song)
        try folder.write(Data("Plain sidecar".utf8), to: "Song.lrc")
        #expect(try #require(await LocalLyrics.find(for: song)).lyrics.lines.first?.text == "Plain sidecar")
    }

    @Test func decodesLegacyEncodings() {
        #expect(LocalLyrics.decode(Data("[00:01.00]café".utf8)) == "[00:01.00]café")
        #expect(LocalLyrics.decode("[00:01.00]café".data(using: .utf16)!) == "[00:01.00]café")
        #expect(LocalLyrics.decode("[00:01.00]café déjà vu".data(using: .windowsCP1252)!) == "[00:01.00]café déjà vu")
        #expect(LocalLyrics.decode("[00:01.00]こんにちは、世界".data(using: .shiftJIS)!) == "[00:01.00]こんにちは、世界")
    }
}

/// Issue #37: LRCLIB lookups, against a stub server.
@Suite struct LRCLIBTests {
    @Test func takesTheExactMatch() async throws {
        let stub = StubServer { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "miniamp-test/1")
            let query = StubServer.query(request)
            #expect(request.url?.path == "/api/get")
            #expect(query == ["track_name": "Song & Dance", "artist_name": "Band", "album_name": "Record", "duration": "184"])
            return (200, Self.json(["id": 7, "trackName": "Song & Dance", "duration": 184.0, "instrumental": false,
                                    "plainLyrics": "Words", "syncedLyrics": "[00:01.00] Words"]))
        }
        let record = try #require(try await stub.client.record(for:
            LRCLIB.Query(title: "Song & Dance", artist: "Band", album: "Record", duration: .milliseconds(183_600))))
        #expect(record.id == 7)
        #expect(record.lyrics?.lines.map(\.text) == ["Words"])
        #expect(record.lyrics?.isSynced == true)
    }

    @Test func searchesWhenThereIsNoExactMatch() async throws {
        let stub = StubServer { request in
            if request.url?.path == "/api/get" { return (404, Self.json(["code": 404, "name": "TrackNotFound"])) }
            #expect(StubServer.query(request) == ["track_name": "Song", "artist_name": "Band"])
            return (200, Self.jsonArray([
                ["id": 1, "duration": 300.0, "instrumental": false, "syncedLyrics": "[00:01.00]Too long"],
                ["id": 2, "duration": 201.0, "instrumental": false, "plainLyrics": "Plain, closest"],
                ["id": 3, "duration": 198.0, "instrumental": false, "syncedLyrics": "[00:01.00]Synced, close"],
                ["id": 4, "duration": 200.0, "instrumental": false],
            ]))
        }
        let record = try await stub.client.record(for: LRCLIB.Query(title: "Song", artist: "Band", duration: .seconds(200)))
        #expect(record?.id == 3)
        // As a provider, the same record under LRCLIB's name.
        let online = try await stub.client.lookUp(LRCLIB.Query(title: "Song", artist: "Band", duration: .seconds(200)))
        #expect(online?.provider == .lrclib)
        #expect(online?.id == "3")
    }

    @Test func nothingFoundAndErrors() async throws {
        let empty = StubServer { request in
            request.url?.path == "/api/get" ? (404, Data("{}".utf8)) : (200, Data("[]".utf8))
        }
        #expect(try await empty.client.lookUp(LRCLIB.Query(title: "A", artist: "B", duration: .seconds(1))) == nil)
        let failing = StubServer { _ in (503, Data()) }
        await #expect(throws: LyricsServiceError.self) {
            try await failing.client.lookUp(LRCLIB.Query(title: "A", artist: "B", duration: .seconds(1)))
        }
    }

    @Test func instrumentalTracks() {
        let record = LRCLIB.Record(id: 1, instrumental: true)
        #expect(record.lyrics == .instrumental)
        #expect(LRCLIB.Record(id: 2, plainLyrics: "  ").lyrics == nil)
    }

    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func jsonArray(_ object: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}

/// Issue #37: what LRCLIB said is kept, so a track is looked up once.
@Suite struct LyricsFinderTests {
    @Test func cachesFoundAndNotFound() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let found = try folder.mp3("found.mp3", title: "Found", artist: "Band", album: "Record")
        let missing = try folder.mp3("missing.mp3", title: "Missing", artist: "Band")
        let untagged = try folder.flac("untagged.flac")
        let paths = ["found.mp3", "missing.mp3", "untagged.flac"].map { folder.canonical($0) }
        try await db.writer.write { d in
            for path in paths {
                _ = try SchemaTests.insertTrack(path, artist: "Band", album: nil, path: path, d)
            }
        }
        let asked = Mutex<[String]>([])
        let stub = StubServer { request in
            let title = StubServer.query(request)["track_name"] ?? ""
            asked.withLock { $0.append(title) }
            if title == "Found", request.url?.path == "/api/get" {
                return (200, LRCLIBTests.json(["id": 9, "instrumental": false, "syncedLyrics": "[00:01.00]Hi"]))
            }
            return request.url?.path == "/api/get" ? (404, Data()) : (200, Data("[]".utf8))
        }
        let finder = LyricsFinder(database: db, providers: [stub.client])

        #expect(try await finder.find(for: found, online: .off) == .notFound(searchedOnline: false))
        #expect(try await finder.find(for: found, online: .cachedOnly) == .notFound(searchedOnline: false))
        guard case .found(let first) = try await finder.find(for: found, online: .automatic) else {
            Issue.record("not found"); return
        }
        #expect(first.source == .online(.lrclib, id: "9"))
        #expect(first.lyrics.lines.first?.text == "Hi")
        #expect(try await finder.find(for: found, online: .cachedOnly) == .found(first))
        #expect(try await finder.find(for: missing, online: .automatic) == .notFound(searchedOnline: true))
        #expect(try await finder.find(for: missing, online: .automatic) == .notFound(searchedOnline: true))
        // Each was asked once (an exact match, then a search for the missing one).
        #expect(asked.withLock { $0 } == ["Found", "Missing", "Missing"])
        // Asking again on purpose goes back to LRCLIB.
        _ = try await finder.find(for: missing, online: .refresh)
        #expect(asked.withLock { $0.count } == 5)
        // No title and artist, nothing to search by.
        await #expect(throws: LyricsFinder.MissingTags.self) { try await finder.find(for: untagged, online: .automatic) }
        // A sidecar comes first, and LRCLIB isn't asked.
        try folder.write(Data("[00:01.00]Local".utf8), to: "missing.lrc")
        guard case .found(let local) = try await finder.find(for: missing, online: .refresh) else {
            Issue.record("not found"); return
        }
        #expect(local.lyrics.lines.first?.text == "Local")
        #expect(asked.withLock { $0.count } == 5)
        // Deleting the track deletes what was cached.
        try await db.writer.write { try $0.execute(sql: "DELETE FROM track") }
        #expect(try await db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM lyricsLookup") } == 0)
    }
}

/// Issue #53: NetEase Cloud Music, against a stub server.
@Suite struct NetEaseTests {
    static let song = LyricsQuery(title: "The Nights", artist: "Avicii", duration: .milliseconds(176_000))

    @Test func takesTheMatchingSongAndDropsTheCredits() async throws {
        let asked = Mutex<[String]>([])
        let stub = StubServer { request in
            let query = StubServer.query(request)
            if request.url?.path == "/api/search/get" {
                #expect(query["s"] == "The Nights Avicii")
                #expect(query["type"] == "1")
                return (200, LRCLIBTests.json(["result": ["songs": [
                    // Another artist, a remix far longer, then two that fit: the exact title wins.
                    ["id": 1, "name": "The Nights", "duration": 176_000, "artists": [["name": "Someone Else"]]],
                    ["id": 2, "name": "The Nights (Remix)", "duration": 200_000, "artists": [["name": "Avicii"]]],
                    ["id": 3, "name": "The Nights (Edit)", "duration": 176_200, "artists": [["name": "Avicii"]]],
                    ["id": 4, "name": "the nights", "duration": 177_500, "artists": [["name": "Avicii"], ["name": "Nicholas Furlong"]]],
                ]]]))
            }
            asked.withLock { $0.append(query["id"] ?? "") }
            #expect(request.url?.path == "/api/song/lyric")
            return (200, LRCLIBTests.json(["lrc": ["lyric": """
                [00:00.000] 作词 : Tim Bergling
                [00:00.800] 作曲 : Tim Bergling
                [00:01.000] Producer: Avicii
                [00:12.30]Hey, once upon a younger year
                [00:15.10]When all our shadows disappeared
                """]]))
        }
        let record = try #require(try await stub.netEase.lookUp(Self.song))
        #expect(record.provider == .netease)
        #expect(record.id == "4")
        #expect(asked.withLock { $0 } == ["4"])
        #expect(record.lyrics?.isSynced == true)
        #expect(record.lyrics?.lines.map(\.text) == ["Hey, once upon a younger year", "When all our shadows disappeared"])
    }

    @Test func triesTheNextMatchWhenOneHasNoLyrics() async throws {
        let stub = StubServer { request in
            if request.url?.path == "/api/search/get" {
                return (200, LRCLIBTests.json(["result": ["songs": [
                    ["id": 1, "name": "The Nights", "duration": 176_000, "artists": [["name": "Avicii"]]],
                    ["id": 2, "name": "The Nights", "duration": 176_900, "artists": [["name": "AVICII"]]],
                ]]]))
            }
            let id = StubServer.query(request)["id"]
            return (200, LRCLIBTests.json(id == "1" ? ["lrc": ["lyric": ""]] : ["lrc": ["lyric": "[00:01.00]Hey"]]))
        }
        #expect(try await stub.netEase.lookUp(Self.song)?.id == "2")
    }

    @Test func nothingFoundAndInstrumentals() async throws {
        let empty = StubServer { _ in (200, LRCLIBTests.json(["result": [:], "code": 200])) }
        #expect(try await empty.netEase.lookUp(Self.song) == nil)
        let instrumental = StubServer { request in
            if request.url?.path == "/api/search/get" {
                return (200, LRCLIBTests.json(["result": ["songs": [
                    ["id": 5, "name": "The Nights", "duration": 176_000, "artists": [["name": "Avicii"]]],
                ]]]))
            }
            return (200, LRCLIBTests.json(["lrc": ["lyric": "[99:00.00]纯音乐，请欣赏\n"]]))
        }
        #expect(try await instrumental.netEase.lookUp(Self.song)?.lyrics == .instrumental)
    }
}

/// Issue #53: Lyrics.ovh, against a stub server.
@Suite struct LyricsOvhTests {
    @Test func plainLyricsWithoutTheHeading() async throws {
        let stub = StubServer { request in
            // A slash in the artist stays in the name, not the path.
            #expect(request.url?.absoluteString.hasSuffix("/v1/AC%2FDC/Back%20in%20Black") == true)
            return (200, LRCLIBTests.json(["lyrics": "Paroles de la chanson Back in Black par AC/DC\r\nBack in black\r\nI hit the sack"]))
        }
        let record = try #require(try await stub.lyricsOvh.lookUp(LyricsQuery(title: "Back in Black", artist: "AC/DC", duration: .seconds(255))))
        #expect(record.provider == .lyricsOvh)
        #expect(record.lyrics?.isSynced == false)
        #expect(record.lyrics?.lines.map(\.text) == ["Back in black", "I hit the sack"])
    }

    @Test func notFound() async throws {
        let stub = StubServer { _ in (404, LRCLIBTests.json(["error": "No lyrics found"])) }
        #expect(try await stub.lyricsOvh.lookUp(LyricsQuery(title: "A", artist: "B", duration: .seconds(1))) == nil)
        let blank = StubServer { _ in (200, LRCLIBTests.json(["lyrics": "  \n "])) }
        #expect(try await blank.lyricsOvh.lookUp(LyricsQuery(title: "A", artist: "B", duration: .seconds(1))) == nil)
    }
}

/// Issue #53: providers tried in order, each remembered on its own.
@Suite struct LyricsProviderOrderTests {
    /// A provider that answers from a table of titles, counting what it's asked.
    final class Fake: LyricsProvider, @unchecked Sendable {
        let provider: LyricsProviderID
        let lyrics: [String: String]
        let fails: Bool
        let asked = Mutex<[String]>([])

        init(_ provider: LyricsProviderID, _ lyrics: [String: String] = [:], fails: Bool = false) {
            self.provider = provider
            self.lyrics = lyrics
            self.fails = fails
        }

        func lookUp(_ query: LyricsQuery) async throws -> OnlineLyricsRecord? {
            asked.withLock { $0.append(query.title) }
            if fails { throw LyricsServiceError(provider: provider, status: 503) }
            return lyrics[query.title].map { OnlineLyricsRecord(provider: provider, id: query.title, syncedLyrics: $0) }
        }
    }

    @Test func firstProviderWithLyricsWinsAndEachIsAskedOnce() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let both = try folder.mp3("both.mp3", title: "Both", artist: "Band")
        let second = try folder.mp3("second.mp3", title: "Second", artist: "Band")
        let neither = try folder.mp3("neither.mp3", title: "Neither", artist: "Band")
        let paths = ["both.mp3", "second.mp3", "neither.mp3"].map { folder.canonical($0) }
        try await db.writer.write { d in
            for path in paths { _ = try SchemaTests.insertTrack(path, artist: "Band", album: nil, path: path, d) }
        }
        let lrclib = Fake(.lrclib, ["Both": "[00:01.00]From LRCLIB"])
        let netease = Fake(.netease, ["Both": "[00:01.00]From NetEase", "Second": "[00:01.00]Only NetEase"])
        let finder = LyricsFinder(database: db, providers: [lrclib, netease])

        guard case .found(let a) = try await finder.find(for: both, online: .automatic) else { Issue.record("not found"); return }
        #expect(a.source == .online(.lrclib, id: "Both"))
        guard case .found(let b) = try await finder.find(for: second, online: .automatic) else { Issue.record("not found"); return }
        #expect(b.source == .online(.netease, id: "Second"))
        #expect(try await finder.find(for: neither, online: .automatic) == .notFound(searchedOnline: true))
        // NetEase wasn't asked about the song LRCLIB had.
        #expect(lrclib.asked.withLock { $0 } == ["Both", "Second", "Neither"])
        #expect(netease.asked.withLock { $0 } == ["Second", "Neither"])

        // From the cache, nobody is asked again.
        #expect(try await finder.find(for: second, online: .cachedOnly) == .found(b))
        #expect(try await finder.find(for: neither, online: .automatic) == .notFound(searchedOnline: true))
        #expect(lrclib.asked.withLock { $0.count } == 3)
        #expect(netease.asked.withLock { $0.count } == 2)

        // In the other order, NetEase is asked first and its lyrics win, though LRCLIB has some cached.
        guard case .found(let c) = try await finder.find(for: both, online: .automatic, using: [.netease, .lrclib]) else {
            Issue.record("not found"); return
        }
        #expect(c.lyrics.lines.first?.text == "From NetEase")
        #expect(netease.asked.withLock { $0.count } == 3)
        // A provider turned off isn't asked, and its cached lyrics aren't shown.
        #expect(try await finder.find(for: second, online: .automatic, using: [.lrclib]) == .notFound(searchedOnline: true))
        #expect(try await finder.find(for: second, online: .automatic, using: []) == .notFound(searchedOnline: false))
        // One row per track and provider.
        #expect(try await db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM lyricsLookup") } == 6)
    }

    @Test func aNewProviderIsAskedWithoutWaitingOutTheOthers() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let song = try folder.mp3("song.mp3", title: "Song", artist: "Band")
        let path = folder.canonical("song.mp3")
        try await db.writer.write { d in _ = try SchemaTests.insertTrack("Song", artist: "Band", album: nil, path: path, d) }
        let lrclib = Fake(.lrclib)
        let netease = Fake(.netease, ["Song": "[00:01.00]Hi"])
        let finder = LyricsFinder(database: db, providers: [lrclib, netease])

        #expect(try await finder.find(for: song, online: .automatic, using: [.lrclib]) == .notFound(searchedOnline: true))
        // Turning NetEase on: the cache alone doesn't settle it, so the pane goes on to ask.
        #expect(try await finder.find(for: song, online: .cachedOnly, using: [.lrclib, .netease]) == .notFound(searchedOnline: false))
        guard case .found = try await finder.find(for: song, online: .automatic, using: [.lrclib, .netease]) else {
            Issue.record("not found"); return
        }
        #expect(lrclib.asked.withLock { $0.count } == 1)
        #expect(netease.asked.withLock { $0.count } == 1)
    }

    @Test func aFailingProviderFallsThrough() async throws {
        let folder = try TestFolder()
        let song = try folder.mp3("song.mp3", title: "Song", artist: "Band")
        let down = Fake(.lrclib, fails: true)
        let finder = LyricsFinder(database: nil, providers: [down, Fake(.lyricsOvh, ["Song": "Plain words"])])
        guard case .found(let found) = try await finder.find(for: song, online: .automatic) else { Issue.record("not found"); return }
        #expect(found.source == .online(.lyricsOvh, id: "Song"))
        // With nothing found anywhere, the failure is what's reported.
        let alone = LyricsFinder(database: nil, providers: [down, Fake(.netease)])
        await #expect(throws: LyricsServiceError.self) { try await alone.find(for: song, online: .automatic) }
    }

    @Test func migrationKeepsWhatLRCLIBSaid() throws {
        let queue = try DatabaseQueue()
        var migrator = AppDatabase.migrator
        try migrator.migrate(queue, upTo: "v6")
        try queue.write { d in
            let id = try SchemaTests.insertTrack("A", artist: nil, album: nil, path: "/a.flac", d).id
            let other = try SchemaTests.insertTrack("B", artist: nil, album: nil, path: "/b.flac", d).id
            try d.execute(sql: "INSERT INTO onlineLyrics (trackId, lrclibId, syncedLyrics, instrumental, fetchedAt) VALUES (?, 42, '[00:01.00]Hi', 0, ?)",
                          arguments: [id, Date()])
            try d.execute(sql: "INSERT INTO onlineLyrics (trackId, lrclibId, instrumental, fetchedAt) VALUES (?, NULL, 0, ?)",
                          arguments: [other, Date()])
        }
        migrator = AppDatabase.migrator
        try migrator.migrate(queue)
        let rows = try queue.read { try LyricsLookup.order(Column("trackId")).fetchAll($0) }
        #expect(rows.map(\.provider) == ["lrclib", "lrclib"])
        #expect(rows.first?.found?.source == .online(.lrclib, id: "42"))
        #expect(rows.last?.recordId == nil)
        #expect(try queue.read { try $0.tableExists("onlineLyrics") } == false)
    }
}

/// Issue #53: the order and switches the Lyrics settings keep.
@Suite struct LyricsProviderSettingsTests {
    @Test func startsWithEveryProviderAndOnlyLRCLIBOn() {
        let settings = LyricsProviderSettings()
        #expect(settings.entries.map(\.provider) == LyricsProviderID.allCases)
        #expect(settings.enabled == [.lrclib])
    }

    @Test func reordersAndSwitches() throws {
        var settings = LyricsProviderSettings()
        settings.set(.netease, on: true)
        settings.move(.netease, by: -1)
        #expect(settings.enabled == [.netease, .lrclib])
        settings.move(.netease, by: -5)
        #expect(settings.entries.first?.provider == .netease)
        settings.move(fromOffsets: [0], toOffset: 3)
        #expect(settings.entries.map(\.provider) == [.lrclib, .lyricsOvh, .netease])
        settings.set(.lrclib, on: false)
        #expect(settings.enabled == [.netease])
        // Round-trips through JSON, as kept in the defaults.
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(LyricsProviderSettings.self, from: data) == settings)
    }

    @Test func fillsInNewProvidersAndDropsUnknownOnes() throws {
        let saved = Data(#"{"entries":[{"provider":"lyricsOvh","isOn":true},{"provider":"someday","isOn":true},{"provider":"lyricsOvh","isOn":false}]}"#.utf8)
        let settings = try JSONDecoder().decode(LyricsProviderSettings.self, from: saved)
        #expect(settings.entries.map(\.provider) == [.lyricsOvh, .lrclib, .netease])
        #expect(settings.enabled == [.lyricsOvh, .lrclib])
    }
}

/// Per-track lyrics timing corrections.
@Suite struct LyricsTimingTests {
    @Test func storesAnOffsetPerTrack() throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let url = folder.url.appendingPathComponent("a.flac")
        try db.writer.write { d in _ = try SchemaTests.insertTrack("A", artist: nil, album: nil, path: folder.canonical("a.flac"), d) }
        try folder.flac("a.flac")

        #expect(try db.writer.read { try LyricsTiming.offset(for: url, $0) } == .zero)
        #expect(try db.writer.write { try LyricsTiming.setOffset(.milliseconds(-300), for: url, $0) })
        #expect(try db.writer.read { try LyricsTiming.offset(for: url, $0) } == .milliseconds(-300))
        try db.writer.write { try LyricsTiming.setOffset(.milliseconds(500), for: url, $0) }
        #expect(try db.writer.read { try LyricsTiming.offset(for: url, $0) } == .milliseconds(500))
        // Zero removes the row.
        try db.writer.write { try LyricsTiming.setOffset(.zero, for: url, $0) }
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM lyricsTiming") } == 0)
        // Outside the library there's nowhere to keep it.
        let elsewhere = URL(fileURLWithPath: "/elsewhere.flac")
        #expect(try db.writer.write { try LyricsTiming.setOffset(.seconds(1), for: elsewhere, $0) } == false)
        // It goes with the track.
        try db.writer.write { try LyricsTiming.setOffset(.seconds(1), for: url, $0) }
        try db.writer.write { try $0.execute(sql: "DELETE FROM track") }
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM lyricsTiming") } == 0)
    }
}

/// Serves canned responses on a host of its own, so tests running at once don't mix them up.
final class StubServer: Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    let host = "stub-\(UUID().uuidString.lowercased()).invalid"
    let client: LRCLIB

    init(_ handler: @escaping Handler) {
        client = LRCLIB(userAgent: "miniamp-test/1", configuration: Self.configuration,
                        base: URL(string: "https://\(host)/api/")!)
        StubProtocol.handlers.withLock { $0[host] = handler }
    }

    /// A session configuration whose requests the stubs answer.
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    /// The stub's address, for a provider's `base`.
    func base(_ path: String = "api/") -> URL { URL(string: "https://\(host)/\(path)")! }

    var netEase: NetEase { NetEase(userAgent: "miniamp-test/1", configuration: Self.configuration, base: base()) }
    var lyricsOvh: LyricsOvh { LyricsOvh(userAgent: "miniamp-test/1", configuration: Self.configuration, base: base("v1/")) }

    deinit { StubProtocol.handlers.withLock { _ = $0.removeValue(forKey: host) } }

    static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { a, _ in a }
    }

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        static let handlers = Mutex<[String: Handler]>([:])

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let handler = Self.handlers.withLock { $0[request.url?.host ?? ""] }
            let (status, data) = handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
