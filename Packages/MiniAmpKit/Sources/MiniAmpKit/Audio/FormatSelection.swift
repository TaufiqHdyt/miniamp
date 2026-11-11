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
    /// Non-mixable formats are only considered when `allowNonMixable` (hog mode is held), since
    /// setting one without exclusive access fails. Ties on bit depth prefer integer over float
    /// (what a DAC actually takes), then mixable formats, then the stream's current channel count.
    public static func bestPhysicalFormat(
        from available: [AudioStreamRangedDescription],
        sampleRate: Double,
        channels: UInt32,
        allowNonMixable: Bool = false
    ) -> AudioStreamBasicDescription? {
        let candidates = available.compactMap { ranged -> AudioStreamBasicDescription? in
            var f = ranged.mFormat
            guard f.mFormatID == kAudioFormatLinearPCM else { return nil }
            if !allowNonMixable && f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 { return nil }
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

    /// Common hardware rates, used to expand continuous ranges into concrete choices.
    static let standardRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000,
    ]

    /// The rate to run the device at for a file it can't play natively.
    ///
    /// In order of preference:
    /// 1. The highest supported rate that divides the file's rate by a power of two
    ///    (192 → 96, 176.4 → 88.2): the resampler's job is simplest and the family is kept.
    /// 2. The lowest supported rate that multiplies it by a power of two (22.05 → 44.1).
    /// 3. The highest supported rate in the same family (multiples of 44.1 or 48 kHz).
    /// 4. The highest supported rate.
    public static func fallbackRate(for fileRate: Double, supported ranges: [ClosedRange<Double>]) -> Double? {
        if contains(ranges, fileRate) { return fileRate }
        let rates = Set(ranges.flatMap { range in
            standardRates.filter { range.contains($0) } + [range.lowerBound, range.upperBound]
        }).sorted(by: >)
        guard !rates.isEmpty else { return nil }

        let halving = rates.first { rate in
            let ratio = fileRate / rate
            return ratio > 1 && ratio == ratio.rounded() && Int(ratio).nonzeroBitCount == 1
        }
        if let halving { return halving }

        // Below every supported rate (22.05 kHz on a 44.1+ device): the lowest exact doubling.
        let doubling = rates.reversed().first { rate in
            let ratio = rate / fileRate
            return ratio > 1 && ratio == ratio.rounded() && Int(ratio).nonzeroBitCount == 1
        }
        if let doubling { return doubling }

        func family(_ r: Double) -> Double? {
            if (r / 44_100).rounded() * 44_100 == r { return 44_100 }
            if (r / 48_000).rounded() * 48_000 == r { return 48_000 }
            return nil
        }
        if let base = family(fileRate), let sameFamily = rates.first(where: { family($0) == base }) {
            return sameFamily
        }
        return rates.first
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
