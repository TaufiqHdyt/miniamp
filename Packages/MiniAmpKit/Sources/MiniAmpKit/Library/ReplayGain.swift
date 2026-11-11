import Foundation
import GRDB

/// A track's ReplayGain: how far to turn it up or down (dB) to reach the reference loudness,
/// and its peak sample (linear, 1.0 is full scale), for the track alone and for its album.
public struct ReplayGain: Sendable, Equatable {
    public var trackGain: Double
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?

    public init(trackGain: Double, trackPeak: Double? = nil, albumGain: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }

    /// ReplayGain 2.0's reference: -18 LUFS (EBU R128 integrated loudness).
    public static let referenceLoudness = -18.0

    public enum Source: String, Sendable { case tags, scan }

    public enum Mode: String, Sendable, CaseIterable, Codable {
        case off
        /// Every track at the same loudness.
        case track
        /// Albums at the same loudness, keeping the differences between their tracks. Tracks
        /// with no album gain use their track gain.
        case album
    }

    /// The gain to apply, in dB: the mode's gain plus `preamp`, lowered if needed so the peak
    /// stays at or under full scale (when `preventClipping` and the peak is known).
    public func gain(_ mode: Mode, preamp: Double = 0, preventClipping: Bool = true) -> Double {
        let (base, peak): (Double, Double?) = switch mode {
        case .off: (0, nil)
        case .track: (trackGain, trackPeak)
        case .album: albumGain.map { ($0, albumPeak) } ?? (trackGain, trackPeak)
        }
        guard mode != .off else { return 0 }
        var gain = base + preamp
        if preventClipping, let peak, peak > 0 {
            gain = min(gain, -20 * log10(peak))
        }
        return gain
    }
}

/// ReplayGain rows (see Schema.v2).
public enum ReplayGains {
    /// Stores what a track's tags say, or forgets it when they say nothing.
    static func storeTags(_ gain: ReplayGain?, trackId: Int64, _ db: Database) throws {
        guard let gain else {
            try db.execute(sql: "DELETE FROM replayGain WHERE trackId = ? AND source = 'tags'", arguments: [trackId])
            return
        }
        try store(gain, source: .tags, trackId: trackId, db)
    }

    static func store(_ gain: ReplayGain, source: ReplayGain.Source, trackId: Int64, _ db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO replayGain (trackId, source, trackGain, trackPeak, albumGain, albumPeak)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [trackId, source.rawValue, gain.trackGain, gain.trackPeak, gain.albumGain, gain.albumPeak])
    }

    /// Measurements no longer match audio that changed.
    static func forgetScan(trackId: Int64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM replayGain WHERE trackId = ? AND source = 'scan'", arguments: [trackId])
    }

    /// The ReplayGain for the library track at `path` (as the library spells it): its tags', or else the scan's.
    public static func lookup(path: String, _ db: Database) throws -> ReplayGain? {
        let row = try Row.fetchOne(db, sql: """
            SELECT trackGain, trackPeak, albumGain, albumPeak FROM replayGain
            WHERE trackId = (SELECT id FROM track WHERE path = ?)
            ORDER BY source = 'tags' DESC
            LIMIT 1
            """, arguments: [path])
        return row.map { ReplayGain(trackGain: $0[0], trackPeak: $0[1], albumGain: $0[2], albumPeak: $0[3]) }
    }

    /// Local tracks with no ReplayGain from either source.
    public static func unmeasuredTrackIds(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT id FROM track
            WHERE NOT isEvicted AND durationMs > 0 AND id NOT IN (SELECT trackId FROM replayGain)
            """)
    }
}
