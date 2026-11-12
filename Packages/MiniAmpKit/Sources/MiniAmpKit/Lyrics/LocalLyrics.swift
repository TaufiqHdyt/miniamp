import Foundation

/// Lyrics for a track, and where they came from.
public struct FoundLyrics: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// A `.lrc` file beside the track.
        case sidecar(URL)
        /// The track's own tags.
        case embedded
        /// LRCLIB, by its record id.
        case lrclib(id: Int)
    }

    public var lyrics: Lyrics
    public var source: Source

    public init(lyrics: Lyrics, source: Source) {
        self.lyrics = lyrics
        self.source = source
    }
}

/// Lyrics that come with the file: a sidecar `.lrc`, or the tags.
public enum LocalLyrics {
    /// A sidecar `.lrc` wins over the tags, unless it's plain and the tags are synced.
    @concurrent
    public static func find(for url: URL) async -> FoundLyrics? {
        let sidecarURL = sidecar(for: url)
        let sidecar = sidecarURL.flatMap { try? Data(contentsOf: $0) }.flatMap(decode).map(Lyrics.init(lrc:))
            .flatMap { $0.isEmpty ? nil : $0 }
        if let sidecar, sidecar.isSynced { return FoundLyrics(lyrics: sidecar, source: .sidecar(sidecarURL!)) }
        let embedded = TagReader.lyrics(url).map(Lyrics.init(lrc:)).flatMap { $0.isEmpty ? nil : $0 }
        if let embedded, embedded.isSynced || sidecar == nil { return FoundLyrics(lyrics: embedded, source: .embedded) }
        return sidecar.map { FoundLyrics(lyrics: $0, source: .sidecar(sidecarURL!)) }
    }

    /// "Song.flac" → "Song.lrc" beside it, if there is one.
    public static func sidecar(for url: URL) -> URL? {
        let base = url.deletingPathExtension()
        return ["lrc", "LRC"].lazy.map { base.appendingPathExtension($0) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// UTF-8, or UTF-16 with a byte-order mark; failing those, whatever Foundation detects
    /// (old LRC files are often in a legacy encoding: Windows-1252, Shift JIS, GB 18030).
    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        let suggested: [UInt] = [
            String.Encoding.shiftJIS.rawValue,
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)),
            String.Encoding.windowsCP1252.rawValue,
        ]
        _ = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: suggested],
                                    convertedString: &converted, usedLossyConversion: nil)
        return converted as String?
    }
}

extension LocalLyrics {
    /// The text of the lyrics as they're stored, to edit: the `.lrc` file, or the tags.
    @concurrent
    public static func text(of source: FoundLyrics.Source, for url: URL) async -> String? {
        switch source {
        case .sidecar(let file): (try? Data(contentsOf: file)).flatMap(decode)
        case .embedded: TagReader.lyrics(url)
        case .lrclib: nil
        }
    }
}
