import Foundation
import GRDB

/// A set of tracks that look like the same recording: same title and artist (ignoring case,
/// accents, punctuation, and spacing), and lengths within `Duplicates.durationTolerance`.
public struct DuplicateGroup: Sendable, Identifiable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var info: TrackInfo
        public var plays: Int
        public var id: Int64 { info.track.id ?? 0 }
    }

    /// The tracks' ids, sorted and joined: what a dismissal remembers.
    public var id: String
    public var title: String
    public var artist: String
    /// Best first (see `Duplicates.isBetter`): the first is the one to keep.
    public var entries: [Entry]
}

/// Finding likely duplicates, by tags and duration. (Audio fingerprints are for later.)
public enum Duplicates {
    /// Lengths further apart than this are different recordings (a live take, an edit).
    public static let durationTolerance = 2000 // ms

    public static func find(_ db: Database) throws -> [DuplicateGroup] {
        let infos = try TrackInfo.fetchAll(db, sql: TrackInfo.selectSQL + " WHERE track.artistId IS NOT NULL")
        let plays = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT trackId, count(*) FROM play GROUP BY trackId")
            .map { ($0[0] as Int64, $0[1] as Int) })
        let dismissed = try Set(String.fetchAll(db, sql: "SELECT signature FROM duplicateDismissal"))

        var byKey: [String: [TrackInfo]] = [:]
        for info in infos {
            guard let artist = info.artistName else { continue }
            let key = normalized(info.track.title) + "\u{1F}" + normalized(artist)
            guard key.count > 1 else { continue }
            byKey[key, default: []].append(info)
        }

        var groups: [DuplicateGroup] = []
        for candidates in byKey.values where candidates.count > 1 {
            // Runs of close lengths; a long gap starts a new run.
            var run: [TrackInfo] = []
            func close() {
                defer { run = [] }
                guard run.count > 1 else { return }
                let entries = run.map { DuplicateGroup.Entry(info: $0, plays: plays[$0.track.id!] ?? 0) }.sorted(by: isBetter)
                let id = run.compactMap(\.track.id).sorted().map(String.init).joined(separator: ",")
                guard !dismissed.contains(id) else { return }
                groups.append(DuplicateGroup(id: id, title: entries[0].info.track.title,
                                             artist: entries[0].info.artistName ?? "", entries: entries))
            }
            for info in candidates.sorted(by: { $0.track.durationMs < $1.track.durationMs }) {
                if let last = run.last, info.track.durationMs - last.track.durationMs > durationTolerance { close() }
                run.append(info)
            }
            close()
        }
        return groups.sorted {
            ($0.artist.localizedLowercase, $0.title.localizedLowercase) < ($1.artist.localizedLowercase, $1.title.localizedLowercase)
        }
    }

    /// Hides this group from review until its tracks change (one is added to it, or leaves).
    public static func dismiss(_ group: DuplicateGroup, _ db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO duplicateDismissal (signature) VALUES (?)", arguments: [group.id])
    }

    /// Which of two copies to keep: a local file over one only in the cloud, lossless over
    /// lossy, then the higher sample rate, bit depth, and bitrate; then the more played, and
    /// the one added first.
    public static func isBetter(_ a: DuplicateGroup.Entry, than b: DuplicateGroup.Entry) -> Bool {
        let x = a.info.track, y = b.info.track
        func rank(_ t: Track, _ plays: Int) -> [Double] {
            [t.isEvicted ? 0 : 1, t.bitsPerSample == nil ? 0 : 1, Double(t.sampleRate), Double(t.bitsPerSample ?? 0),
             Double(t.bitrateKbps), Double(plays), -t.addedAt.timeIntervalSince1970]
        }
        let (ra, rb) = (rank(x, a.plays), rank(y, b.plays))
        if ra != rb { return ra.lexicographicallyPrecedes(rb) == false }
        return (x.id ?? 0) < (y.id ?? 0)
    }

    /// "Björk – It's Oh So Quiet!" and "bjork its oh so quiet" match.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
            .map(String.init).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
