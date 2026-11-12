import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #51: duet voices (`v1:`, `v2:`) in LRC.
@Suite struct LyricsVoiceTests {
    @Test func takesTheVoicePrefixOutOfTheWords() {
        let lyrics = Lyrics(lrc: """
            [00:01.00]v1: First voice
            [00:02.00]v2:Second, no space
            [00:03.00]  v1:  Spaces around
            [00:04.00]No prefix
            [00:05.00]v12: Twelfth
            """)
        #expect(lyrics.lines.map(\.text) == ["First voice", "Second, no space", "Spaces around", "No prefix", "Twelfth"])
        #expect(lyrics.lines.map(\.voice) == [1, 2, 1, nil, 12])
        #expect(lyrics.hasVoices)
    }

    @Test func onlyALineStartPrefixCounts() {
        let lyrics = Lyrics(lrc: """
            [00:01.00]She said v2: nothing
            [00:02.00]V2: capital
            [00:03.00]v0: zero
            [00:04.00]v123: too long
            [00:05.00]v2 no colon
            [00:06.00]version: words
            """)
        #expect(lyrics.lines.map(\.voice) == [nil, nil, nil, nil, nil, nil])
        #expect(lyrics.lines[0].text == "She said v2: nothing")
        #expect(lyrics.lines[5].text == "version: words")
        #expect(!lyrics.hasVoices)
    }

    @Test func worksOnWordTimedLines() {
        let lyrics = Lyrics(lrc: """
            [00:01.00]v2: <00:01.00>Hel<00:01.50>lo
            [00:03.00]<00:03.00>v1: Good<00:03.40>bye
            """)
        #expect(lyrics.lines.map(\.voice) == [2, 1])
        #expect(lyrics.lines.map(\.text) == ["Hello", "Goodbye"])
        #expect(lyrics.lines[0].words.map(\.text) == ["Hel", "lo"])
        #expect(lyrics.lines[1].words.map(\.text) == ["Good", "bye"])
        #expect(lyrics.lines[1].words.map(\.time) == [.seconds(3), .milliseconds(3400)])
    }

    @Test func plainLyricsHaveVoicesToo() {
        let lyrics = Lyrics(lrc: "v1: Mine\nv2: Yours\n\nBoth")
        #expect(!lyrics.isSynced)
        #expect(lyrics.lines.map(\.voice) == [1, 2, nil, nil])
        #expect(lyrics.lines.map(\.text) == ["Mine", "Yours", "", "Both"])
    }

    @Test func writingLRCKeepsVoicesAndWordTimes() {
        let lyrics = Lyrics(lrc: """
            [00:01.00]v1: One
            [00:02.50]v2: <00:02.50>Two <00:03.00>words
            [00:04.00]
            [01:05.25]Last
            """)
        #expect(Lyrics(lrc: lyrics.lrc) == lyrics)
        #expect(lyrics.lrc.hasPrefix("[00:01.00]v1: One\n[00:02.50]v2: <00:02.50>Two <00:03.00>words"))
    }
}

/// Issue #51: the editor's line-by-line LRC.
@Suite struct LyricsDocumentTests {
    static let text = """
        [ar:Someone]
        [00:01.0]v1: First
        [00:02.50]v2: <00:02.50>Two <00:03.00>words

        A plain line
        """

    @Test func anUntouchedDocumentWritesItsTextBack() {
        let document = LyricsDocument(Self.text)
        #expect(document.text == Self.text)
        #expect(document.lines.map(\.isHeader) == [true, false, false, false, false])
        #expect(document.lines.map(\.isLyric) == [false, true, true, false, true])
        #expect(document.lines[2].displayText == "Two words")
        #expect(document.isSynced)
        #expect(document.untimedLyricCount == 1)
        #expect(LyricsDocument(Self.text + "\n").text == Self.text)
    }

    @Test func stampingALineMovesItsWordsWithIt() {
        var document = LyricsDocument(Self.text)
        document.setTime(.seconds(4), ofLine: 2)
        #expect(document.lines[2].times == [.seconds(4)])
        #expect(document.text.contains("[00:04.00]v2: <00:04.00>Two <00:04.50>words"))
        // Other lines keep their form.
        #expect(document.text.contains("[00:01.0]v1: First"))

        document.setTime(.milliseconds(12_345), ofLine: 4)
        #expect(document.text.hasSuffix("[00:12.35]A plain line"))
        #expect(document.untimedLyricCount == 0)

        document.setTime(nil, ofLine: 1)
        #expect(document.text.contains("\nv1: First\n"))
        // A header can't be stamped.
        document.setTime(.seconds(1), ofLine: 0)
        #expect(document.lines[0].body == "[ar:Someone]")
    }

    @Test func shiftingMovesEveryTimeButNotBelowZero() {
        var document = LyricsDocument("[00:00.05][00:10.00]<00:00.05>Chorus")
        document.shift(line: 0, by: .milliseconds(-100))
        #expect(document.text == "[00:00.00][00:09.90]<00:00.00>Chorus")
    }

