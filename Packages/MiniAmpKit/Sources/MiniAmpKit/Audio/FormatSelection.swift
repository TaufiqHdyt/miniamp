import CoreAudio

/// Pure decision logic for device formats, kept free of HAL calls so it can be unit-tested.
public enum FormatSelection {
    /// Sample rates are doubles from hardware; treat anything within half a hertz as equal.
    public static func sameRate(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }

    public static func contains(_ ranges: [ClosedRange<Double>], _ rate: Double) -> Bool {
        ranges.contains { ($0.lowerBound - 0.5)...($0.upperBound + 0.5) ~= rate }
    }

    /// The highest-bit-depth linear PCM format the stream offers at `sampleRate`.
    ///
    /// Ties on bit depth prefer integer over float (what a DAC actually takes), then mixable
    /// formats (non-mixable ones need hog mode), then the stream's current channel count.
    public static func bestPhysicalFormat(
        from available: [AudioStreamRangedDescription],
        sampleRate: Double,
        channels: UInt32
    ) -> AudioStreamBasicDescription? {
        let candidates = available.compactMap { ranged -> AudioStreamBasicDescription? in
            var f = ranged.mFormat
            guard f.mFormatID == kAudioFormatLinearPCM else { return nil }
            let range = ranged.mSampleRateRange
            if f.mSampleRate == 0 {
                // A rate of 0 means "any rate in mSampleRateRange".
                guard (range.mMinimum - 0.5)...(range.mMaximum + 0.5) ~= sampleRate else { return nil }
                f.mSampleRate = sampleRate
            } else if !sameRate(f.mSampleRate, sampleRate) {
                return nil
            }
            return f
        }
        return candidates.max { rank($0, channels) < rank($1, channels) }
    }

    private static func rank(_ f: AudioStreamBasicDescription, _ channels: UInt32) -> (UInt32, Int, Int, Int) {
        (f.mBitsPerChannel,
         isFloat(f) ? 0 : 1,
         f.mFormatFlags & kAudioFormatFlagIsNonMixable == 0 ? 1 : 0,
         f.mChannelsPerFrame == channels ? 1 : 0)
    }

    static func isFloat(_ f: AudioStreamBasicDescription) -> Bool {
        f.mFormatFlags & kAudioFormatFlagIsFloat != 0
    }

    /// Compares the fields that define a physical format.
    public static func matches(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        sameRate(a.mSampleRate, b.mSampleRate)
            && a.mFormatID == b.mFormatID
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && isFloat(a) == isFloat(b)
    }

    public static func describe(_ f: AudioStreamBasicDescription) -> String {
        let kind = isFloat(f) ? "float" : "int"
        return "\(formatRate(f.mSampleRate)), \(f.mBitsPerChannel)-bit \(kind), \(f.mChannelsPerFrame) ch"
    }

    public static func formatRate(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }
}
