import Foundation
import GRDB
import Testing
@testable import MiniAmpKit

/// Issue #16: picking up changes without a manual rescan.
@Suite(.serialized) struct LibraryTests {
    @Test func watcherReportsNewChangedAndRemovedFiles() async throws {
        let folder = try TestFolder()
        let batches = Batches()
        let watcher = FolderWatcher(roots: [folder.path], latency: 0.2) { batches.append($0) }
        defer { watcher.invalidate() }
        try await Task.sleep(for: .milliseconds(300)) // FSEvents starts asynchronously

        let file = try folder.mp3("sub/new.mp3", title: "New")
        #expect(await eventually { batches.paths.contains(folder.canonical("sub/new.mp3")) })
        try FileManager.default.removeItem(at: file)
        batches.clear()
        #expect(await eventually { batches.paths.contains(folder.canonical("sub/new.mp3")) })
    }

    @Test func libraryPicksUpChangesWithoutARescan() async throws {
        let db = try AppDatabase.inMemory()
        let folder = try TestFolder()
        try folder.mp3("a.mp3", title: "First")
        let library = await Library(database: db, artwork: nil)
        await library.open()
        try await library.addFolder(folder.url)
        await library.waitForScans()
        #expect(await library.trackCount == 1)

        try folder.mp3("Album/b.mp3", title: "Second Song", artist: "New Artist")
        #expect(await eventually { await library.trackCount == 2 })
        #expect(try await library.search("second").map(\.track.title) == ["Second Song"])

        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("Album"))
        #expect(await eventually { await library.trackCount == 1 })
        #expect(try await library.search("new artist").isEmpty)
        await library.waitForScans()
        #expect(await library.lastError == nil)
    }
}

/// Collects watcher batches across threads.
final class Batches: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FolderWatcher.Batch] = []
    func append(_ batch: FolderWatcher.Batch) { lock.withLock { all.append(batch) } }
    func clear() { lock.withLock { all.removeAll() } }
    var paths: Set<String> { lock.withLock { all.reduce(into: []) { $0.formUnion($1.paths) } } }
}
