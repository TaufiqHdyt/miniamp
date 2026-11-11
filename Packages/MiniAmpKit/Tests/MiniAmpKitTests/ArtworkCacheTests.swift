import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #17: the thumbnail cache.
@Suite struct ArtworkCacheTests {
    let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("miniamp-art-\(UUID().uuidString)")

    @Test func storesADownscaledJPEGOnce() throws {
        let cache = try ArtworkCache(directory: cacheDir)
        let image = TestImage.png(width: 1000, height: 500)
        let key = try #require(cache.store(image))
        #expect(key == ArtworkCache.key(for: image))
        #expect(TestImage.pixelSize(of: cache.thumbnailURL(for: key)).map { $0 == (600, 300) } == true)
        #expect(cache.store(image) == key)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).count == 1)
    }

    @Test func rejectsBytesThatArentAnImage() throws {
        #expect(try ArtworkCache(directory: cacheDir).store(Data("not an image".utf8)) == nil)
    }

    @Test func embeddedPictureIsRead() throws {
        let folder = try TestFolder()
        let cover = TestImage.png(width: 20, height: 20)
        let file = try folder.mp3("a.mp3", title: "A", picture: cover)
        #expect(TagReader.read(file, includeArtwork: true)?.artwork == cover)
        #expect(TagReader.read(file)?.artwork == nil)
    }

    @Test func pruneRemovesUnreferencedThumbnails() async throws {
        let cache = try ArtworkCache(directory: cacheDir)
        let kept = try #require(cache.store(TestImage.png(width: 10, height: 10)))
        let dropped = try #require(cache.store(TestImage.png(width: 10, height: 10, red: 0)))
        #expect(try cache.prune(keeping: [kept]) == 1)
        #expect(FileManager.default.fileExists(atPath: cache.thumbnailURL(for: kept).path))
        #expect(!FileManager.default.fileExists(atPath: cache.thumbnailURL(for: dropped).path))
    }
}
