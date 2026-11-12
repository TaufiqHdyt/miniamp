import Foundation
import MiniAmpKit

/// How tracks' formats and times are written everywhere in the app.
enum TrackFormat {
    /// "FLAC 96/24", "MP3 320k".
    static func short(_ track: Track) -> String {
        short(codec: track.codec, sampleRate: track.sampleRate, bits: track.bitsPerSample, bitrateKbps: track.bitrateKbps)
    }

    static func short(codec: String, sampleRate: Int, bits: Int?, bitrateKbps: Int) -> String {
        guard sampleRate > 0 else { return codec }
        // "DSD64" says it all: the rate is 64 × 44.1 kHz, one bit deep.
        if codec.hasPrefix("DSD") { return codec }
        let khz = Double(sampleRate) / 1000
        let rate = khz == khz.rounded() ? "\(Int(khz))" : String(format: "%.1f", khz)
        if let bits { return "\(codec) \(rate)/\(bits)" }
        return bitrateKbps > 0 ? "\(codec) \(bitrateKbps)k" : "\(codec) \(rate)"
    }
}

enum TimeFormat {
    /// "3:07", "1:02:03".
    static func minutes(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension ReplayGain.Mode {
    var label: String {
        switch self {
        case .off: "Off"
        case .track: "Track"
        case .album: "Album"
        }
    }
}
