import AVFoundation
import CChromaprint
import Foundation
import GRDB

/// Audio fingerprints with Chromaprint (the algorithm AcoustID uses), for finding copies of a
/// recording whatever their tags say.
///
/// A fingerprint is Chromaprint's raw form: one 32-bit value per ~0.12 s of audio, each bit a
/// feature of the sound there. Two encodings of the same recording give mostly the same bits;
/// different recordings agree on about half of them, by chance.
public enum Fingerprints {
    /// The first two minutes are plenty to tell recordings apart, and keep decoding quick.
    static let analysedSeconds = 120.0

    public struct DecodeError: Error, CustomStringConvertible {
        public var path: String
        public var description: String { "can't fingerprint \(path)" }
    }

    /// The raw fingerprint of the file's first two minutes.
    public static func compute(_ url: URL) throws -> [UInt32] {
        let file = try PCMReader.open(url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0,
              let context = chromaprint_new(Int32(CHROMAPRINT_ALGORITHM_DEFAULT.rawValue)) else { throw DecodeError(path: url.path) }
        defer { chromaprint_free(context) }
        guard chromaprint_start(context, Int32(format.sampleRate), Int32(channels)) == 1 else { throw DecodeError(path: url.path) }

        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw DecodeError(path: url.path) }
        var interleaved = [Int16](repeating: 0, count: Int(chunk) * channels)
        var remaining = min(AVAudioFramePosition(analysedSeconds * format.sampleRate), file.length)
        while remaining > 0 {
            // Reading at the end throws (eofErr) rather than returning nothing.
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining)))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for ch in 0..<channels {
                let samples = data[ch]
                for i in 0..<frames {
                    interleaved[i * channels + ch] = Int16(max(-1, min(1, samples[i])) * 32_767)
                }
            }
            let fed = interleaved.withUnsafeBufferPointer { chromaprint_feed(context, $0.baseAddress, Int32(frames * channels)) }
            guard fed == 1 else { throw DecodeError(path: url.path) }
            remaining -= AVAudioFramePosition(frames)
        }
        guard chromaprint_finish(context) == 1 else { throw DecodeError(path: url.path) }

        var raw: UnsafeMutablePointer<UInt32>?
        var size: Int32 = 0
        guard chromaprint_get_raw_fingerprint(context, &raw, &size) == 1, let raw else { throw DecodeError(path: url.path) }
        defer { chromaprint_dealloc(raw) }
        return Array(UnsafeBufferPointer(start: raw, count: Int(size)))
    }

    /// How alike two fingerprints are, 0.5 (unrelated) to 1 (identical): the share of bits
    /// that agree where they line up best, within `maxOffset` items (~10 s) of each other.
    /// 0 when they can't be lined up over enough audio to say.
    public static func similarity(_ a: [UInt32], _ b: [UInt32], maxOffset: Int = 80) -> Double {
        let minimumOverlap = max(40, min(a.count, b.count) / 2)
        var best = 0.0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for offset in -maxOffset...maxOffset {
                    // a[i] lines up with b[i + offset].
                    let start = max(0, -offset), end = min(a.count, b.count - offset)
                    let overlap = end - start
                    guard overlap >= minimumOverlap else { continue }
                    var errors = 0
                    for i in start..<end { errors += (a[i] ^ b[i + offset]).nonzeroBitCount }
                    best = max(best, 1 - Double(errors) / Double(overlap * 32))
                }
            }
        }
        return best
    }

    /// At or above this, two fingerprints are taken to be the same recording. Different
    /// encodings of one recording score about 0.9 or more; unrelated audio about 0.5 to 0.65.
    public static let matchThreshold = 0.8

    // MARK: Storage (Schema.v6)

    static func encode(_ values: [UInt32]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [UInt32] {
        data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }

    public static func store(_ values: [UInt32], for track: Track, _ db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO fingerprint (trackId, modifiedAt, fingerprint) VALUES (?, ?, ?)",
                       arguments: [track.id, track.modifiedAt, encode(values)])
    }

    /// Local tracks with no fingerprint, or one taken before their file last changed.
    public static func unfingerprinted(_ db: Database) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT track.* FROM track LEFT JOIN fingerprint ON fingerprint.trackId = track.id
            WHERE track.isEvicted = 0 AND (fingerprint.trackId IS NULL OR fingerprint.modifiedAt != track.modifiedAt)
            ORDER BY track.id
            """)
    }

    /// Current fingerprints by track id (stale and empty ones left out).
    static func all(_ db: Database) throws -> [Int64: [UInt32]] {
        var out: [Int64: [UInt32]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT fingerprint.trackId, fingerprint.fingerprint FROM fingerprint
            JOIN track ON track.id = fingerprint.trackId AND track.modifiedAt = fingerprint.modifiedAt
            """) {
            let values = decode(row[1])
            if !values.isEmpty { out[row[0]] = values }
        }
        return out
    }

    // MARK: Matching

    /// Pairs of tracks whose fingerprints match.
    ///
    /// Comparing every pair would be quadratic, so candidates come from an index of
    /// fingerprint values: copies of a recording share many exact values, unrelated tracks
    /// few. Values found in very many tracks (silence, say) say nothing and are skipped.
    static func matchingPairs(_ fingerprints: [Int64: [UInt32]]) -> [(Int64, Int64)] {
        var index: [UInt32: [Int64]] = [:]
        for (id, values) in fingerprints {
            for value in Set(values) { index[value, default: []].append(id) }
        }
        let commonLimit = max(20, fingerprints.count / 50)
        var shared: [Pair: Int] = [:]
        for ids in index.values where ids.count > 1 && ids.count <= commonLimit {
            for i in ids.indices {
                for j in ids.index(after: i)..<ids.endIndex {
                    shared[Pair(ids[i], ids[j]), default: 0] += 1
                }
            }
        }
        return shared.compactMap { pair, count in
            guard count >= 8, let a = fingerprints[pair.low], let b = fingerprints[pair.high],
                  similarity(a, b) >= matchThreshold else { return nil }
            return (pair.low, pair.high)
        }
    }

    private struct Pair: Hashable {
        var low: Int64, high: Int64
        init(_ a: Int64, _ b: Int64) { (low, high) = a < b ? (a, b) : (b, a) }
    }
}

public struct FingerprintProgress: Sendable, Equatable {
    public var tracksDone = 0
    public var tracksTotal = 0
    /// Files that couldn't be decoded, or were too short (a few seconds) to fingerprint.
    public var failed = 0
}
