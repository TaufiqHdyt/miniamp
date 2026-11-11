import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import MiniAmpKit

/// Issue #10: when the device can't run at the file's rate, the output unit resamples at high quality.
///
/// Renders offline through the same graph as playback, 192 kHz file → 96 kHz output.
@MainActor
@Suite struct ResamplingTests {
    /// Level in dBFS (RMS relative to a full-scale sine) of the rendered output, skipping the
    /// first and last 10 ms where the filter rings in and out.
    static func render(tone: Double, from fileRate: Double, to outputRate: Double,
                       complexity: UInt32?) throws -> Double {
        let url = try TestAudio.writeTone(frequency: tone, sampleRate: fileRate, amplitude: 0.5, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: 4096)
        if let complexity {
            try OutputUnit.setResamplerComplexity(complexity, on: engine)
        } else {
            try OutputUnit.setMaximumResamplingQuality(on: engine)
        }
        try Player.connectBitPerfect(node, in: engine, format: file.processingFormat)
        node.scheduleFile(file, at: nil)
        try engine.start()
        try node.playAudio()
        defer { engine.stop() }

        let total = AVAudioFrameCount(outputRate * 0.5)
        let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)!
        var samples: [Float] = []
        while samples.count < Int(total) {
            _ = try engine.renderOffline(min(4096, total - AVAudioFrameCount(samples.count)), to: buffer)
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        let skip = Int(outputRate * 0.01)
        let body = samples[skip..<(samples.count - skip)]
        let rms = sqrt(body.reduce(0) { $0 + Double($1 * $1) } / Double(body.count))
        return 20 * log10(max(rms, 1e-12) / (1 / 2.squareRoot()))
    }

    @Test func passbandToneSurvives() throws {
        let level = try Self.render(tone: 1_000, from: 192_000, to: 96_000, complexity: nil)
        #expect(abs(level - -6.02) < 0.1, "1 kHz at -6 dBFS came out at \(level) dBFS")
    }

    @Test func toneAboveNewNyquistIsRemoved() throws {
        // 60 kHz is above 48 kHz (Nyquist at 96 kHz). A poor resampler folds it down to 36 kHz.
        let best = try Self.render(tone: 60_000, from: 192_000, to: 96_000, complexity: nil)
        let linear = try Self.render(tone: 60_000, from: 192_000, to: 96_000,
                                     complexity: kAudioUnitSampleRateConverterComplexity_Linear)
        print("60 kHz tone after 192→96 kHz: mastering \(best) dBFS, linear \(linear) dBFS")
        #expect(best < -100, "alias at \(best) dBFS")
        #expect(best < linear - 20, "max quality isn't better than linear (\(best) vs \(linear))")
    }
}
