import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #28: editing tags, and the library picking the edit up.
@Suite(.serialized) struct TagWriterTests {
    @Test(arguments: [false, true])
    func writesMP3AndFLAC(replacingFile: Bool) throws {
        let folder = try TestFolder()
        let mp3 = try folder.mp3("a.mp3", title: "Old", artist: "Someone", album: "Record", track: 3, genre: "Rock")
        let flac = try folder.flac("b.flac")
        let changes = TagChanges(title: "Ünïcode Title", artist: "", albumArtist: "Various", year: 2024,
                                 trackNumber: 7, discNumber: 2)
        for url in [mp3, flac] {
            try TagWriter.write(changes, to: url, replacingFile: replacingFile)
            let tags = try #require(TagReader.read(url))
            #expect(tags.title == "Ünïcode Title")
            #expect(tags.artist == nil)
            #expect(tags.albumArtist == "Various")
            #expect(tags.year == 2024)
            #expect(tags.trackNumber == 7)
            #expect(tags.discNumber == 2)
            #expect(tags.duration > .zero)
        }
        // Untouched tags stay.
        #expect(TagReader.read(mp3)?.album == "Record")
        #expect(TagReader.read(mp3)?.genre == "Rock")
        // No copies left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(Set(left) == ["a.mp3", "b.flac"])
    }

    @Test func keepsTheTrackTotal() throws {
        let folder = try TestFolder()
        let audio = try Data(contentsOf: TestAudio.mp3Fixture)
        let url = try folder.write(ID3.tag([("TRCK", "3/12")]) + audio, to: "a.mp3")
        try TagWriter.write(TagChanges(trackNumber: 5), to: url)
        #expect(TagReader.read(url)?.trackNumber == 5)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("5/12".utf8)) != nil || bytes.range(of: "5/12".data(using: .utf16LittleEndian)!) != nil)
        try TagWriter.write(TagChanges(trackNumber: 0), to: url)
        #expect(TagReader.read(url)?.trackNumber == nil)
    }

    @Test func replacingKeepsAnOpenFileReadable() throws {
        let folder = try TestFolder()
        let url = try folder.flac("a.flac")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let before = try handle.readToEnd()
        // A long title outgrows any padding, so an in-place edit would shift the audio.
        try TagWriter.write(TagChanges(title: String(repeating: "x", count: 20_000)), to: url, replacingFile: true)
        try handle.seek(toOffset: 0)
        #expect(try handle.readToEnd() == before)
        #expect(TagReader.read(url)?.title?.count == 20_000)
    }

    @Test func failsForAFileTagLibCantOpen() throws {
        let folder = try TestFolder()
        let url = try folder.write(Data("not audio".utf8), to: "a.flac")
        #expect(throws: TagWriter.WriteError.self) { try TagWriter.write(TagChanges(title: "x"), to: url) }
    }

    /// The milestone's "done when": the edit is in the library at once and survives a full rescan.
    @Test @MainActor func libraryEditSurvivesAFullRescan() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        try folder.mp3("a.mp3", title: "Old Title", artist: "Old Artist", album: "Album")
        let library = Library(database: db, artwork: nil)
        await library.open()
        try await library.addFolder(folder.url)
        await library.waitForScans()
        let track = try #require(try await library.search("old title").first?.track)

        try await library.editTags(of: [track], TagChanges(title: "New Title", artist: "New Artist"))
        await library.waitForScans()
        var found = try await library.search("new title")
        #expect(found.map(\.track.id) == [track.id])
        #expect(found.first?.artistName == "New Artist")
        #expect(try await library.search("old artist").isEmpty)

        library.rescan()
        await library.waitForScans()
        found = try await library.tracks(in: .all)
        #expect(found.map(\.track.title) == ["New Title"])
        #expect(found.first?.track.id == track.id)
        #expect(library.lastError == nil)
    }
}
