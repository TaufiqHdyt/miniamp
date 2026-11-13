import AVFoundation
import Foundation
import Testing
@testable import MiniAmpKit

/// The spectrum visualizer: what the output captures, and the bars made from it.
@Suite struct VisualizerTests {
    static let rate = 44_100.0

    static func sine(_ frequency: Double, dBFS: Double = -6, count: Int = 4096) -> [Float] {
        let amplitude = pow(10, dBFS / 20)
        return (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// The band whose range holds `frequency`.
    static func band(of frequency: Double, in analyzer: SpectrumAnalyzer) -> Int {
        let top = min(SpectrumAnalyzer.highest, rate / 2 * 0.95)
        let position = log2(frequency / SpectrumAnalyzer.lowest) / log2(top / SpectrumAnalyzer.lowest)
        return Int(position * Double(analyzer.bandCount))
    }

    @Test(arguments: [100.0, 1000.0, 8000.0])
    func aToneLightsItsOwnBand(frequency: Double) {
        let analyzer = SpectrumAnalyzer(bandCount: 32)
        analyzer.update(samples: Self.sine(frequency, dBFS: -12), sampleRate: Self.rate, dt: 1 / 60)
        let levels = analyzer.levels
        let loudest = levels.indices.max { levels[$0] < levels[$1] }!
        #expect(abs(loudest - Self.band(of: frequency, in: analyzer)) <= 1)
        // −12 dBFS (below the top even with the slope's lift at 8 kHz), give or take where the
        // tone falls between bins and in its band.
        let db = Double(levels[loudest] - 1) * Double(SpectrumAnalyzer.range)
            - Double(SpectrumAnalyzer.slope) * log2(frequency / 1000)
        #expect(abs(db + 12) < 3, "\(db) dB")
        // More than an octave away: at least 30 dB down.
        let octave = Int((Double(analyzer.bandCount) / log2(min(SpectrumAnalyzer.highest, Self.rate / 2 * 0.95) / SpectrumAnalyzer.lowest)).rounded(.up))
        for (index, level) in levels.enumerated() where abs(index - loudest) > octave + 1 {
            #expect((levels[loudest] - level) * SpectrumAnalyzer.range >= 30, "band \(index)")
        }
    }

    @Test func silenceIsFlatAndSettles() {
        let analyzer = SpectrumAnalyzer(bandCount: 24)
        let silence = [Float](repeating: 0, count: 2048)
        analyzer.update(samples: silence, sampleRate: Self.rate, dt: 1 / 60)
        #expect(analyzer.levels.allSatisfy { $0 == 0 })
        #expect(analyzer.isSettled)

        analyzer.update(samples: Self.sine(1000), sampleRate: Self.rate, dt: 1 / 60)
        #expect(!analyzer.isSettled)
        for _ in 0..<120 { analyzer.update(samples: silence, sampleRate: Self.rate, dt: 1 / 60) }
        #expect(analyzer.isSettled)
    }

    @Test func peaksHangThenFall() {
        let analyzer = SpectrumAnalyzer(bandCount: 24)
        let silence = [Float](repeating: 0, count: 2048)
        analyzer.update(samples: Self.sine(1000), sampleRate: Self.rate, dt: 1 / 60)
        let band = analyzer.levels.indices.max { analyzer.levels[$0] < analyzer.levels[$1] }!
        let top = analyzer.peaks[band]
        #expect(top == analyzer.levels[band])

        // The bar sinks at once; the cap stays for half a second.
        for _ in 0..<24 { analyzer.update(samples: silence, sampleRate: Self.rate, dt: 1 / 60) }
        #expect(analyzer.levels[band] < top)
        #expect(analyzer.peaks[band] == top)
        for _ in 0..<12 {
            analyzer.update(samples: silence, sampleRate: Self.rate, dt: 1 / 60)
            #expect(analyzer.levels.indices.allSatisfy { analyzer.levels[$0] <= analyzer.peaks[$0] })
        }
        #expect(analyzer.peaks[band] < top)
    }

    @Test func tapKeepsTheNewestSamplesInOrder() {
        let tap = SampleTap()
        tap.setActive(true)
        #expect(tap.isCapturing)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        var next = 0
        // Round the ring more than once; left and right average to the sample's number.
        for _ in 0..<(SampleTap.capacity / 4096 + 3) {
            for i in 0..<4096 {
                buffer.floatChannelData![0][i] = Float(next + i) - 1
                buffer.floatChannelData![1][i] = Float(next + i) + 1
            }
            tap.write(buffer.mutableAudioBufferList, frames: 4096, hostTime: 0)
            next += 4096
        }
        var out = [Float](repeating: -1, count: 5000)
        #expect(tap.latest(5000, into: &out))
        #expect(out == (next - 5000..<next).map(Float.init))

        tap.setActive(false)
        #expect(!tap.isCapturing)
    }

    @Test func tapIsSilentBeforeAnythingAndDuringDoP() {
        let tap = SampleTap()
        var out = [Float](repeating: 1, count: 1024)
        #expect(!tap.latest(1024, into: &out))
        #expect(out.allSatisfy { $0 == 0 })

        tap.setActive(true)
        tap.setSuppressed(true)
        #expect(!tap.isCapturing)
        #expect(tap.isSuppressed)
    }
}
