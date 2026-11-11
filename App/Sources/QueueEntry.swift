import MiniAmpKit
import SwiftUI

/// What the interface shows for a queued file: its tags from the library, or read from the
/// file itself when it isn't in the library (opened with Open…), or its name until either is known.
struct QueueEntry: Equatable {
    var url: URL
    var title: String
    var artist: String?
    var album: String?
    var format: String
    var durationMs: Int?
    /// Library artwork; nil for files outside the library (their cover is read from the file).
    var artworkKey: String?
    var inLibrary = false

    init(fileName url: URL) {
        self.url = url
        title = url.deletingPathExtension().lastPathComponent
        format = url.pathExtension.uppercased()
    }

    init(_ info: TrackInfo, url: URL) {
        self.url = url
        title = info.track.title
        artist = info.artistName
        album = info.albumTitle
        format = TrackFormat.short(info.track)
        durationMs = info.track.durationMs
        artworkKey = info.track.artworkKey
        inLibrary = true
    }

    init(_ tags: TrackTags, url: URL) {
        self.init(fileName: url)
        if let title = tags.title, !title.isEmpty { self.title = title }
        artist = tags.artist
        album = tags.album
        format = TrackFormat.short(codec: tags.codec.isEmpty ? format : tags.codec, sampleRate: tags.sampleRate,
                                   bits: tags.bitsPerSample, bitrateKbps: tags.bitrateKbps)
        let (seconds, attoseconds) = tags.duration.components
        durationMs = Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    /// "Artist — Album", or nil when neither is known.
    var subtitle: String? {
        let parts = [artist, album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    static func load(_ urls: [URL], from library: Library?) async -> [URL: QueueEntry] {
        var entries: [URL: QueueEntry] = [:]
        if let library, let found = try? await library.tracks(at: urls) {
            for (url, info) in found { entries[url] = QueueEntry(info, url: url) }
        }
        let rest = urls.filter { entries[$0] == nil }
        guard !rest.isEmpty, !Task.isCancelled else { return entries }
        // Not in the library: read the tags off the main actor.
        let read = await Task.detached(priority: .userInitiated) {
            rest.compactMap { url in TagReader.read(url).map { (url, $0) } }
        }.value
        for (url, tags) in read { entries[url] = QueueEntry(tags, url: url) }
        return entries
    }
}
