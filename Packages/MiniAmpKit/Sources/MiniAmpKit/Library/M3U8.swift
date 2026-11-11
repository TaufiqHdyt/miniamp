import Foundation

/// Extended M3U in UTF-8 (.m3u8), the playlist format most players read.
///
///     #EXTM3U
///     #PLAYLIST:Road Trip
///     #EXTINF:241,Artist - Title
///     Music/Artist/Album/01 Title.flac
///
/// Files under the playlist's own folder are written relative to it, so the folder can move
/// (or be copied to another machine) with the playlist; anything else gets its full path.
public enum M3U8 {
    public static func export(_ tracks: [TrackInfo], name: String? = nil, savedIn directory: URL? = nil) -> String {
        let base = directory.map { LibraryPaths.canonical($0) }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var lines = ["#EXTM3U"]
        if let name = name.nonBlank { lines.append("#PLAYLIST:\(singleLine(name))") }
        for info in tracks {
            let track = info.track
            // -1 is "unknown" (an offloaded file whose tags were never read).
            let seconds = track.durationMs > 0 ? Int((Double(track.durationMs) / 1000).rounded()) : -1
            let title = singleLine(track.title)
            let label = info.artistName.nonBlank.map { "\(singleLine($0)) - \(title)" } ?? title
            lines.append("#EXTINF:\(seconds),\(label)")
            if let base, track.path.hasPrefix(base) {
                lines.append(String(track.path.dropFirst(base.count)))
            } else {
                lines.append(track.path)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Line breaks would end the entry early.
    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}