    @Test func repeatedLinesAreSplitInTimeOrder() {
        var document = LyricsDocument("""
            [ti:Song]
            [00:05.00][00:20.00]Chorus
            [00:10.00]Verse
            Untimed
            """)
        document.splitRepeatedLines()
        #expect(document.text == """
            [ti:Song]
            [00:05.00]Chorus
            [00:10.00]Verse
            [00:20.00]Chorus
            Untimed
            """)
        let before = document
        document.splitRepeatedLines()
        #expect(document == before)
    }

    @Test func formatsToTheHundredth() {
        #expect(LyricsDocument.format(.zero) == "00:00.00")
        #expect(LyricsDocument.format(.milliseconds(83_456)) == "01:23.46")
        #expect(LyricsDocument.format(.seconds(6000)) == "100:00.00")
    }
}

/// Issue #51: lyrics saved into the tags read back as saved, whatever was there before.
@Suite struct LyricsTagTests {
    static let duet = "[00:01.00]v1: Mine\n[00:02.00]v2: <00:02.00>Yo<00:02.30>urs"

    @Test func savedLRCKeepsVoicesAndWordTimesOverAnOldSYLT() async throws {
        let folder = try TestFolder()
        let audio = try Data(contentsOf: TestAudio.mp3Fixture)
        let mp3 = try folder.write(ID3.tag([], raw: [("SYLT", Self.sylt(["Old synced": 1500]))]) + audio, to: "a.mp3")
        #expect(try #require(await LocalLyrics.find(for: mp3)).lyrics.lines.map(\.text) == ["Old synced"])

        try TagWriter.write(TagChanges(lyrics: Self.duet), to: mp3)
        let found = try #require(await LocalLyrics.find(for: mp3))
        #expect(found.lyrics.lines.map(\.text) == ["Mine", "Yours"])
        #expect(found.lyrics.lines.map(\.voice) == [1, 2])
        #expect(found.lyrics.lines[1].words.count == 2)
        // A new SYLT for other players, with the new lines.
        let bytes = try Data(contentsOf: mp3)
        #expect(bytes.range(of: Data("SYLT".utf8)) != nil)
        #expect(bytes.range(of: Data("Old synced".utf8)) == nil)
    }

    @Test func plainLyricsDropTheSYLT() async throws {
        let folder = try TestFolder()
        let audio = try Data(contentsOf: TestAudio.mp3Fixture)
        let mp3 = try folder.write(ID3.tag([], raw: [("SYLT", Self.sylt(["Old synced": 1500]))]) + audio, to: "a.mp3")
        try TagWriter.write(TagChanges(lyrics: "Just words"), to: mp3)
        let found = try #require(await LocalLyrics.find(for: mp3))
        #expect(found.lyrics.lines.map(\.text) == ["Just words"])
        #expect(try Data(contentsOf: mp3).range(of: Data("SYLT".utf8)) == nil)
    }

    @Test func removingClearsEveryKindOfLyricsTag() async throws {
        let folder = try TestFolder()
        let audio = try Data(contentsOf: TestAudio.mp3Fixture)
        // A described USLT and a SYLT, neither of them plain LYRICS.
        var uslt = Data([3]) + Data("eng".utf8) + Data("desc".utf8) + Data([0]) + Data("Described words".utf8)
        let mp3 = try folder.write(ID3.tag([("TIT2", "Kept")], raw: [("USLT", uslt), ("SYLT", Self.sylt(["Synced": 1000]))]) + audio,
                                   to: "a.mp3")
        #expect(await LocalLyrics.find(for: mp3) != nil)
        try TagWriter.write(TagChanges(lyrics: ""), to: mp3)
        #expect(await LocalLyrics.find(for: mp3) == nil)
        #expect(TagReader.read(mp3)?.title == "Kept")
    }

    @Test func flacKeepsTheLRC() async throws {
        let folder = try TestFolder()
        let flac = try folder.flac("a.flac")
        try TagWriter.write(TagChanges(lyrics: Self.duet), to: flac)
        #expect(try #require(await LocalLyrics.find(for: flac)).lyrics.lines.map(\.voice) == [1, 2])
        #expect(await LocalLyrics.text(of: .embedded, for: flac) == Self.duet)
    }

    @Test @MainActor func libraryWritesASidecar() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        let song = try folder.flac("Song.flac")
        let library = Library(database: db, artwork: nil)
        await library.open()
        try await library.addFolder(folder.url)
        await library.waitForScans()
        let track = try #require(try await library.tracks(in: .all).first?.track)

        let sidecar = folder.url.appendingPathComponent("Song.lrc")
        try await library.saveLyrics("[00:01.00]v2: Beside", for: track, to: .sidecar(sidecar))
        let found = try #require(await LocalLyrics.find(for: song))
        #expect(found.source == .sidecar(sidecar))
        #expect(found.lyrics.lines.first?.voice == 2)

        try await library.saveLyrics("[00:01.00]In the tags", for: track, to: .tags)
        await library.waitForScans()
        #expect(await LocalLyrics.text(of: .embedded, for: song) == "[00:01.00]In the tags")
    }

    /// A SYLT frame: UTF-8, English, millisecond times, lyrics, no description.
    static func sylt(_ lines: KeyValuePairs<String, UInt32>) -> Data {
        var data = Data([3]) + Data("eng".utf8) + Data([2, 1, 0])
        for (text, ms) in lines {
            data += Data(text.utf8) + Data([0])
            withUnsafeBytes(of: ms.bigEndian) { data += $0 }
        }
        return data
    }
}
