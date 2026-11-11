import Foundation
import GRDB
import Synchronization
import Testing
@testable import MiniAmpKit

/// Files offloaded to iCloud Drive (or another File Provider) are listed without downloading them,
/// and read once they're local again.
@Suite struct CloudFileTests {
    /// Stands in for SF_DATALESS, which tests can't set on real files.
    final class Offloaded: Sendable {
        let paths = Mutex<Set<String>>([])
        func set(_ path: String, _ offloaded: Bool) {
            _ = paths.withLock { offloaded ? $0.insert(path).inserted : $0.remove(path) != nil }
        }
        func contains(_ path: String) -> Bool { paths.withLock { $0.contains(path) } }
    }

    let db: AppDatabase
    let folder: TestFolder
    let offloaded = Offloaded()
    let scanner: LibraryScanner
    let record: LibraryFolder

    init() throws {
        db = try AppDatabase.inMemory()
        folder = try TestFolder()
        let offloaded = offloaded
        scanner = LibraryScanner(database: db, artwork: nil, isEvicted: { offloaded.contains($0) })
        var record = LibraryFolder(path: folder.path, bookmark: Data(), addedAt: Date())
        try db.writer.write { try record.insert($0) }
        self.record = record
    }

    func track() throws -> TrackInfo? { try db.writer.read { try LibraryQueries.allTracks($0).first } }

    @Test func offloadedFileIsListedByNameUntilItsDownloaded() async throws {
        try folder.mp3("Artist/04 Song Name.mp3", title: "Real Title", artist: "Real Artist")
        let path = folder.canonical("Artist/04 Song Name.mp3")
        offloaded.set(path, true)

        let first = try await scanner.scan(record)
        #expect(first.added == 1 && first.offloaded == 1 && first.filesToRead == 0)
        let placeholder = try #require(try track())
        #expect(placeholder.track.isEvicted)
        #expect(placeholder.track.title == "04 Song Name")
        #expect(placeholder.track.codec == "MP3")
        #expect(placeholder.artistName == nil)

        // Nothing changes while it stays offloaded.
        let again = try await scanner.scan(record)
        #expect(!again.changedAnything && again.filesToRead == 0)

        // Downloaded: same size and date, but now its tags are read.
        offloaded.set(path, false)
        let downloaded = try await scanner.scan(record, scope: .paths([path]))
        #expect(downloaded.filesToRead == 1 && downloaded.updated == 1)
        let read = try #require(try track())
        #expect(read.track.id == placeholder.track.id)
        #expect(!read.track.isEvicted)
        #expect(read.track.title == "Real Title")
        #expect(read.artistName == "Real Artist")
        #expect(read.track.durationMs > 0)
    }

    @Test func offloadingAReadTrackKeepsItsTags() async throws {
        try folder.mp3("song.mp3", title: "Kept", artist: "Someone")
        _ = try await scanner.scan(record)
        offloaded.set(folder.canonical("song.mp3"), true)

        let result = try await scanner.scan(record)
        #expect(result.filesToRead == 0 && result.offloaded == 1)
        let info = try #require(try track())
        #expect(info.track.isEvicted)
        #expect(info.track.title == "Kept")
        #expect(info.artistName == "Someone")
        #expect(info.track.durationMs > 0)
    }

    @Test func offloadedFileThatMovedKeepsItsIdentity() async throws {
        let file = try folder.mp3("a/song.mp3", title: "Song")
        offloaded.set(folder.canonical("a/song.mp3"), true)
        _ = try await scanner.scan(record)
        let before = try #require(try track())

        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: folder.url.appendingPathComponent("b/song.mp3"))
        offloaded.set(folder.canonical("b/song.mp3"), true)
        let result = try await scanner.scan(record)
        #expect(result.moved == 1 && result.added == 0 && result.removed == 0)
        #expect(try track()?.track.id == before.track.id)
        #expect(try track()?.track.path == folder.canonical("b/song.mp3"))
    }

    @Test func realFilesAreNotReportedOffloaded() throws {
        let folder = try TestFolder()
        let file = try folder.mp3("local.mp3", title: "Local")
        #expect(!CloudFiles.isEvicted(file.path))
        #expect(!CloudFiles.isEvicted(folder.url.appendingPathComponent("missing.mp3").path))
    }

    @Test func readsStillWorkWithDownloadsTurnedOff() throws {
        let folder = try TestFolder()
        let file = try folder.mp3("local.mp3", title: "Local")
        let type = Int32(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES), scope = Int32(IOPOL_SCOPE_THREAD)
        let before = getiopolicy_np(type, scope)
        let (tags, during) = CloudFiles.withoutDownloading { (TagReader.read(file), getiopolicy_np(type, scope)) }
        #expect(tags?.title == "Local")
        #expect(during == Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF))
        #expect(getiopolicy_np(type, scope) == before)
    }
}
