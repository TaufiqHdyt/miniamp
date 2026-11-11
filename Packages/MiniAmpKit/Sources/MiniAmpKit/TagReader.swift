import Foundation
import TagLibBridge

public struct TrackTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Duration
    public var sampleRate: Int
    /// nil for lossy formats (MP3, AAC) that have no fixed bit depth.
    public var bitsPerSample: Int?
    public var channels: Int
    public var bitrateKbps: Int
}

public enum TagReader {
    public static var tagLibVersion: String { String(cString: ma_taglib_version()) }

    /// Returns nil if TagLib can't open the file.
    public static func read(_ url: URL) -> TrackTags? {
        var info = MATagInfo()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { ma_taglib_read($0, &info) } ?? false
        }
        guard ok else { return nil }
        defer { ma_taglib_free(&info) }

        func str(_ p: UnsafeMutablePointer<CChar>?) -> String? { p.map { String(cString: $0) } }
        func num(_ n: UInt32) -> Int? { n == 0 ? nil : Int(n) }

        return TrackTags(
            title: str(info.title),
            artist: str(info.artist),
            album: str(info.album),
            albumArtist: str(info.albumArtist),
            genre: str(info.genre),
            year: num(info.year),
            trackNumber: num(info.trackNumber),
            discNumber: num(info.discNumber),
            duration: .milliseconds(Int(info.durationMs)),
            sampleRate: Int(info.sampleRate),
            bitsPerSample: info.bitsPerSample == 0 ? nil : Int(info.bitsPerSample),
            channels: Int(info.channels),
            bitrateKbps: Int(info.bitrateKbps)
        )
    }
}
