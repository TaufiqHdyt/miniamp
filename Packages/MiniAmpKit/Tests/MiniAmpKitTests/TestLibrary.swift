import Foundation
@testable import MiniAmpKit

/// A temporary folder of audio files for library tests, removed on deinit.
final class TestFolder {
    let url: URL
    /// Canonical, as the library stores it (`/private/var/…`).
    var path: String { LibraryPaths.canonical(url) }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("miniamp-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes the MP3 fixture with an ID3v2 tag to `relativePath`.
    @discardableResult
    func mp3(_ relativePath: String, title: String? = nil, artist: String? = nil, album: String? = nil,
             albumArtist: String? = nil, track: Int? = nil, year: Int? = nil, genre: String? = nil,
             picture: Data? = nil) throws -> URL {
        var frames: [(String, String)] = []
        if let title { frames.append(("TIT2", title)) }
        if let artist { frames.append(("TPE1", artist)) }
        if let album { frames.append(("TALB", album)) }
        if let albumArtist { frames.append(("TPE2", albumArtist)) }
        if let track { frames.append(("TRCK", "\(track)")) }
        if let year { frames.append(("TYER", "\(year)")) }
        if let genre { frames.append(("TCON", genre)) }
        let audio = try Data(contentsOf: TestAudio.mp3Fixture)
        return try write(ID3.tag(frames, picture: picture) + audio, to: relativePath)
    }

    /// Writes a short untagged FLAC to `relativePath`.
    @discardableResult
    func flac(_ relativePath: String) throws -> URL {
        let source = try TestAudio.write(TestAudio.flac44k16, seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: source) }
        return try write(Data(contentsOf: source), to: relativePath)
    }

    @discardableResult
    func write(_ data: Data, to relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func canonical(_ relativePath: String) -> String { path + "/" + relativePath }
}

/// Just enough ID3v2.3 to tag test files.
enum ID3 {
    static func tag(_ frames: [(String, String)], picture: Data? = nil, raw: [(String, Data)] = []) -> Data {
        var body = Data()
        for (id, content) in raw { body += frame(id, content) }
        for (id, text) in frames {
            // Encoding 1: UTF-16 with a byte-order mark.
            var content = Data([1, 0xFF, 0xFE])
            content += text.data(using: .utf16LittleEndian)!
            body += frame(id, content)
        }
        if let picture {
            var content = Data([0]) + Data("image/png".utf8) + Data([0])
            content += Data([3, 0]) // front cover, empty description
            content += picture
            body += frame("APIC", content)
        }
        var header = Data("ID3".utf8) + Data([3, 0, 0])
        header += syncsafe(body.count)
        return header + body
    }

    private static func frame(_ id: String, _ content: Data) -> Data {
        var frame = Data(id.utf8)
        let size = UInt32(content.count).bigEndian
        withUnsafeBytes(of: size) { frame += $0 }
        frame += Data([0, 0])
        return frame + content
    }

    private static func syncsafe(_ n: Int) -> Data {
        Data([UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return try await condition()
}
