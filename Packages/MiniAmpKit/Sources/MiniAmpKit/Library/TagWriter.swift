import Foundation
import TagLibBridge

/// Changes to a file's tags. Nil leaves a tag as it is; an empty string, or zero for the
/// numbers, removes it.
public struct TagChanges: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    /// Lyrics: plain words, or LRC, which is read back through the LRC parser. Saving them
    /// replaces every lyrics tag the file has (an MP3's synced SYLT frame is rewritten from
    /// the LRC's times, for other players); an empty string removes them all.
    public var lyrics: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, year: Int? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                lyrics: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.lyrics = lyrics
    }

    public var isEmpty: Bool { self == TagChanges() }
}

public enum TagWriter {
    public struct WriteError: Error, CustomStringConvertible {
        public var path: String
        public var description: String { "can't save the tags of \(path)" }
    }

    /// Writes `changes` into the file at `url`.
    ///
    /// TagLib edits in place, and a tag that outgrows its padding moves the audio after it.
    /// That's fine for a closed file, but a decoder reading it (the track playing now) would
    /// lose its place. With `replacingFile`, the edit goes to a copy that then replaces the
    /// original: anything that has the file open keeps reading the old one, unchanged.
    public static func write(_ changes: TagChanges, to url: URL, replacingFile: Bool = false) throws {
        guard !changes.isEmpty else { return }
        guard replacingFile else { return try writeInPlace(changes, url) }
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).miniamp-\(UUID().uuidString).\(url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: copy)
        do {
            try writeInPlace(changes, copy)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
    }

    private static func writeInPlace(_ changes: TagChanges, _ url: URL) throws {
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return withText(changes.title) { title in
                withText(changes.artist) { artist in
                    withText(changes.album) { album in
                        withText(changes.albumArtist) { albumArtist in
                            withText(changes.genre) { genre in
                                withText(changes.lyrics) { lyrics in
                                    withSyncedLines(changes.lyrics) { times, texts, count in
                                        var edit = MATagEdit(
                                            title: title, artist: artist, album: album, albumArtist: albumArtist, genre: genre,
                                            year: number(changes.year), trackNumber: number(changes.trackNumber),
                                            discNumber: number(changes.discNumber), lyrics: lyrics,
                                            syncedTimes: times, syncedTexts: texts, syncedCount: count)
                                        return ma_taglib_write(path, &edit)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard ok else { throw WriteError(path: url.path) }
    }

    /// Nil stays NULL (leave the tag alone); text is trimmed, so a blank value removes the tag.
    private static func withText<R>(_ text: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let text else { return body(nil) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).withCString { body($0) }
    }

    /// Synced lyrics' lines, times in milliseconds, for an ID3v2 SYLT frame: none for plain
    /// lyrics, or when the lyrics are left alone.
    private static func withSyncedLines<R>(_ text: String?,
                                           _ body: (UnsafePointer<UInt32>?, UnsafePointer<UnsafePointer<CChar>?>?, Int32) -> R) -> R {
        guard let text else { return body(nil, nil, 0) }
        let lyrics = Lyrics(lrc: text)
        guard lyrics.isSynced, !lyrics.lines.isEmpty else { return body(nil, nil, 0) }
        let times = lyrics.lines.map { UInt32(clamping: $0.time?.wholeMilliseconds ?? 0) }
        let texts = lyrics.lines.map { strdup($0.text) }
        defer { texts.forEach { free($0) } }
        let pointers = texts.map { UnsafePointer($0) }
        return times.withUnsafeBufferPointer { timeBuffer in
            pointers.withUnsafeBufferPointer { textBuffer in
                body(timeBuffer.baseAddress, textBuffer.baseAddress, Int32(lyrics.lines.count))
            }
        }
    }

    /// Nil is -1 (leave alone), 0 removes, anything else is the value.
    private static func number(_ value: Int?) -> Int32 {
        guard let value else { return -1 }
        return Int32(clamping: max(value, 0))
    }
}
