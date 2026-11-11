import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issues #15 and #17: incremental scanning and artwork.
@Suite struct ScannerTests {
    let db: AppDatabase
    let folder: TestFolder
    let cacheDir: URL
    let scanner: LibraryScanner
    var record: LibraryFolder

    init() throws {
        db = try AppDatabase.inMemory()
        folder = try TestFolder()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("miniamp-art-\(UUID().uuidString)")
        scanner = LibraryScanner(database: db, artwork: try ArtworkCache(directory: cacheDir))
        var record = LibraryFolder(path: folder.path, bookmark: Data(), addedAt: Date())
        try db.writer.write { try record.insert($0) }
        self.record = record
    }

    func tracks() throws -> [TrackInfo] {
        try db.writer.read { try LibraryQueries.allTracks($0) }
    }

    @Test func readsTagsAndGroupsAlbums() async throws {
        try folder.mp3("Björk/Homogenic/01 Hunter.mp3", title: "Hunter", artist: "Björk", album: "Homogenic",
                       track: 1, year: 1997, genre: "Electronic")
        try folder.mp3("Björk/Homogenic/02 Jóga.mp3", title: "Jóga", artist: "Björk", album: "Homogenic", track: 2)
        try folder.mp3("Various/Mix/01.mp3", title: "Guest", artist: "Guest Artist", album: "Mix", albumArtist: "Various")
        try folder.flac("Loose/untitled take.flac")
        try folder.write(Data("not audio".utf8), to: "notes.txt")
        try folder.mp3(".hidden/secret.mp3", title: "Hidden")

        let result = try await scanner.scan(record)
        #expect(result.filesFound == 4)
        #expect(result.added == 4)

        let all = try tracks()
        let hunter = try #require(all.first { $0.track.title == "Hunter" })
        #expect(hunter.artistName == "Björk")
        #expect(hunter.albumTitle == "Homogenic")
        #expect(hunter.albumArtistName == "Björk")
        #expect(hunter.track.trackNumber == 1)
        #expect(hunter.track.year == 1997)
        #expect(hunter.track.genre == "Electronic")
        #expect(hunter.track.codec == "MP3")
        #expect(hunter.track.sampleRate == 44_100)
        #expect(hunter.track.bitsPerSample == nil)
        #expect(hunter.track.durationMs > 0)
        #expect(hunter.track.path == folder.canonical("Björk/Homogenic/01 Hunter.mp3"))

        let guest = try #require(all.first { $0.track.title == "Guest" })
        #expect(guest.artistName == "Guest Artist")
        #expect(guest.albumArtistName == "Various")

        let loose = try #require(all.first { $0.track.codec == "FLAC" })
        #expect(loose.track.title == "untitled take")
        #expect(loose.track.bitsPerSample == 16)
        #expect(loose.artistName == nil && loose.albumTitle == nil)

        let counts = try await db.writer.read { (try Album.fetchCount($0), try Artist.fetchCount($0)) }
        #expect(counts.0 == 2) // Homogenic, Mix
        #expect(counts.1 == 3) // Björk, Guest Artist, Various
    }

