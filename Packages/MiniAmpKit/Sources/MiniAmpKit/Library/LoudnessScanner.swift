import AVFoundation
import CEBUR128
import Foundation
import GRDB
import os

public struct LoudnessProgress: Sendable, Equatable {
    public var tracksDone = 0
    public var tracksTotal = 0
    /// Files that couldn't be decoded, or were silent.
    public var failed = 0
}

/// Measures tracks for ReplayGain with libebur128: EBU R128 integrated loudness and sample peak.
///
/// An album is measured as a whole, so its album gain comes from the loudness of all its audio
/// together, not an average of its tracks'. Albums are measured in parallel, one per core.
enum LoudnessScanner {
    static let log = Logger(subsystem: "dev.miniamp", category: "loudness")

    /// The tracks to measure, in groups that share an album gain: the given tracks' whole
    /// albums (one track's album gain needs all of them), and tracks with no album on their own.
    static func groups(for trackIds: [Int64], _ db: Database) throws -> [[Track]] {
        let ids = Set(trackIds)
        let chosen = try Track.filter(keys: Array(ids)).fetchAll(db).filter { !$0.isEvicted && $0.durationMs > 0 }
        let albumIds = Set(chosen.compactMap(\.albumId))
        var groups = chosen.filter { $0.albumId == nil }.map { [$0] }
        if !albumIds.isEmpty {
            let albumTracks = try Track.filter(albumIds.contains(Track.Columns.albumId))
                .filter(Track.Columns.isEvicted == false)
                .order(Track.Columns.discNumber, Track.Columns.trackNumber)
                .fetchAll(db)
            groups += Dictionary(grouping: albumTracks, by: { $0.albumId! }).values.map(Array.init)
        }
        return groups
    }

    /// Measures one album (or lone track): a gain for each track, nil for those that couldn't be measured.
    static func measure(_ tracks: [Track]) -> [ReplayGain?] {
        let meters = tracks.map { track -> LoudnessMeter? in
            do { return try LoudnessMeter.measure(track.url) } catch {
                log.error("can't measure \(track.path, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
        let measured = meters.compactMap { $0 }.filter { $0.loudness != nil }
        let album = tracks.count > 1 && tracks.first?.albumId != nil ? LoudnessMeter.loudness(of: measured) : nil
        let albumPeak = measured.map(\.peak).max()
        return meters.map { meter in
            guard let meter, let loudness = meter.loudness else { return nil }
            return ReplayGain(trackGain: ReplayGain.referenceLoudness - loudness, trackPeak: meter.peak,
                              albumGain: album.map { ReplayGain.referenceLoudness - $0 },
                              albumPeak: album == nil ? nil : albumPeak)
        }
    }
}

/// One file's EBU R128 measurement (libebur128 state).
final class LoudnessMeter: @unchecked Sendable {
    private let state: UnsafeMutablePointer<ebur128_state>
    private let channels: Int

    enum MeterError: Error { case unsupportedFormat, cantCreateMeter }

    private init(channels: Int, sampleRate: Double) throws {
        guard let state = ebur128_init(UInt32(channels), UInt(sampleRate.rounded()),
                                       Int32(EBUR128_MODE_I.rawValue | EBUR128_MODE_SAMPLE_PEAK.rawValue))
        else { throw MeterError.cantCreateMeter }
        self.state = state
        self.channels = channels
        if channels == 1 {
            // Mono plays from both speakers, so it counts twice (+3 dB), as the standard says.
            ebur128_set_channel(state, 0, Int32(EBUR128_DUAL_MONO.rawValue))
        } else if channels == 6 {
            // 5.1 in file order: L R C LFE Ls Rs. The LFE channel doesn't count.
            let map: [CEBUR128.channel] = [EBUR128_LEFT, EBUR128_RIGHT, EBUR128_CENTER, EBUR128_UNUSED,
                                          EBUR128_LEFT_SURROUND, EBUR128_RIGHT_SURROUND]
            for (index, channel) in map.enumerated() { ebur128_set_channel(state, UInt32(index), Int32(channel.rawValue)) }
        }
    }

    deinit {
        var state: UnsafeMutablePointer<ebur128_state>? = state
        ebur128_destroy(&state)
    }

    /// Decodes the whole file through the meter.
    static func measure(_ url: URL) throws -> LoudnessMeter {
        let file = try PCMReader.open(url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536)
        else { throw MeterError.unsupportedFormat }
        let meter = try LoudnessMeter(channels: channels, sampleRate: format.sampleRate)
        var interleaved = [Float](repeating: 0, count: Int(buffer.frameCapacity) * channels)
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<channels {
                let source = data[c]
                for f in 0..<frames { interleaved[f * channels + c] = source[f] }
            }
            let status = interleaved.withUnsafeBufferPointer { ebur128_add_frames_float(meter.state, $0.baseAddress, frames) }
            guard status == Int32(EBUR128_SUCCESS.rawValue) else { throw MeterError.cantCreateMeter }
        }
        return meter
    }

    /// Integrated loudness in LUFS; nil for silence (nothing above the absolute gate).
    var loudness: Double? {
        var value = 0.0
        guard ebur128_loudness_global(state, &value) == Int32(EBUR128_SUCCESS.rawValue), value.isFinite else { return nil }
        return value
    }

    /// The highest sample on any channel, linear.
    var peak: Double {
        (0..<channels).reduce(0.0) { highest, c in
            var value = 0.0
            ebur128_sample_peak(state, UInt32(c), &value)
            return max(highest, value)
        }
    }

    /// Integrated loudness of all the meters' audio taken together (an album's).
    static func loudness(of meters: [LoudnessMeter]) -> Double? {
        guard !meters.isEmpty else { return nil }
        var states: [UnsafeMutablePointer<ebur128_state>?] = meters.map(\.state)
        var value = 0.0
        let status = states.withUnsafeMutableBufferPointer { ebur128_loudness_global_multiple($0.baseAddress, $0.count, &value) }
        return withExtendedLifetime(meters) { status == Int32(EBUR128_SUCCESS.rawValue) && value.isFinite ? value : nil }
    }
}
