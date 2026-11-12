import AVFoundation
import Testing
@testable import MiniAmpKit

/// The app volume: a gain on what's rendered, ramped, and untouched at 100%.
@Suite struct AppVolumeTests {
    /// Two deinterleaved channels of `frames` samples, all `value`.
    func buffers(_ frames: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<2 { for i in 0..<frames { buffer.floatChannelData![ch][i] = value } }
        return buffer
    }

    func samples(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    @Test func fullVolumeLeavesSamplesUntouched() {
        let buffer = buffers(64, value: 0.123456789)
        let before = samples(buffer, channel: 0).map(\.bitPattern)
        HALOutput.applyGain(from: 1, to: 1, buffer.mutableAudioBufferList)
        #expect(samples(buffer, channel: 0).map(\.bitPattern) == before)
    }

    @Test func steadyGainScalesEverySample() {
        let buffer = buffers(64, value: 0.5)
        HALOutput.applyGain(from: 0.25, to: 0.25, buffer.mutableAudioBufferList)
        #expect(samples(buffer, channel: 0).allSatisfy { $0 == 0.125 })
        #expect(samples(buffer, channel: 1).allSatisfy { $0 == 0.125 })
    }

    @Test func changesRampAcrossTheBuffer() {
        let buffer = buffers(100, value: 1)
        HALOutput.applyGain(from: 1, to: 0, buffer.mutableAudioBufferList)
        let ramp = samples(buffer, channel: 1)
        #expect(ramp.first == 1)
        #expect(abs(ramp[50] - 0.5) < 0.02)
        #expect(ramp.last! < 0.02)
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 }) // no jumps
    }

    @Test func taperFollowsLoudness() {
        #expect(Player.gain(forVolume: 1) == 1)
        #expect(Player.gain(forVolume: 0) == 0)
        let db = { (v: Float) in 20 * log10(Player.gain(forVolume: v)) }
        #expect(abs(db(0.5) - -18.06) < 0.1)
        #expect(abs(db(0.75) - -7.5) < 0.1)
    }

    @MainActor
    @Test func theSignalPathSaysSo() {
        let player = Player()
        player.appVolume = 2
        #expect(player.appVolume == 1)
        player.appVolume = 0.6
        #expect(player.appVolume == 0.6)
        var path = SignalPath(codec: "FLAC", fileSampleRate: 44_100, fileBitDepth: 16, fileChannels: 2,
                              engineSampleRate: 44_100, deviceName: "Test", deviceSampleRate: 44_100,
                              devicePhysicalFormat: "24-bit integer", devicePhysicalBits: 24)
        #expect(path.verdict == .bitPerfect)
        path.appVolume = 0.6
        #expect(path.verdict == .volumeScaled(percent: 60))
        #expect(path.summary.contains("app volume 60%"))
    }
}