    @Test func rescanReadsOnlyWhatChanged() async throws {
        try folder.mp3("a.mp3", title: "A", artist: "One", album: "First")
        try folder.mp3("b.mp3", title: "B", artist: "One", album: "First")
        try folder.mp3("c.mp3", title: "C", artist: "Two", album: "Second")
        _ = try await scanner.scan(record)

        let again = try await scanner.scan(record)
        #expect(again.filesFound == 3)
        #expect(again.filesToRead == 0)
        #expect(!again.changedAnything)

        // Retag one, delete another: its album and artist go with it.
        try folder.mp3("a.mp3", title: "A (Remastered)", artist: "One", album: "First")
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("c.mp3"))
        let changed = try await scanner.scan(record)
        #expect(changed.filesToRead == 1)
        #expect(changed.updated == 1)
        #expect(changed.removed == 1)
        #expect(try tracks().map(\.track.title).sorted() == ["A (Remastered)", "B"])
        let remaining = try await db.writer.read { (try Album.fetchAll($0).map(\.title), try Artist.fetchAll($0).map(\.name)) }
        #expect(remaining.0 == ["First"])
        #expect(remaining.1 == ["One"])
    }

    @Test func movedFileKeepsItsIdentity() async throws {
        try folder.mp3("old/song.mp3", title: "Song", artist: "Someone")
        _ = try await scanner.scan(record)
        let before = try #require(try tracks().first)
        try await db.writer.write { d in
            var play = Play(trackId: before.track.id!, playedAt: Date(), listenedMs: 40_000); try play.insert(d)
        }

        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("new"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder.url.appendingPathComponent("old/song.mp3"),
                                         to: folder.url.appendingPathComponent("new/renamed.mp3"))
        let result = try await scanner.scan(record)
        #expect(result.moved == 1)
        #expect(result.added == 0 && result.removed == 0)
        let after = try #require(try tracks().first)
        #expect(after.track.id == before.track.id)
        #expect(after.track.path == folder.canonical("new/renamed.mp3"))
        #expect(try await db.writer.read { try Play.fetchCount($0) } == 1)
    }

    @Test func pathScopeTouchesOnlyThosePaths() async throws {
        try folder.mp3("keep/one.mp3", title: "One")
        try folder.mp3("gone/two.mp3", title: "Two")
        try folder.mp3("gone/deeper/three.mp3", title: "Three")
        _ = try await scanner.scan(record)

        try folder.mp3("keep/four.mp3", title: "Four")
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("gone"))
        let result = try await scanner.scan(record, scope: .paths([folder.canonical("keep/four.mp3"), folder.canonical("gone")]))
        #expect(result.added == 1)
        #expect(result.removed == 2)
        #expect(result.filesFound == 1) // one.mp3 wasn't in scope, so it wasn't even looked at
        #expect(try tracks().map(\.track.title).sorted() == ["Four", "One"])

        // A path outside the folder, or a hidden one, is ignored.
        try folder.mp3(".cache/x.mp3", title: "X")
        let ignored = try await scanner.scan(record, scope: .paths(["/elsewhere/a.mp3", folder.canonical(".cache/x.mp3")]))
        #expect(ignored.filesFound == 0 && !ignored.changedAnything)
    }

    /// The directory enumerator hands back decomposed (NFD) names while FSEvents reports them
    /// precomposed (NFC); SQLite compares bytes, so both must land on the same stored path.
    @Test func pathsMatchWhateverTheirUnicodeNormalization() async throws {
        try folder.mp3("Ångström/Jóga.mp3", title: "Jóga")
        _ = try await scanner.scan(record)
        let stored = try #require(try tracks().first?.track.path)
        let nfc = folder.canonical("Ångström/Jóga.mp3").precomposedStringWithCanonicalMapping
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(Array(stored.utf8) == Array(nfc.utf8))
        for form in [nfc, nfd] {
            let result = try await scanner.scan(record, scope: .paths([form]))
            #expect(result.filesFound == 1)
            #expect(!result.changedAnything)
        }
        #expect(try tracks().count == 1)
    }

    @Test func unavailableFolderIsAnErrorNotAnEmptyLibrary() async throws {
        try folder.mp3("a.mp3", title: "A")
        _ = try await scanner.scan(record)
        var gone = record
        gone.path = folder.path + "-unmounted"
        await #expect(throws: ScanError.self) { try await scanner.scan(gone) }
        #expect(try tracks().count == 1)
    }

    @Test func embeddedArtworkIsThumbnailedOncePerImage() async throws {
        let cover = TestImage.png(width: 1200, height: 800)
        try folder.mp3("album/1.mp3", title: "One", album: "Art", picture: cover)
        try folder.mp3("album/2.mp3", title: "Two", album: "Art", picture: cover)
        _ = try await scanner.scan(record)

        let all = try tracks()
        let keys = Set(all.compactMap(\.track.artworkKey))
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(key == ArtworkCache.key(for: cover))
        let thumbnail = try ArtworkCache(directory: cacheDir).thumbnailURL(for: key)
        let size = try #require(TestImage.pixelSize(of: thumbnail))
        #expect(size == (600, 400))
        #expect(try await db.writer.read { try Album.fetchOne($0)?.artworkKey } == key)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).filter { $0.hasSuffix(".jpg") }.count == 1)
    }

    @Test func folderImageCoversFilesWithoutEmbeddedArt() async throws {
        let cover = TestImage.png(width: 300, height: 300, red: 0.1, green: 0.5, blue: 0.9)
        try folder.flac("with cover/track.flac")
        try folder.write(cover, to: "with cover/Cover.PNG")
        try folder.flac("without/track.flac")
        _ = try await scanner.scan(record)

        let all = try tracks()
        #expect(all.first { $0.track.path.contains("with cover") }?.track.artworkKey == ArtworkCache.key(for: cover))
        #expect(all.first { $0.track.path.contains("without") }?.track.artworkKey == nil)
        let size = TestImage.pixelSize(of: try ArtworkCache(directory: cacheDir).thumbnailURL(for: ArtworkCache.key(for: cover)))
        #expect(size.map { $0 == (300, 300) } == true) // never upscaled
    }
}
