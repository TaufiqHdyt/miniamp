import Accelerate
import AVFoundation
import CDSD
import Synchronization

/// Turns a DSD file into frames the player can schedule, in one of two ways:
///
/// - **DoP** (DSD over PCM) for DACs that play DSD: each 24-bit frame carries 16 DSD bits of a
///   channel under a marker byte that alternates 0x05 and 0xFA, at a sixteenth of the DSD rate
///   (176.4 kHz for DSD64). The DAC spots the markers and plays the bits as DSD. The frames must
///   reach it bit for bit: no DSP, no volume, no resampling.
/// - **PCM**, for everything else, in two stages. A short filter read a byte at a time (see
///   LookupFilter) takes the bits down to eight times the base rate (352.8 kHz), rejecting
///   everything that would fold into the audio band; a 128-tap low-pass at about 30 kHz then
///   decimates by four to twice the base rate (88.2 kHz for DSD64, which a 96 kHz device takes
///   as is after the usual fallback). DSD's full scale is ±1. The response is that of a single
///   1024-tap filter at a quarter of the work, and the first stage's table fits in the cache
///   of an efficiency core, where playback mostly runs.
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
    private let stages: DSDFilterStages?
    private var scratch: [UInt8] = []
    private var intermediate: [Float] = []

    init(file: DSDFile, mode: Mode) throws {
        self.file = file
        self.mode = mode
        let rate: Double
        switch mode {
        case .dop:
            bytesPerFrame = 2
            rate = Double(file.sampleRate) / 16
            stages = nil
        case .pcm:
            // Down to twice the base rate: a decimation of 32 for DSD64, 64 for DSD128.
            let filters = DSDFilterStages.shared(multiple: file.multiple, baseRate: file.baseRate)
            bytesPerFrame = filters.firstStep * DSDFilterStages.secondDecimation
            rate = Double(file.baseRate * 2)
            stages = filters
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
        guard let stages else { return }
        let step = stages.firstStep, window = stages.first.bytes
        let decimation = DSDFilterStages.secondDecimation, taps = stages.second.count
        // Output n stands for DSD time n / output rate; each stage's window is centred on the
        // sample it makes, so the conversion adds no delay. Stage-one samples needed: those
        // under the second stage's windows, from 4·first − taps/2 on.
        let firstIntermediate = framePosition * Int64(decimation) - Int64(taps / 2)
        let intermediates = (frames - 1) * decimation + taps
        let firstByte = firstIntermediate * Int64(step) - Int64(window / 2)
        let count = (intermediates - 1) * step + window
        if scratch.count < count { scratch = [UInt8](repeating: 0, count: count) }
        if intermediate.count < intermediates { intermediate = [Float](repeating: 0, count: intermediates) }
        scratch.withUnsafeMutableBufferPointer { bytes in
            file.copyBytes(channel: channel, from: firstByte, count: count, into: bytes.baseAddress!)
            intermediate.withUnsafeMutableBufferPointer { mid in
                stages.first.table.withUnsafeBufferPointer { table in
                    dsd_filter(bytes.baseAddress!, intermediates, step, table.baseAddress!, window, mid.baseAddress!)
                }
                stages.second.withUnsafeBufferPointer { h in
                    vDSP_desamp(mid.baseAddress!, vDSP_Stride(decimation), h.baseAddress!, out,
                                vDSP_Length(frames), vDSP_Length(taps))
                }
            }
        }
    }
}

/// The two filters that turn DSD into PCM (see DSDDecoder), kept per rate.
final class DSDFilterStages: Sendable {
    /// The second stage takes eight times the base rate to two times.
    static let secondDecimation = 4

    /// Bits to eight times the base rate: −6 dB at 100 kHz (for the 44.1 kHz family), flat to
    /// 40 kHz and down by the Blackman window's 74 dB from 160 kHz, so nothing that would
    /// fold back below 40 kHz gets through.
    let first: LookupFilter
    /// DSD bytes per first-stage sample (1 for DSD64, 2 for DSD128).
    let firstStep: Int
    /// −6 dB at 30 kHz, flat to about 22 kHz, and 74 dB down from about 38 kHz.
    let second: [Float]

    init(multiple: Int, baseRate: Int) {
        firstStep = max(multiple / 64, 1)
        let sampleRate = Double(multiple * baseRate)
        first = LookupFilter(coefficients: Self.lowPass(taps: 128 * firstStep, cutoff: 2.27 * Double(baseRate) / sampleRate))
        second = Self.lowPass(taps: 128, cutoff: 0.68 * Double(baseRate) / Double(8 * baseRate)).map(Float.init)
    }

    /// A Blackman-windowed sinc with unity gain at DC; `cutoff` is a fraction of the sample rate.
    static func lowPass(taps: Int, cutoff: Double) -> [Double] {
        let middle = Double(taps - 1) / 2
        let h = (0..<taps).map { k -> Double in
            let x = Double(k) - middle
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(k) / Double(taps - 1)) + 0.08 * cos(4 * .pi * Double(k) / Double(taps - 1))
            return sinc * w
        }
        let sum = h.reduce(0, +)
        return h.map { $0 / sum }
    }

    private static let cache = Mutex<[Int: DSDFilterStages]>([:])

    static func shared(multiple: Int, baseRate: Int) -> DSDFilterStages {
        cache.withLock { cache in
            let key = multiple * baseRate
            if let stages = cache[key] { return stages }
            let stages = DSDFilterStages(multiple: multiple, baseRate: baseRate)
            cache[key] = stages
            return stages
        }
    }
}

/// An FIR filter on DSD bits applied a byte at a time: for each byte of the window, a table of
/// what its 256 possible values add to the output (bits as ±1, the earliest the top bit).
final class LookupFilter: Sendable {
    /// Bytes in the window (8 taps each).
    let bytes: Int
    /// `bytes` × 256 partial sums.
    let table: [Float]

    init(coefficients h: [Double]) {
        bytes = h.count / 8
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
}
