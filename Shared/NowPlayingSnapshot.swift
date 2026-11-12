import Foundation

/// What's playing, written by the app for the widget, in the app group's container.
struct NowPlayingSnapshot: Codable, Equatable {
    var title: String
    var artist: String?
    var album: String?
    var isPlaying: Bool
    /// Seconds into the track at `positionDate`.
    var position: Double
    var positionDate: Date
    var duration: Double
    /// Changes when the cover does, so the widget knows to reload it.
    var artworkID: String?

    /// When the track started (or would have, at this position), for a live progress bar.
    var startDate: Date { positionDate.addingTimeInterval(-position) }

    static let empty = NowPlayingSnapshot(title: "Not Playing", isPlaying: false, position: 0, positionDate: .distantPast,
                                          duration: 0)
}

enum SharedContainer {
    /// The app group the app and the widget share; in each target's Info.plist, since it
    /// carries the signing team's prefix.
    static var groupIdentifier: String? { Bundle.main.object(forInfoDictionaryKey: "MiniAmpAppGroup") as? String }

    static var url: URL? {
        groupIdentifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var snapshotURL: URL? { url?.appendingPathComponent("now-playing.json") }
    static var artworkURL: URL? { url?.appendingPathComponent("now-playing-artwork.jpg") }

    static func readSnapshot() -> NowPlayingSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    static let widgetKind = "dev.miniamp.now-playing"
}
