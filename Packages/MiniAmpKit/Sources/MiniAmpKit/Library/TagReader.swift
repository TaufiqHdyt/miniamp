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
    /// "FLAC", "MP3", "ALAC", "AAC", "WAV", "AIFF", or "" when TagLib can't tell.
    public var codec: String
    /// The embedded cover image's bytes, when read with `includeArtwork`.
    public var artwork: Data?
    /// From the REPLAYGAIN_* tags, when the file has them.
    public var replayGain: ReplayGain? = nil
}

public enum TagReader {
    public static var tagLibVersion: String { String(cString: ma_taglib_version()) }

    /// Returns nil if TagLib can't open the file.
    public static func read(_ url: URL, includeArtwork: Bool = false) -> TrackTags? {
        var info = MATagInfo()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { ma_taglib_read($0, includeArtwork, &info) } ?? false
        }
        guard ok else { return nil }
        defer { ma_taglib_free(&info) }

        func str(_ p: UnsafeMutablePointer<CChar>?) -> String? { p.map { String(cString: $0) } }
        func num(_ n: UInt32) -> Int? { n == 0 ? nil : Int(n) }
        func real(_ x: Double) -> Double? { x.isNaN ? nil : x }

        // A file with only an album gain still gets one: it's the best there is for the track too.
        let replayGain = (real(info.replayGainTrackGain) ?? real(info.replayGainAlbumGain)).map { trackGain in
            ReplayGain(trackGain: trackGain,
                       trackPeak: real(info.replayGainTrackPeak) ?? real(info.replayGainAlbumPeak),
                       albumGain: real(info.replayGainAlbumGain),
                       albumPeak: real(info.replayGainAlbumPeak))
        }

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
            bitrateKbps: Int(info.bitrateKbps),
            codec: withUnsafeBytes(of: info.codec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
            artwork: info.picture.map { Data(bytes: $0, count: Int(info.pictureSize)) },
            replayGain: replayGain
        )
    }

    /// The file's embedded lyrics as text (synced ID3 SYLT frames come back as LRC), or nil.
    public static func lyrics(_ url: URL) -> String? {
        let text = url.withUnsafeFileSystemRepresentation { path in path.flatMap { ma_taglib_lyrics($0) } }
        guard let text else { return nil }
        defer { free(text) }
        return String(cString: text)
    }
}
