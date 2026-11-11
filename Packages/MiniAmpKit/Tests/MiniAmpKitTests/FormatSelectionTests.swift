import CoreAudio
import Testing
@testable import MiniAmpKit

/// Issue #4: choosing the deepest physical format at the target rate.
@Suite struct FormatSelectionTests {
    static func pcm(_ rate: Double, bits: UInt32, float: Bool = false, channels: UInt32 = 2,
                    nonMixable: Bool = false, range: ClosedRange<Double>? = nil) -> AudioStreamRangedDescription {
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
            | (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
        if nonMixable { flags |= kAudioFormatFlagIsNonMixable }
        let bytes = (bits + 7) / 8 * channels
        let asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
        let r = range ?? rate...rate
        return AudioStreamRangedDescription(mFormat: asbd,
                                            mSampleRateRange: AudioValueRange(mMinimum: r.lowerBound, mMaximum: r.upperBound))
    }

    @Test func picksHighestBitDepthAtRate() throws {
        let available = [Self.pcm(96_000, bits: 16), Self.pcm(96_000, bits: 24), Self.pcm(192_000, bits: 32), Self.pcm(44_100, bits: 32)]
        let best = try #require(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 96_000, channels: 2))
        #expect(best.mBitsPerChannel == 24)
        #expect(best.mSampleRate == 96_000)
    }

    @Test func prefersIntegerOverFloatAtSameDepth() throws {
        let available = [Self.pcm(48_000, bits: 32, float: true), Self.pcm(48_000, bits: 32)]
        let best = try #require(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 48_000, channels: 2))
        #expect(!FormatSelection.isFloat(best))
    }

    @Test func nonMixableOnlyWithHogMode() throws {
        // A DAC offering 32-bit integer only as non-mixable, 24-bit mixable.
        let available = [Self.pcm(96_000, bits: 32, nonMixable: true), Self.pcm(96_000, bits: 24)]
        let shared = try #require(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 96_000, channels: 2))
        #expect(shared.mBitsPerChannel == 24)
        let hogged = try #require(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 96_000, channels: 2,
                                                                     allowNonMixable: true))
        #expect(hogged.mBitsPerChannel == 32)
    }

    /// Issue #10: which rate to run the device at when it can't do the file's rate.
    @Test(arguments: [
        // (file rate, device rates, expected)
        (192_000.0, [44_100.0, 48_000, 88_200, 96_000], 96_000.0),   // built-in jack: halve
        (176_400, [44_100, 48_000, 88_200, 96_000], 88_200),          // halve, stay in 44.1 family
        (352_800, [44_100, 48_000, 88_200, 96_000], 88_200),          // quarter
        (384_000, [44_100, 48_000], 48_000),                          // divide by 8
        (96_000, [44_100, 48_000, 96_000], 96_000),                   // supported: unchanged
        (22_050, [44_100, 48_000, 88_200], 44_100),                   // double up
        (88_200, [48_000, 96_000], 96_000),                           // no 44.1 family: highest
        (192_000, [44_100, 88_200], 88_200),                          // no 48 family: highest
    ])
    func fallbackRate(_ c: (Double, [Double], Double)) {
        let ranges = c.1.map { $0...$0 }
        #expect(FormatSelection.fallbackRate(for: c.0, supported: ranges) == c.2)
    }

    @Test func fallbackRateExpandsContinuousRanges() {
        #expect(FormatSelection.fallbackRate(for: 384_000, supported: [8_000...192_000]) == 192_000)
        #expect(FormatSelection.fallbackRate(for: 100_000, supported: [8_000...48_000]) == 48_000)
        #expect(FormatSelection.fallbackRate(for: 48_000, supported: []) == nil)
    }

    /// Issue #47: mono goes to both front channels; other layouts map one-to-one.
    @Test func channelMaps() {
        #expect(OutputUnit.channelMap(sourceChannels: 1, deviceChannels: 2) == [0, 0])
        #expect(OutputUnit.channelMap(sourceChannels: 1, deviceChannels: 4) == [0, 0, -1, -1])
        #expect(OutputUnit.channelMap(sourceChannels: 2, deviceChannels: 2) == [0, 1])
        #expect(OutputUnit.channelMap(sourceChannels: 2, deviceChannels: 6) == [0, 1, -1, -1, -1, -1])
        #expect(OutputUnit.channelMap(sourceChannels: 6, deviceChannels: 2) == [0, 1])
    }

    @Test func prefersMixableThenMatchingChannels() throws {
        let available = [Self.pcm(48_000, bits: 24, nonMixable: true), Self.pcm(48_000, bits: 24, channels: 8), Self.pcm(48_000, bits: 24)]
        let best = try #require(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 48_000, channels: 2))
        #expect(best.mChannelsPerFrame == 2)
        #expect(best.mFormatFlags & kAudioFormatFlagIsNonMixable == 0)
    }

    @Test func zeroRateMeansAnyRateInRange() throws {
        let available = [Self.pcm(0, bits: 24, range: 44_100...192_000)]
        let best = try #require(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 176_400, channels: 2))
        #expect(best.mSampleRate == 176_400)
        #expect(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 384_000, channels: 2) == nil)
    }

    @Test func ignoresNonPCMAndOtherRates() {
        var ac3 = Self.pcm(48_000, bits: 16)
        ac3.mFormat.mFormatID = kAudioFormat60958AC3
        #expect(FormatSelection.bestPhysicalFormat(from: [ac3, Self.pcm(44_100, bits: 24)],
                                                   sampleRate: 48_000, channels: 2) == nil)
    }

    @Test func builtInDeviceOffersOnlyFloat() throws {
        // What the MacBook Pro built-in output reports: 32-bit float only.
        let available = [96_000.0, 88_200, 48_000, 44_100].map { Self.pcm($0, bits: 32, float: true) }
        let best = try #require(FormatSelection.bestPhysicalFormat(from: available, sampleRate: 96_000, channels: 2))
        #expect(FormatSelection.describe(best) == "96 kHz, 32-bit float, 2 ch")
    }

    @Test func rateHelpers() {
        #expect(FormatSelection.sameRate(44_100, 44_100.2))
        #expect(!FormatSelection.sameRate(44_100, 48_000))
        #expect(FormatSelection.contains([44_100...44_100, 96_000...96_000], 96_000))
        #expect(!FormatSelection.contains([44_100...48_000], 96_000))
        #expect(FormatSelection.formatRate(44_100) == "44.1 kHz")
        #expect(FormatSelection.formatRate(96_000) == "96 kHz")
    }

    @Test func signalPathReportsResampling() {
        let native = SignalPath(codec: "FLAC", fileSampleRate: 96_000, fileBitDepth: 24, fileChannels: 2,
                                engineSampleRate: 96_000, deviceName: "Test", deviceSampleRate: 96_000,
                                devicePhysicalFormat: "")
        #expect(!native.isResampled)
        var resampled = native
        resampled.deviceSampleRate = 44_100
        #expect(resampled.isResampled)
        #expect(resampled.summary.contains("RESAMPLED (96 kHz → 44.1 kHz)"))
    }

    /// Issue #22: the quality label's verdict.
    @Test func signalPathVerdict() {
        func path(codec: String = "FLAC", rate: Double = 96_000, bits: Int? = 24, deviceRate: Double = 96_000,
                  deviceBits: Int? = 24, float: Bool = false) -> SignalPath {
            SignalPath(codec: codec, fileSampleRate: rate, fileBitDepth: bits, fileChannels: 2,
                       engineSampleRate: deviceRate, deviceName: "Test", deviceSampleRate: deviceRate,
                       devicePhysicalFormat: "", devicePhysicalBits: deviceBits, devicePhysicalIsFloat: float)
        }
        #expect(path().verdict == .bitPerfect)
        #expect(path(bits: 16, deviceBits: 24).verdict == .bitPerfect)
        // Float32 holds 24 bits exactly (the built-in speakers' format), but not 32.
        #expect(path(deviceBits: 32, float: true).verdict == .bitPerfect)
        #expect(path(bits: 32, deviceBits: 32, float: true).verdict == .reducedBitDepth(from: 32, to: 24))
        #expect(path(bits: 24, deviceBits: 16).verdict == .reducedBitDepth(from: 24, to: 16))
        #expect(path(rate: 192_000, deviceRate: 96_000).verdict == .resampled(from: 192_000, to: 96_000))
        // Lossy: nothing resamples, but there are no original samples to be "bit-perfect" to.
        #expect(path(codec: "MP3", rate: 44_100, bits: nil, deviceRate: 44_100).verdict == .nativeRate)
        #expect(path(codec: "MP3", rate: 44_100, bits: nil, deviceRate: 48_000).verdict == .resampled(from: 44_100, to: 48_000))
        // Unknown device format: judged on rate alone.
        #expect(path(deviceBits: nil).verdict == .bitPerfect)
    }
}
