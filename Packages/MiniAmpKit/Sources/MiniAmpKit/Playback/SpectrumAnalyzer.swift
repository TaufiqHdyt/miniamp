import Accelerate
import Foundation

/// Turns the sound going out into a spectrum analyser's bars, moving the way Winamp's do: a bar
/// jumps up to the level at once and sinks back slowly; above it a peak cap hangs for half a
/// second, then drops faster and faster.
///
/// Each update takes the latest `fftSize` samples, Hann-windowed, through a real FFT, and gives
/// each of `bandCount` bands spaced evenly in pitch (50 Hz to 16 kHz) the loudest bin within it.
/// Levels run 0...1 over the top `range` dB, a full-scale sine reaching 1. Not thread-safe:
/// give each display its own.
public final class SpectrumAnalyzer {
    public static let lowest = 50.0
    public static let highest = 16_000.0
    /// dB shown, from full scale down.
    public static let range: Float = 66
    /// dB added per octave above 1 kHz (taken off below), so music, whose highs are quieter,
    /// fills the bars more evenly.
    public static let slope: Float = 3
    /// Heights per second a bar sinks.
    public static let fall: Float = 1.8
    /// How long a peak cap hangs before it drops, and how fast it then speeds up.
    public static let hold = 0.5
    public static let peakAcceleration: Float = 4

    public let bandCount: Int
    public let fftSize: Int
    public private(set) var levels: [Float]
    public private(set) var peaks: [Float]

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var targets: [Float]
    private var holds: [Double]
    private var speeds: [Float]
    /// Per band: its first and last bin, and its dB correction; for `bandsRate`.
    private var bands: [(first: Int, last: Int, tilt: Float)] = []
    private var bandsRate = 0.0

    public init(bandCount: Int, fftSize: Int = 2048) {
        precondition(fftSize.nonzeroBitCount == 1 && fftSize >= 64)
        self.bandCount = max(bandCount, 1)
        self.fftSize = fftSize
        fft = vDSP.FFT(log2n: vDSP_Length(fftSize.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        samples = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imaginary = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        levels = [Float](repeating: 0, count: self.bandCount)
        peaks = levels
        targets = levels
        holds = [Double](repeating: 0, count: self.bandCount)
        speeds = levels
    }

    /// Whether every bar and cap is at the bottom: nothing moves until the sound comes back.
    public var isSettled: Bool { levels.allSatisfy { $0 == 0 } && peaks.allSatisfy { $0 == 0 } }

    /// Reads what's being heard from `tap` and moves the bars on by `dt` seconds. Silence when
    /// the tap has nothing (paused, or DoP).
    public func update(from tap: SampleTap, dt: Double) {
        let heard = samples.withUnsafeMutableBufferPointer { tap.latest(fftSize, into: $0.baseAddress!) }
        guard heard else { return fade(by: dt) }
        analyze(sampleRate: tap.sampleRate)
        advance(by: dt)
    }

    /// Moves on by `dt` seconds with nothing playing: the bars and caps fall.
    public func fade(by dt: Double) {
        for i in targets.indices { targets[i] = 0 }
        advance(by: dt)
    }

    /// Analyses `input` (at least `fftSize` samples, the newest last) and moves on by `dt`.
    public func update(samples input: [Float], sampleRate: Double, dt: Double) {
        precondition(input.count >= fftSize)
        samples.withUnsafeMutableBufferPointer { out in
            input.withUnsafeBufferPointer { out.baseAddress!.update(from: $0.baseAddress! + (input.count - fftSize), count: fftSize) }
        }
        analyze(sampleRate: sampleRate)
        advance(by: dt)
    }

    /// The bars without the motion: each band's level for the samples in `samples`.
    private func analyze(sampleRate: Double) {
        if sampleRate != bandsRate { layOutBands(sampleRate: sampleRate) }
        let half = fftSize / 2
        vDSP.multiply(samples, window, result: &samples)
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                // Bin 0 packs DC and Nyquist together; neither is shown.
                im[0] = 0
                re[0] = 0
                vDSP.squareMagnitudes(split, result: &magnitudes)
            }
        }
        // A full-scale sine's bin comes out at (fftSize / 2 · Hann's mean of ½ · the FFT's 2)².
        let reference = Float(fftSize / 2) * Float(fftSize / 2)
        for (index, band) in bands.enumerated() {
            var loudest: Float = 0
            for bin in band.first...band.last { loudest = max(loudest, magnitudes[bin]) }
            let db = 10 * log10(max(loudest / reference, 1e-12)) + band.tilt
            targets[index] = min(max((db + Self.range) / Self.range, 0), 1)
        }
    }

    private func layOutBands(sampleRate: Double) {
        bandsRate = sampleRate
        let half = fftSize / 2
        let binWidth = sampleRate / Double(fftSize)
        let top = min(Self.highest, sampleRate / 2 * 0.95)
        let ratio = log2(top / Self.lowest) / Double(bandCount)
        bands = (0..<bandCount).map { index in
            let low = Self.lowest * pow(2, ratio * Double(index))
            let high = Self.lowest * pow(2, ratio * Double(index + 1))
            let centre = (low * high).squareRoot()
            // A band narrower than a bin takes the bin it's in.
            let first = min(max(Int((low / binWidth).rounded()), 1), half - 1)
            let last = min(max(Int((high / binWidth).rounded()) - 1, first), half - 1)
            return (first, last, Self.slope * Float(log2(centre / 1000)))
        }
    }

    private func advance(by dt: Double) {
        let step = Float(dt)
        for i in 0..<bandCount {
            let target = targets[i]
            levels[i] = target >= levels[i] ? target : max(levels[i] - Self.fall * step, target)
            if levels[i] >= peaks[i] {
                peaks[i] = levels[i]
                holds[i] = levels[i] > 0 ? Self.hold : 0
                speeds[i] = 0
            } else if holds[i] > 0 {
                holds[i] -= dt
            } else {
                speeds[i] += Self.peakAcceleration * step
                peaks[i] = max(peaks[i] - speeds[i] * step, levels[i])
            }
        }
    }
}
