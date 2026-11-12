import AVFoundation
import CDSD
import Synchronization

/// Turns a DSD file into frames the player can schedule, in one of two ways:
///
/// - **DoP** (DSD over PCM) for DACs that play DSD: each 24-bit frame carries 16 DSD bits of a
///   channel under a marker byte that alternates 0x05 and 0xFA, at a sixteenth of the DSD rate
///   (176.4 kHz for DSD64). The DAC spots the markers and plays the bits as DSD. The frames must
///   reach it bit for bit: no DSP, no volume, no resampling.
/// - **PCM**, for everything else: a low-pass filter (a windowed sinc 32 output samples long, about
///   30 kHz for the 44.1 kHz family) decimates to twice the base rate (88.2 kHz for DSD64,
///   which a 96 kHz device takes as is after the usual fallback). DSD's full scale is ±1.
///
/// Reads like an AVAudioFile: a Float32, deinterleaved processing format, `length`,
/// `framePosition`, `read(into:)`. Not thread-safe; give each thread its own.
final class DSDDecoder {
    enum Mode: Sendable, Equatable { case dop, pcm }

    let file: DSDFile
    let mode: Mode
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition
    var framePosition: AVAudioFramePosition = 0
    /// DoP only: added to a frame's number to pick its marker (even 0x05, odd 0xFA), so the
    /// alternation can carry on unbroken from whatever was played before.
    var markerOffset: Int64 = 0

    /// DSD bytes per output frame, per channel.
    private let bytesPerFrame: Int
    private let filter: LookupFilter?
    private var scratch: [UInt8] = []

    init(file: DSDFile, mode: Mode) throws {
        self.file = file
        self.mode = mode
        let rate: Double
        switch mode {
        case .dop:
            bytesPerFrame = 2
            rate = Double(file.sampleRate) / 16
            filter = nil
        case .pcm:
            // Down to twice the base rate: a decimation of 32 for DSD64, 64 for DSD128.
            let decimation = file.multiple / 2
            bytesPerFrame = decimation / 8
            rate = Double(file.baseRate * 2)
            filter = LookupFilter.shared(decimation: decimation, baseRate: file.baseRate, sampleRate: file.sampleRate)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(file.channels))
        else { throw DSDFile.FileError.unsupported("\(file.channels) channels") }
        processingFormat = format
        length = file.byteCount / Int64(bytesPerFrame)
    }

    convenience init(url: URL, mode: Mode) throws {
        try self.init(file: DSDFile(url: url), mode: mode)
    }

    /// The DoP rate for `file`: what the device must run at to take it.
    static func dopRate(of file: DSDFile) -> Double { Double(file.sampleRate) / 16 }

    func read(into buffer: AVAudioPCMBuffer) throws {
        try read(into: buffer, frameCount: buffer.frameCapacity)
    }

    /// Fills `buffer` from `framePosition` with up to `frameCount` frames and moves past them.
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        let frames = Int(min(AVAudioFramePosition(min(frameCount, buffer.frameCapacity)), max(length - framePosition, 0)))
        guard let channels = buffer.floatChannelData, Int(buffer.format.channelCount) == file.channels else {
            throw DSDFile.FileError.unsupported("buffer format \(buffer.format)")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard frames > 0 else { return }
        for ch in 0..<file.channels {
            switch mode {
            case .dop: dop(channel: ch, frames: frames, into: channels[ch])
            case .pcm: pcm(channel: ch, frames: frames, into: channels[ch])
            }
        }
        framePosition += AVAudioFramePosition(frames)
    }

    private func dop(channel: Int, frames: Int, into out: UnsafeMutablePointer<Float>) {
        let count = frames * 2
        if scratch.count < count { scratch = [UInt8](repeating: 0, count: count) }
        let start = framePosition
        scratch.withUnsafeMutableBufferPointer { bytes in
            file.copyBytes(channel: channel, from: start * 2, count: count, into: bytes.baseAddress!)
            // Exact: every 24-bit integer is a Float32, and the output unit turns it back.
            dsd_pack_dop(bytes.baseAddress!, frames, start, markerOffset, out)
        }
    }

    private func pcm(channel: Int, frames: Int, into out: UnsafeMutablePointer<Float>) {
        guard let filter else { return }
        let taps = filter.bytes
        // Output n stands for DSD bit n × decimation, and the window is centred on it, so the
        // conversion adds no delay.
        let first = framePosition * Int64(bytesPerFrame) - Int64(taps / 2)
        let count = (frames - 1) * bytesPerFrame + taps
        if scratch.count < count { scratch = [UInt8](repeating: 0, count: count) }
        scratch.withUnsafeMutableBufferPointer { bytes in
            file.copyBytes(channel: channel, from: first, count: count, into: bytes.baseAddress!)
            filter.table.withUnsafeBufferPointer { table in
                dsd_filter(bytes.baseAddress!, frames, bytesPerFrame, table.baseAddress!, taps, out)
            }
        }
    }
}

/// A windowed-sinc low-pass for DSD, applied a byte at a time: for each byte of the window, a
/// table of what its 256 possible values add to the output (bits as ±1).
final class LookupFilter: Sendable {
    /// Bytes in the window (8 taps each).
    let bytes: Int
    /// `bytes` × 256 partial sums.
    let table: [Float]

    init(decimation: Int, baseRate: Int, sampleRate: Int) {
        let taps = 32 * decimation
        bytes = taps / 8
        // −6 dB at 0.68 × the base rate (30 kHz for 44.1 kHz): flat through the audio band and
        // well down by the output's Nyquist frequency, before DSD's shaped noise climbs.
        let cutoff = 0.68 * Double(baseRate) / Double(sampleRate)
        let middle = Double(taps - 1) / 2
        var h = (0..<taps).map { k -> Double in
            let x = Double(k) - middle
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(k) / Double(taps - 1)) + 0.08 * cos(4 * .pi * Double(k) / Double(taps - 1))
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        var table = [Float](repeating: 0, count: bytes * 256)
        for t in 0..<bytes {
            for v in 0..<256 {
                var acc = 0.0
                for j in 0..<8 { acc += (v >> (7 - j)) & 1 == 1 ? h[t * 8 + j] : -h[t * 8 + j] }
                table[t * 256 + v] = Float(acc)
            }
        }
        self.table = table
    }

    private static let cache = Mutex<[Int: LookupFilter]>([:])

    /// Building a table takes a few milliseconds, so each rate's is kept.
    static func shared(decimation: Int, baseRate: Int, sampleRate: Int) -> LookupFilter {
        cache.withLock { cache in
            if let filter = cache[sampleRate] { return filter }
            let filter = LookupFilter(decimation: decimation, baseRate: baseRate, sampleRate: sampleRate)
            cache[sampleRate] = filter
            return filter
        }
    }
}
